-- ============================================================================
-- Preparar el Postgres de Odoo para Lakeflow Connect (conector PostgreSQL)
--
-- Correr como superusuario contra la base de Odoo. La forma soportada es:
--
--   make cdc-setup
--
-- que equivale a:
--
--   docker compose -f odoo/docker-compose.yml exec -T db \
--     psql -U odoo -d demo \
--       -v repl_user=databricks_replication \
--       -v repl_password='...' \
--       -v repl_publication=databricks_pub \
--       -v repl_slot=databricks_slot \
--     < ingestion/cdc/lakeflow_setup.sql
--
-- Los cuatro parámetros son obligatorios y salen de .env. El password NO está
-- quemado en este archivo a propósito.
--
-- Requisitos previos que NO se resuelven acá:
--   - wal_level = logical  (va en el arranque del servidor, ver el compose)
--   - PostgreSQL 13 o superior
--   - el gateway de Databricks tiene que poder abrir el puerto 5432
--
-- Re-ejecutable: crea el rol solo si falta, recrea la publicación y respeta
-- un slot que ya exista. OJO: recrear la publicación con el gateway corriendo
-- interrumpe el streaming. Si ya está en producción, pará el gateway primero.
-- ============================================================================

\set ON_ERROR_STOP on

-- ============================================================================
-- 0. Parámetros. Si falta alguno, parar acá antes de tocar nada.
-- ============================================================================

-- Las variables no definidas se vuelven cadena vacía, y una sola verificación
-- las cubre a las cuatro. Falla con exit code distinto de cero: si esto se
-- corre dentro de un `make`, la cadena se corta acá.
\if :{?repl_user}       \else \set repl_user       '' \endif
\if :{?repl_password}   \else \set repl_password   '' \endif
\if :{?repl_publication}\else \set repl_publication '' \endif
\if :{?repl_slot}       \else \set repl_slot       '' \endif
\if :{?tablas}          \else \set tablas          '' \endif

SELECT format('DO $guard$ BEGIN RAISE EXCEPTION %L; END $guard$',
              'Faltan parámetros obligatorios (repl_user, repl_password, ' ||
              'repl_publication, repl_slot, tablas). Corré `make cdc-setup` en vez de ' ||
              'invocar psql a mano.')
WHERE '' IN (:'repl_user', :'repl_password', :'repl_publication', :'repl_slot', :'tablas')
\gexec

\echo 'Base:' :DBNAME '| rol:' :repl_user '| publicación:' :repl_publication '| slot:' :repl_slot

-- ============================================================================
-- 1. Verificación del arranque del servidor.
-- Sin wal_level = logical no hay CDC posible: falla fuerte en vez de seguir.
-- ============================================================================

DO $$
BEGIN
  IF current_setting('wal_level') <> 'logical' THEN
    RAISE EXCEPTION
      'wal_level = %, se necesita "logical". Arreglá el arranque del servidor (ver odoo/docker-compose.yml) y recreá el contenedor: make db-recreate.',
      current_setting('wal_level');
  END IF;
  IF current_setting('max_replication_slots')::int < 1 THEN
    RAISE EXCEPTION 'max_replication_slots = 0, no se puede crear el slot.';
  END IF;
END $$;

\echo '  wal_level OK'

-- ============================================================================
-- 2. Tablas replicadas — FUENTE ÚNICA
--
-- Odoo tiene ~900 tablas. NO se publica el esquema completo: la mayoría es
-- plomería del ORM (ir_*, mail_*, tablas de relación m2m sin llave primaria)
-- que solo infla el WAL y el costo del gateway. Databricks recomienda 250
-- tablas o menos por pipeline.
--
-- La lista alimenta TANTO el replica identity COMO la publicación. Y viene de
-- ingestion/contract.py, el mismo archivo que usa el carril batch, así que los
-- dos carriles publican exactamente lo mismo. Agregar una tabla es una
-- decisión consciente: se hace allá, no acá.
-- ============================================================================

DROP TABLE IF EXISTS tablas_replicadas;
CREATE TEMP TABLE tablas_replicadas(tabla name PRIMARY KEY);

-- La lista NO vive acá: llega en :tablas desde ingestion/contract.py, que es la
-- fuente única. `make cdc-setup` la calcula con `python3 ingestion/contract.py
-- --lista`. Así el carril CDC y el carril batch no se pueden desincronizar.
INSERT INTO tablas_replicadas
SELECT DISTINCT trim(t)::name
FROM unnest(string_to_array(:'tablas', ',')) AS t
WHERE trim(t) <> '';

\echo '  tablas del contrato recibidas:'
SELECT count(*) AS n_tablas FROM tablas_replicadas;

-- Falla si alguna tabla de la lista no existe en la base (típico: falta
-- instalar el módulo que la crea).
DO $$
DECLARE faltantes text;
BEGIN
  SELECT string_agg(t.tabla, ', ' ORDER BY t.tabla) INTO faltantes
  FROM tablas_replicadas t
  WHERE to_regclass('public.' || quote_ident(t.tabla)) IS NULL;

  IF faltantes IS NOT NULL THEN
    RAISE EXCEPTION 'Estas tablas no existen en la base: %. ¿Instalaste sale_management y stock?', faltantes;
  END IF;
END $$;

-- ============================================================================
-- 3. Usuario de replicación
-- El pipeline NO usa credenciales de admin: en la conexión de Unity Catalog
-- solo se guardan las credenciales de este usuario.
-- ============================================================================

SELECT format('CREATE ROLE %I WITH LOGIN REPLICATION', :'repl_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'repl_user')
\gexec

-- El password se fija siempre, así rotarlo es solo volver a correr el script.
SELECT format('ALTER ROLE %I WITH LOGIN REPLICATION PASSWORD %L',
              :'repl_user', :'repl_password')
\gexec

SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'DBNAME', :'repl_user') \gexec
SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'repl_user') \gexec
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA public TO %I', :'repl_user') \gexec

-- Para que las tablas que Odoo cree después (al instalar un módulo) también
-- queden legibles sin volver a correr los GRANT:
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO %I',
              :'repl_user')
\gexec

\echo '  rol de replicación listo'

-- ============================================================================
-- 4. Replica identity
-- Cada tabla replicada necesita replica identity FULL o DEFAULT. Databricks
-- recomienda FULL para tablas sin llave primaria o con columnas TOASTables.
--
-- Las tablas de Odoo están llenas de text y jsonb (o sea, TOASTables), así que
-- acá se usa FULL. El costo es más volumen de WAL: si el disco de la instancia
-- va justo, evaluá dejar DEFAULT en las tablas grandes que solo se insertan.
-- ============================================================================

SELECT format('ALTER TABLE public.%I REPLICA IDENTITY FULL', tabla)
FROM tablas_replicadas ORDER BY tabla
\gexec

\echo '  replica identity FULL aplicado'

-- ============================================================================
-- 5. Publicación
-- IMPORTANTE: la publicación va ANTES del slot de replicación. Al revés falla.
-- ============================================================================

SELECT format('DROP PUBLICATION IF EXISTS %I', :'repl_publication') \gexec

SELECT format('CREATE PUBLICATION %I FOR TABLE %s',
              :'repl_publication',
              string_agg(format('public.%I', tabla), ', ' ORDER BY tabla))
FROM tablas_replicadas
\gexec

\echo '  publicación creada'

-- ============================================================================
-- 6. Slot de replicación
-- Solo se soporta el plugin pgoutput. Lo tiene que crear el usuario con
-- privilegio REPLICATION. Si el slot ya existe se respeta: borrarlo perdería
-- la posición del CDC.
-- ============================================================================

SELECT format('SET ROLE %I', :'repl_user') \gexec

SELECT format('SELECT pg_create_logical_replication_slot(%L, %L)',
              :'repl_slot', 'pgoutput')
WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = :'repl_slot')
\gexec

RESET ROLE;

-- ============================================================================
-- 7. Verificación
-- ============================================================================

\echo ''
\echo '--- slots ---'
SELECT slot_name, plugin, slot_type, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retenido
FROM pg_replication_slots;

\echo '--- publicaciones ---'
SELECT pubname, puballtables FROM pg_publication;

\echo '--- tablas publicadas ---'
SELECT schemaname, tablename FROM pg_publication_tables
WHERE pubname = :'repl_publication' ORDER BY tablename;

-- ============================================================================
-- VIGILANCIA
--
-- Un slot inactivo retiene WAL indefinidamente. Si el gateway se cae o borrás
-- el pipeline sin borrar el slot, el WAL crece hasta llenar el disco y se cae
-- Odoo. Los slots NO se eliminan solos al borrar un pipeline.
--
--   make slots        → estado de los slots y WAL retenido
--   make slot-drop    → borrar el slot a mano
--
-- Esto va en un monitor, no en la memoria.
-- ============================================================================
