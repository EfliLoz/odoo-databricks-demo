# Demo Odoo + Databricks — Runbook completo

De cero a una página con dashboard y Genie donde un gerente pregunta
"¿cómo va la Zona Norte contra el año pasado?" y recibe el número correcto.

---

## 0. Arquitectura

```
Odoo 19 (EC2, Docker)
   └── PostgreSQL 16  ── replicación lógica (pgoutput)
                          │
                    Lakeflow Connect
                    ├── gateway    (compute clásico, modo continuo)
                    └── ingesta    (serverless, programada)
                          │
                    bronze_pg.*   ← esquema crudo de Odoo, en Delta
                          │
                    silver.*      ← tipado, jsonb resuelto, joins del ORM
                          │
                    gold.*        ← modelo estrella + comentarios + llaves
                          │
              ┌───────────┴───────────┐
        AI/BI Dashboard         Genie Agent
              └───────────┬───────────┘
                    Página embebida (iframe)
```

### Decisiones tomadas y por qué

| Decisión | Motivo | Costo |
|---|---|---|
| CDC por Postgres, no por API | La API se topa en 2-3 ops/seg por worker; el carril directo rinde 5-10x y **sí captura borrados** | Solo sirve para clientes self-hosted; Odoo Online y Odoo.sh quedan fuera |
| Odoo 19 | Última versión; 17, 18 y 19 tienen soporte | Ninguno para la demo |
| Modelo estrella en Gold | Genie responde mucho mejor sobre datos curados que sobre el esquema del ERP | Una capa más de SQL que mantener |
| Nombres de negocio en español | "zona" y "vendedor" en vez de team_id y user_id | Ninguno |

### Bloqueantes que no dependen de vos — arrancalos hoy

1. **El conector PostgreSQL de Lakeflow Connect está en Public Preview** y hay
   que pedir acceso al equipo de cuenta de Databricks. No es un toggle.
2. **La EC2**: el gateway tiene que alcanzar el puerto 5432. Un Postgres en
   Docker en tu laptop no es alcanzable. Misma región que el workspace.

---

## Fase 1 — Infraestructura

EC2 en la misma región del workspace de Databricks. `t3.large` alcanza de sobra
(2 vCPU, 8 GB). Security group: 5432 abierto **solo** al rango de Databricks,
8069 solo a tu IP.

```bash
# Amazon Linux 2023
sudo dnf install -y docker
sudo systemctl enable --now docker
sudo usermod -aG docker $USER && newgrp docker
docker compose version
```

Clonar el repo en la instancia y preparar las credenciales:

```bash
git clone <repo> ~/odoo-databricks-demo && cd ~/odoo-databricks-demo
make env          # crea odoo/.env a partir de odoo/.env.example
$EDITOR odoo/.env
```

`odoo/.env` lleva las credenciales de Postgres, los puertos publicados y —
importante para la Fase 4 — el password del usuario de replicación. No se
versiona. Todo lo demás tiene valores por defecto en el compose, así que el
sandbox levanta aunque no lo edites; en la EC2 sí conviene cambiarlo.

Todos los comandos de este runbook se corren **desde la raíz del repo**.
`make help` los lista.

---

## Fase 2 — Odoo con moneda hondureña

Odoo instala automáticamente la localización según el país de la compañía; si
no hay país configurado cae en `l10n_generic_coa` (US) y te quedás en dólares.
Y **la moneda de la compañía no se puede cambiar una vez que hay asientos
contables**, así que el orden importa.

```bash
make bootstrap
```

Eso encadena los cuatro pasos que **tienen que ir en este orden**:

| Paso | Target | Qué hace |
|---|---|---|
| 1 | `db-up` | levanta Postgres y espera a que esté `healthy` |
| 2 | `db-create` | crea la base con `--with-demo`, **solo el módulo `base`** |
| 3 | `localize` | fija país Honduras y moneda HNL (`odoo/scripts/localize_hn.py`) |
| 4 | `modules` | instala la localización (`l10n_hn`) y luego ventas e inventario |

Tres cosas que cuestan una tarde si no se saben:

- **Desde Odoo 19 la demo data NO se instala por defecto.** `--without-demo` es
  el default. Sin `--with-demo`, `product_template` queda en 0 y el seed muere
  sin productos que vender.
- **`sale_management` arrastra `account` como dependencia.** Si se instala en
  el paso 2, la demo data de contabilidad crea asientos y en el paso 3 la
  moneda ya no se puede cambiar. Por eso el paso 2 instala **solo `base`**.
- **Con demo data terminás con tres compañías, y no se puede evitar.** El demo
  de `account` renombra la principal, le aplica `generic_coa` en USD, y crea
  una por cada localización instalada. Instalar `l10n_hn` primero tampoco lo
  evita: se probó. La compañía que queda en HNL nace **sin almacén**, y sin
  almacén no hay `stock_quant` que mostrar. De eso se encarga `make company`,
  del que depende `make seed`.

Cada paso corre suelto (`make db-create`, `make localize`, …) si algo falla a
la mitad y querés retomar.

Verificar si existe localización hondureña:

```bash
make check-l10n
```

Si existe, instalarlo con `-i l10n_hn` en vez de `account` y trae plan de
cuentas e impuestos hondureños. Si no existe, `make modules` cae en `account`
y deja el
plan genérico pero en lempiras y con el país correcto: para la demo alcanza.

Entrar a `http://<ip>:8069` con `admin` / `admin` y confirmar que hay productos
y pedidos.

---

## Fase 3 — Datos que valgan la pena mostrar

La demo de Odoo trae un puñado de pedidos. Un dashboard con 30 pedidos no vende
nada. El seed crea departamentos hondureños, 4 zonas con gerente, 10 vendedores
y ~900 pedidos con estacionalidad en 18 meses.

```bash
make seed
```

`seed` depende de `company`, que corre solo antes: toma la compañía de la
moneda de la demo, le crea el almacén que le falta y la deja como compañía por
defecto del admin. Sin ese paso el seed cae en la compañía en dólares.

**Verificá la moneda antes de dar la demo por buena:**

```bash
make currency     # tiene que mostrar la compañía del seed en HNL
```

579 pedidos en USD se ven idénticos a 579 en HNL hasta que alguien mira el
dashboard delante del cliente.

Por debajo es `docker compose run --rm -T odoo odoo shell -d demo --no-http <
odoo/scripts/seed_sales.py`. **El `-T` es obligatorio.** Sin él compose no conecta el
stdin y el script nunca entra — por eso conviene usar el target y no escribirlo
a mano.

> Detalle que ahorra una tarde: `action_confirm` reescribe `date_order` con la
> fecha de hoy. Hay que retrofechar **después** de confirmar, o toda la historia
> se apila en el día de hoy y el dashboard sale plano.

Tarda 3-5 minutos. Termina imprimiendo el conteo por zona.

---

## Fase 4 — Postgres listo para CDC

Ya viene en el `docker-compose.yml`, pero requiere recrear el contenedor:

```bash
make db-recreate
make wal-level
```

Si no dice `logical`, **no sigas**.

```bash
make cdc-setup
```

El script crea el usuario de replicación, fija replica identity, crea la
publicación y luego el slot — **en ese orden, que es obligatorio**. Verifica
primero `wal_level` y que las 17 tablas existan, así que falla temprano y con
un mensaje útil en vez de dejar la replicación a medias.

Es re-ejecutable: respeta un slot que ya exista (borrarlo perdería la posición
del CDC) y vuelve a fijar el password del rol, así que rotarlo es solo volver a
correr el target. Recrear la publicación con el gateway corriendo **sí**
interrumpe el streaming: si ya está en producción, pará el gateway primero.

Publica 17 tablas, no las ~900 de Odoo. El resto es plomería del ORM
(`ir_*`, `mail_*`, tablas de relación m2m sin llave primaria) que solo infla
el WAL. Databricks recomienda 250 tablas o menos por pipeline.

El password sale de `REPL_PASSWORD` en `odoo/.env`, no está quemado en el
`.sql`. `make cdc-setup` se niega a correr mientras siga en el valor de ejemplo.

---

## Fase 4b — Elegir carril de ingesta

Los dos carriles llenan el mismo contrato (`ingestion/contract.py`) y Silver no
sabe cuál corrió.

| Carril | Cuándo | Requisitos |
|---|---|---|
| `cdc` | prospectos reales | workspace **de pago** (el gateway exige compute clásico), acceso al Public Preview, y alcanzar el 5432 |
| `batch` | la demo en Free Edition | nada: `psql` + el CLI de `databricks` |

**En un workspace Free Edition solo corre `batch`.** Free Edition es
serverless-only y el gateway de Lakeflow Connect necesita compute clásico.
Lakebase tampoco es salida: su CDC nativo falla con *"Lakebase CDF is not
supported for catalogs using Default Storage"*, y Free Edition solo tiene
default storage.

```bash
make load-bronze     # Odoo -> bronze_pg, las 17 tablas
```

El cargador introspecciona el esquema del Odoo origen, así que tolera 17, 18 y
19: las columnas del contrato que esa versión no tenga salen como NULL.

Lo que se pierde frente al CDC: no captura borrados entre corridas y no es
continuo. Para la demo alcanza — recargar son segundos, así que el momento
"creo un pedido y aparece en el dashboard" se conserva.

---

## Fase 5 — Lakeflow Connect (solo carril `cdc`)

**Conexión.** Catalog → External Data → Connections → Create, tipo PostgreSQL.
Host, puerto 5432, base `demo`, credenciales de `databricks_replication`.
El pipeline nunca usa credenciales de admin.

**Gateway e ingesta son dos objetos distintos**, y esto sorprende a todos:

- El **gateway** corre en **compute clásico** (no serverless) y debe correr en
  **modo continuo** para evitar el crecimiento del WAL y la acumulación de slots.
- El **pipeline de ingesta** corre en serverless y **no soporta modo continuo**:
  va programado.

Desde la UI: Data Ingestion → PostgreSQL → conexión, publicación
`databricks_pub`, catálogo de staging, destino `odoo_demo.bronze_pg`.

> En la primera corrida el gateway extrae histórico y CDC apenas arranca, pero
> la ingesta puede correr antes de que termine, dejando datos parciales.
> **Pueden hacer falta varias corridas para que todo aterrice.** No es un bug,
> no lo debuguees.

Verificación. En Databricks:

```sql
SELECT COUNT(*) FROM odoo_demo.bronze_pg.sale_order;
SELECT COUNT(*) FROM odoo_demo.bronze_pg.sale_order_line;
```

Y en el origen, para contrastar:

```bash
make verify-cdc
```

---

## Fase 6 — Silver y Gold

Ya no se corren `.sql` sueltos: todo va por el bundle, y el orden es una
dependencia declarada en `databricks/resources/medallion.job.yml`.

```bash
databricks bundle validate --strict --target dev --profile FREE
databricks bundle deploy            --target dev --profile FREE
databricks bundle run medallion     --target dev --profile FREE
```

El job encadena cuatro tareas: `setup` (esquemas y la función `silver.txt`) →
`silver` (el pipeline declarativo, 7 materialized views) → `gold` (las tablas
del modelo estrella) → `genie` (los trusted assets).

**Por qué Gold no está en el pipeline.** Necesita constraints PK/FK, y las
materialized views no los admiten. Genie los usa para inferir joins, así que
Gold va como tarea SQL. Es una desviación consciente de la recomendación
genérica de Databricks, anotada en `databricks/src/sql/01_gold.sql`.

El catálogo y los esquemas son variables del bundle (`databricks.yml`), no
están quemados en el SQL: `dev` escribe en `silver_dev`/`gold_dev`.

### Las cuatro trampas del esquema de Odoo

Están resueltas en el SQL, pero conocelas porque son las que cuestan horas:

1. **Los campos traducibles son JSONB** desde Odoo 16. `product_template.name`
   no es texto, es `{"en_US": "...", "es_ES": "..."}`. Un `SELECT name` directo
   pinta JSON crudo en el dashboard.
2. **`res_users` no tiene columna `name`.** El nombre vive en `res_partner`
   vía `partner_id`. Es el error número uno de quien abre el esquema por
   primera vez.
3. **`product_product` tampoco tiene `name`.** Está en `product_template`
   vía `product_tmpl_id`.
4. **No existe columna de existencias.** `qty_available` es computado no
   almacenado. Hay que sumar `stock_quant` filtrando ubicaciones `internal`,
   o incluís proveedores y pérdidas y los números salen absurdos.

---

## Fase 7 — Genie Agent

Databricks reorganizó esto: los antiguos "Genie Spaces" ahora son **Genie
Agents**, y **Genie One** es la interfaz donde el usuario de negocio consume
dashboards, agentes y apps.

```
databricks/src/sql/03_genie.sql    → siete trusted assets + el bloque de Instructions
```

Crear el agente sobre `gold.sales_metrics`, `gold.fact_sales`,
`gold.fact_inventory` y las cuatro dimensiones. Después:

1. **Instrucciones** — copiar el bloque comentado al final de `databricks/src/sql/03_genie.sql`.
   Cortas y específicas. Nunca para tapar metadata faltante: si se resuelve con
   un `COMMENT` en la columna, va en el `COMMENT`.
2. **Trusted assets** — agregar las siete funciones de `databricks/src/sql/03_genie.sql`.
   Cuando Genie las usa, la respuesta sale con etiqueta **"Trusted"**, que es
   una señal de confianza que el usuario no técnico no puede obtener leyendo
   el SQL generado.
3. **Sample questions** — las siete que cubren las funciones.

**Preparás las preguntas que vas a hacer en vivo y las volvés trusted. La demo
deja de ser una ruleta.**

Costo: Genie One y Genie Agents están gratis hasta el **31 de enero de 2027**
para usuarios (los service principals sí se cobran). Lo único que consumís es
el SQL warehouse.

---

## Fase 8 — Dashboard y la página

Dashboard AI/BI sobre `gold.sales_metrics`. Mínimo:

- KPI: venta del mes, variación contra año anterior, pedidos, ticket promedio
- Línea: venta mensual, dos años superpuestos
- Barras: venta por zona, con el gerente en el tooltip
- Mapa o barras: venta por departamento
- Tabla: ranking de vendedores
- Tabla: productos en riesgo de quiebre

**El embedding de dashboards para usuarios externos ya es GA**: el prospecto ve
el dashboard sin tener cuenta de Databricks. Y se puede ocultar el logo de
Databricks con la opción `hideDatabricksLogo`.

El chat de Genie por iframe sigue en **Beta** y hay que habilitarlo en la página
de Previews del workspace. Si querés algo estable para producción, las **Genie
Conversation APIs** dejan meter el chat en tu propia página o en Slack/Teams.

---

## Fase 9 — El guion de la demo (5 minutos)

1. **Abrir Odoo.** "Este es el ERP del cliente, sin tocar. No instalamos nada."
2. **Crear un pedido en vivo** en Odoo.
3. **Saltar al dashboard.** Panorama de 18 meses, zonas, gerentes.
4. **Refrescar** y mostrar el pedido recién creado ya reflejado.
5. **Preguntarle a Genie** en español: "¿cómo va la Zona Norte contra el año
   pasado?" — respuesta con etiqueta Trusted.
6. **Segunda pregunta, no preparada**, para mostrar que no es un truco:
   "¿y qué productos me están por faltar?"
7. **Cerrar con gobierno**: el gerente de la Zona Sur no ve la Norte.

### Los tres puntos que cierran

1. **No tocamos su Odoo.** Réplica de solo lectura del cambio, sin módulos
   instalados, sin escribir en su base.
2. **La conversación es gobernada.** Unity Catalog controla quién ve qué.
3. **Escala más allá de ventas.** El mismo pipeline trae compras y cuentas por
   cobrar sin rehacer nada.

### La pregunta de calificación, antes de agendar

**¿Odoo self-hosted o en la nube de Odoo?** Si está en Odoo Online o Odoo.sh,
no hay acceso a la base y este carril no aplica. Y si está en Odoo Online con
plan Standard o One App Free, tampoco hay API: el acceso a la API externa solo
está en los planes Custom. Eso se pregunta **antes** de la demo, no después.

---

## Operación

### Vigilancia obligatoria

Los slots de replicación **no se eliminan al borrar un pipeline**. Un slot
inactivo retiene WAL indefinidamente hasta llenar el disco y tumbar Odoo.

```bash
make slots
```

Esto va en un monitor, no en la memoria. Limpieza manual (pide confirmación,
porque el CDC pierde su posición):

```bash
make slot-drop
```

### No apuntes a una réplica

El soporte se limita a instancias primarias: la replicación lógica no funciona
sobre réplicas de lectura ni standbys. Esto descarta usar la réplica de solo
lectura de Odoo 19 para aliviar carga — el CDC va contra el primario.

### Reset completo del sandbox

```bash
make reset      # borra volúmenes, pide confirmación
```

Y volver a la Fase 2 con `make bootstrap`. Una base creada sin demo data no se puede rellenar
después; hay que recrearla.

---

## Fuera del alcance de la demo

- **Multi-tenant.** Cada cliente sería un pipeline propio hacia su esquema
  `bronze_pg_<cliente>`, con Gold uniendo por encima. No lo armes hasta tener
  el segundo cliente: casi nunca se diferencia en lo que uno predijo.
- **Multi-versión.** Al saltarse el ORM, las diferencias de esquema entre 17,
  18 y 19 son tuyas. Se resuelven en Silver con SQL defensivo cuando aparezca
  un cliente que no esté en 19.
- **`odoo_probe.py` y `odoo_extract.py`.** Salieron del camino crítico de la
  demo al elegir el carril CDC y **no están en este repo**: viven en el
  proyecto del app Flutter, que sigue necesitando la API porque escribe
  pedidos y tiene que funcionar contra clientes en SaaS. Si los vas a traer
  acá, que sea a un `app-connector/` propio y sin mezclarlos con el carril CDC.

---

## Deuda técnica conocida

**La API que usa el app tiene fecha de muerte.** XML-RPC y JSON-RPC en
`/xmlrpc`, `/xmlrpc/2` y `/jsonrpc` están programados para eliminarse en
**Odoo 22 (otoño 2028)** y en **Online 21.1 (invierno 2027)**. El reemplazo es
la **External JSON-2 API** (`POST /json/2/<modelo>/<método>`, autenticación
bearer con API key), disponible desde Odoo 19. `odoo_extract.py` ya trae los
dos transportes detrás de la misma interfaz; el conector del app Flutter
todavía no.

---

## Inventario de archivos

| Archivo | Fase | Cómo se corre |
|---|---|---|
| `Makefile` | todas | `make help` |
| `odoo/docker-compose.yml` | 1 | EC2 o local |
| `odoo/.env.example` | 1 | `make env` → `odoo/.env` |
| `odoo/scripts/localize_hn.py` | 2 | `make localize` |
| `odoo/scripts/seed_sales.py` | 3 | `make seed` |
| `ingestion/contract.py` | 4b | lo importan los dos carriles |
| `ingestion/cdc/lakeflow_setup.sql` | 4 | `make cdc-setup` (carril `cdc`) |
| `ingestion/batch/load_bronze.py` | 4b | `make load-bronze` (carril `batch`) |
| `odoo/scripts/prepare_company.py` | 3 | `make company` (lo llama `seed`) |
| `databricks/databricks.yml` | 6 | `make bundle-deploy` |
| `databricks/resources/*.yml` | 6 | job y pipeline del bundle |
| `databricks/src/pipeline/*.sql` | 6 | tarea `silver` del job |
| `databricks/src/sql/00_setup.sql` | 6 | tarea `setup` |
| `databricks/src/sql/01_gold.sql` | 6 | tarea `gold` |
| `databricks/src/sql/03_genie.sql` | 7 | tarea `genie` |

Los scripts del carril por API (`odoo_probe.py`, `odoo_extract.py`) no están en
este repo — ver *Fuera del alcance de la demo*.
