# CLAUDE.md

Contexto para trabajar en este repositorio.

## Qué es esto

Pipeline Odoo → Databricks para una demo comercial: ventas e inventario de un
ERP Odoo replicados a un lakehouse, con dashboard AI/BI y un agente Genie que
responde en español. El público final es un gerente comercial, no un analista.

```
Odoo → PostgreSQL ──┬── carril cdc    (Lakeflow Connect) ──┐
                    └── carril batch  (CSV + COPY INTO)  ──┴→ bronze_pg
                                                                 ↓
                                                          silver → gold
                                                                 ↓
                                                  Dashboard AI/BI + Genie
```

Los dos carriles llenan el mismo contrato (`ingestion/contract.py`) y Silver no
sabe cuál corrió. Cambiar de carril no toca Silver, Gold, dashboard ni Genie.

## Estructura

Tres dominios que **no se mezclan**. Cada uno es autocontenido:

```
Makefile              todos los comandos de abajo, con `make help`

odoo/                 EL SANDBOX — nada de Databricks acá dentro
  docker-compose.yml    Odoo 19 + Postgres 16 con replicación lógica
  .env.example          credenciales y puertos (copiar a odoo/.env)
  config/odoo.conf
  addons/
  scripts/              localize_hn.py, seed_sales.py (corren en `odoo shell`)

databricks/           EL BUNDLE — nada de Odoo acá dentro
  databricks.yml        variables y targets dev/prod. Es el bundle root.
  resources/            medallion.pipeline.yml, medallion.job.yml
  src/pipeline/         Silver, como materialized views
  src/sql/              00_setup, 01_gold, 02_metrics, 03_genie (tareas del job)

ingestion/              EL PUENTE — lo único que toca los dos lados
  contract.py           QUÉ se extrae de Odoo: fuente única de las 17 tablas
  cdc/                  lakeflow_setup.sql (Lakeflow Connect, workspace de pago)
  batch/                load_bronze.py     (JSON Lines + read_files)
```

La separación es una regla, no una preferencia: si algo de Databricks necesita
saber de Odoo (o al revés), va en `ingestion/`, que para eso existe.

Ya no se corren `.sql` sueltos en un notebook: el orden es una dependencia
declarada en `databricks/resources/medallion.job.yml`, y el catálogo y los
esquemas son variables del bundle en vez de estar quemados.

Las credenciales viven en `odoo/.env` (no versionado, plantilla en
`odoo/.env.example`). Está junto al compose a propósito: Compose busca el
`.env` en el directorio del archivo de compose, no en la raíz del repo.

**El bundle root es `databricks/`**, no la raíz. El CLI busca `databricks.yml`
hacia arriba desde el cwd y no acepta una ruta al archivo, así que los comandos
de bundle entran a ese directorio. Los targets `bundle-*` del Makefile ya lo
hacen.

## Comandos

Todo desde la **raíz del repo**, vía `make`. Los targets encapsulan las partes
que se rompen fácil, así que preferilos a escribir los comandos a mano.

```bash
make help          # lista de targets

make env           # crear odoo/.env desde el ejemplo
make bootstrap     # db-up → db-create → localize → account → up
make seed          # ~900 pedidos de demo
make cdc-setup     # usuario de replicación, publicación y slot

make up / down / logs / ps / restart
make reset         # down -v: borra volúmenes, pide confirmación

make load-bronze  # carril batch: Odoo -> bronze_pg
make export-bronze  # solo los CSV, sin tocar Databricks

make wal-level     # ¿arrancó Postgres en logical?
make slots         # VIGILANCIA: slots y WAL retenido
make slot-drop     # borrar el slot a mano
make verify-cdc    # conteos de origen para contrastar contra bronze_pg
make psql          # psql interactivo
make odoo-shell    # shell del ORM
```

Si hace falta el comando crudo, sale de `make -n <target>`.

Del lado de Databricks, todo pasa por el bundle:

```bash
make bundle-validate    # cd databricks && databricks bundle validate --strict
make bundle-deploy
make bundle-run         # setup -> silver -> gold -> metrics -> genie
```

## Reglas duras

Estas no son preferencias, son cosas que rompen el pipeline.

### Odoo

- **`docker compose run` necesita `-T` cuando se le pasa un script por stdin.**
  Sin `-T` no conecta el stdin y el script nunca entra.
- **`action_confirm` reescribe `date_order` con la fecha de hoy.** Cualquier
  retrofechado va **después** de confirmar, nunca antes.
- **La moneda de la compañía no se puede cambiar si existen asientos
  contables.** El país y la moneda se fijan **antes** de instalar `account`.
  Si hay que cambiarlos, se recrea la base.
- **`sale_management` arrastra `account` como dependencia.** Con demo data eso
  crea asientos contables de una. Por eso `make db-create` instala **solo
  `base`**, y el resto va en `make modules`, después de `make localize`.
  Invertirlo rompe la moneda en silencio.
- **Instalar `account` a secas SOBRESCRIBE la moneda de la compañía.** Aplica
  `generic_coa` (US) y deja todo en USD aunque `localize` haya fijado HNL. Hay
  que instalar la localización del país (`l10n_hn`), que trae su propio plan y
  respeta la moneda. `make modules` ya lo hace.
- **Con demo data, Odoo 19 crea varias compañías y no se puede evitar.** El
  demo de `account` renombra la principal, le pone `generic_coa` en USD, y crea
  una compañía por localización instalada. Instalar `l10n_hn` ANTES que
  `account` no lo evita: se probó. La compañía con la moneda correcta nace
  **sin almacén**, y sin almacén no hay `stock_quant` ni inventario.
  Por eso existe `make company` (`odoo/scripts/prepare_company.py`): le crea
  el almacén y la deja como compañía por defecto del admin. `seed` depende de
  ese target, así que corre solo.
- **El seed elige la compañía por MONEDA, no `env.company`.** Y todos sus
  `search` van acotados por compañía. Odoo prohíbe el cruce de compañías: un
  `crm.team` con el mismo nombre en otra compañía revienta la creación del
  pedido con "no company crossover is allowed".
- **Verificar siempre con `make currency` antes de dar la demo por buena.**
  579 pedidos en USD se ven idénticos a 579 en HNL hasta que alguien mira.
- **Silver filtra a la compañía de la demo.** `silver_orders` se queda solo con
  los pedidos cuya COMPAÑÍA está en `demo_currency` (variable del bundle, HNL
  por defecto). Las otras compañías que crea el demo de Odoo traen sus propios
  pedidos en USD y mezclados dan sumas sin sentido. Se filtra por la moneda de
  la compañía y no la del pedido, para que un cliente con pedidos multi-moneda
  dentro de una compañía no pierda filas.
- **Desde Odoo 19 la demo data NO se instala por defecto.** `--without-demo`
  es el default; hay que pasar `--with-demo` explícitamente al crear la base.
  Sin eso `product_template` queda en 0 y el seed muere sin productos.
- **Una base creada sin demo data se bota y se recrea.** Odoo 19 tiene
  `odoo module force-demo`, pero pelea con el entrypoint de la imagen oficial
  (ver la regla de abajo), así que no vale la pena: `make reset` y de nuevo.
- **El entrypoint de la imagen añade `--db_host/--db_port/--db_user/--db_password`
  a TODA invocación de `odoo`.** `odoo server` y `odoo shell` los aceptan;
  subcomandos nuevos como `odoo module` los rechazan y fallan. No agregar
  targets que usen `odoo module`.
- **`odoo.conf` no lleva credenciales de base a propósito.** El entrypoint de
  la imagen oficial inyecta `db_host`/`db_port`/`db_user`/`db_password` como
  argumentos, pero **solo si no están en el config file**: si los agregás ahí,
  el archivo gana y `odoo/.env` deja de tener efecto en silencio.

### Portabilidad entre versiones y ediciones

La demo tiene que correr contra el Odoo de cualquier prospecto. Son dos
problemas distintos y conviene no confundirlos:

- **La edición casi no importa.** Las 17 tablas del contrato son todas de
  módulos Community core (`base`, `sale`, `sales_team`, `product`, `uom`,
  `stock`). Enterprise es un superconjunto: agrega módulos, nunca renombra ni
  quita estos. Mientras la lista no crezca hacia tablas Enterprise-only, el
  mismo pipeline sirve para ambas.
- **La versión sí importa, y se absorbe en el cargador.** No en Silver.
  `ingestion/batch/load_bronze.py` introspecciona `information_schema` del
  Odoo origen y emite NULL para las columnas del contrato que esa versión no
  tenga, así Bronze siempre sale con la misma forma.
- **En el ORM, resolver los nombres de campo por introspección, nunca fijarlos.**
  Ejemplo real: Odoo 19 renombró `res.users.groups_id` a `group_ids`, y el seed
  reventaba. El patrón es
  `campo = "group_ids" if "group_ids" in u._fields else "groups_id"`.
- **Bronze aterriza todo como STRING a propósito.** El casteo es de Silver.
  Así un cambio de tipo entre versiones de Odoo no rompe la carga.

### Esquema de Odoo (leído directo, sin ORM)

- **Los campos traducibles son JSONB desde Odoo 16.** `product_template.name`
  es `{"en_US": "...", "es_ES": "..."}`. Usar el helper `silver.txt()`, nunca
  un `SELECT name` pelado.
- **`res_users` no tiene columna `name`.** El nombre está en `res_partner`
  vía `res_users.partner_id`.
- **`product_product` no tiene columna `name`.** Está en `product_template`
  vía `product_product.product_tmpl_id`.
- **No existe columna de existencias.** `qty_available` es computado no
  almacenado. La fuente es `stock_quant` filtrando `stock_location.usage =
  'internal'`, o se cuelan ubicaciones virtuales (proveedores, pérdidas) y los
  números salen absurdos.
- Los campos computados **almacenados** sí existen: `sale_order.amount_total`,
  `amount_untaxed`, `sale_order_line.price_subtotal`. Los **no almacenados** no:
  `display_name`, `qty_available`.
- `sale_order_line` tiene filas de sección y nota: filtrar
  `COALESCE(display_type, '') = ''`.

### Replicación lógica

- **La publicación se crea ANTES del slot.** Al revés falla.
- **La lista de tablas replicadas vive en un solo lugar**: la tabla temporal
  `tablas_replicadas` de `ingestion/cdc/lakeflow_setup.sql`, que alimenta tanto el
  `REPLICA IDENTITY` como la `CREATE PUBLICATION`. No duplicar la lista.
- **El password de replicación no se quema en el `.sql`.** Entra como variable
  de psql (`-v repl_password=...`) desde `REPL_PASSWORD` en `odoo/.env`.
- **Solo se soporta el plugin `pgoutput`.**
- **No publicar el esquema completo.** Odoo tiene ~900 tablas; la publicación
  lista 17 a propósito. Agregar tablas es una decisión consciente, no un
  "por si acaso".
- **Los slots no se borran al eliminar un pipeline.** Un slot inactivo retiene
  WAL hasta llenar el disco y tumbar Odoo. Si se borra un pipeline, se dropea
  el slot a mano.
- **No apuntar a una réplica de lectura.** La replicación lógica solo funciona
  contra el primario.
- El gateway corre en **compute clásico y en modo continuo**; el pipeline de
  ingesta corre en **serverless y programado**. No se pueden invertir.

### Workspace y carriles de ingesta

- **El workspace de la demo es Free Edition: serverless-only.** El gateway de
  Lakeflow Connect exige compute clásico, así que **el carril `cdc` no corre
  ahí**. Para la demo se usa el carril `batch`.
- **Lakebase no es una salida.** Se probó: su CDC nativo (Lakehouse Sync)
  falla con `Lakebase CDF is not supported for catalogs using Default Storage`,
  y Free Edition solo tiene default storage. Tampoco sirve como base de Odoo
  (auth solo por OAuth de 1 h, rama de 512 MB, CDC a nivel de esquema).
  No volver a proponerlo.
- **Gold NO va dentro del pipeline declarativo.** Necesita constraints PK/FK y
  las materialized views no los admiten. Es una desviación consciente de la
  recomendación de Databricks, y está anotada en `databricks/src/sql/01_gold.sql`.

### Idioma: inglés en el código, español en los COMMENT

Esta división es deliberada y está fundamentada, no es gusto:

- **Identificadores en inglés**: archivos, código Python, vistas de Silver,
  tablas y columnas de Gold, funciones de Genie, claves del bundle y targets
  del Makefile. Databricks **no publica** un estándar que exija inglés —solo
  pide consistencia, minúsculas y snake_case—, pero el inglés es lo estándar
  en ingeniería y el repo ya cumplía el resto.
- **`COMMENT` y comentarios en español**: la documentación de Genie pide
  metadatos en el idioma del usuario, y el usuario final es un gerente
  comercial hondureño. Los `COMMENT` son la señal de entrada principal del
  agente. **Nunca traducirlos al inglés "por consistencia".**
- **El puente al español es la Metric View, no los sinónimos de la UI.**
  Genie usa los nombres de columna —no solo los comentarios— para hacer
  matching contra la pregunta, así que con el esquema en inglés y el gerente
  preguntando en español hacía falta un puente. Ese puente es
  `databricks/src/sql/02_metrics.sql`: en una metric view el `name` es la
  etiqueta de negocio (`Zona`, `Gerente`, `Venta`) y el `expr` la columna
  física en inglés. **Va versionado en el repo**, a diferencia de los sinónimos
  del Genie Agent, que viven solo en la UI y se pierden si alguien lo recrea.
  Genie y el dashboard consumen la metric view, no Gold directo.
- **Bronze es intocable**: son los nombres literales del esquema de Odoo
  (`sale_order`, `res_partner`, `product_template`). Ya están en inglés y
  renombrarlos rompería el contrato con el origen.
- **Los datos siguen en español** pase lo que pase: "Zona Norte", los
  departamentos hondureños, los nombres de vendedores. Eso es contenido, no
  esquema.

### Metric View (la capa semántica)

- **`synonyms` NO está soportado** en la versión YAML de este workspace: solo
  `name`, `expr` y `window`. Probado. No hace falta, porque el `name` ya separa
  la etiqueta de negocio del nombre físico.
- **Las medidas se leen con `MEASURE()`**, nunca directo, y no pueden ir en
  `WHERE` ni en `GROUP BY`:
  `SELECT \`Zona\`, MEASURE(\`Venta\`) FROM ventas GROUP BY \`Zona\``
- **El filtro `order_status = 'sale'` vive en la metric view**, así que quien la
  consulta no puede olvidarlo. Las cotizaciones y los cancelados quedan fuera
  por construcción.
- **"Ticket promedio" se define una sola vez ahí.** Si cada quien lo calcula a
  su manera, los números del chat no cuadran con los del dashboard.

### Gold y Genie

- **`LIMIT` no acepta un parámetro de función en Databricks.** Falla con
  `INVALID_LIMIT_LIKE_EXPRESSION.IS_UNFOLDABLE`. En `03_genie.sql` el recorte
  del top-N se hace con `ROW_NUMBER() OVER (...)` filtrado en un `WHERE`.
- **Los `COMMENT` son funcionales, no documentación.** Genie los usa como
  contexto principal. Nunca quitarlos ni acortarlos "para limpiar".
- **Los constraints PK/FK son informacionales pero necesarios**: Genie los usa
  para inferir joins.
- **Nombres de negocio, no técnicos**, en Gold: `territory`, `salesperson`,
  `manager`, `state`. Nunca exponer `team_id`, `user_id`, `state_id` hacia
  arriba. El vocabulario español del gerente entra por los sinónimos del
  agente, no por el nombre físico de la columna.
- **`state` es el departamento de Honduras, no el estado del pedido.** El
  estado del pedido es `order_status`. Las dos cosas traducen a "state" en
  inglés y confundirlas rompe las respuestas de Genie: el `COMMENT` de cada una
  lo aclara explícitamente y no debe borrarse.
- `fact_sales` está al **grano de línea de pedido**. Cualquier conteo de
  pedidos usa `COUNT(DISTINCT order_id)`.
- "Venta" siempre significa `subtotal` con `order_status = 'sale'`. Las cotizaciones
  (`draft`) y los cancelados no son ventas.

## Convenciones

- Comentarios y nombres de negocio **en español**; nombres de columnas técnicas
  del origen se dejan como vienen en Bronze.
- SQL en archivos versionados, no inline en notebooks. Los notebooks solo
  ejecutan los archivos.
- Los scripts Python son de stdlib pura, sin dependencias externas. Si algo
  necesita una librería, primero justificarlo.
- Un cambio en Silver que cambie nombres de columna obliga a revisar Gold y los
  trusted assets de `databricks/src/sql/03_genie.sql`. No dejarlos desincronizados.

## Qué NO hacer

- **No cambiar el pipeline de la demo al carril por API.** Se evaluó y se
  descartó: la API se topa en 2-3 ops/seg por worker. Los scripts del carril
  por API (`odoo_probe.py`, `odoo_extract.py`) son para el app Flutter, otro
  proyecto, y **no están en este repo**.
- **No agregar tablas al contrato "por si acaso".** Cada tabla nueva es más WAL
  en el carril CDC y más costo de gateway. Odoo tiene ~900 tablas; las 17 de
  `ingestion/contract.py` están elegidas.
- **No agregar dependencias de módulos Enterprise de Odoo.** La demo tiene que
  correr en Community.
- **No asumir que existe `l10n_hn`.** Verificado en Odoo 19: **sí existe**.
  `make modules` lo detecta en `ir_module_module` y cae en `account` si falta,
  así que no hay que fijarlo a mano — pero tampoco asumir que estará en otras
  versiones o ediciones.
- **No generalizar a multi-tenant todavía.** Es deuda deliberada: se hace
  cuando aparezca el segundo cliente y muestre en qué se diferencia.
  La multi-**versión** sí es requisito y ya está resuelta en el cargador.
- **No exponer el 5432 a internet.** Security group restringido al rango de
  Databricks.

## Glosario del dominio

| Término de negocio | Origen en Odoo |
|---|---|
| Zona | `crm_team` (equipo comercial) |
| Gerente | `crm_team.user_id` |
| Vendedor | `sale_order.user_id` → `res_users` → `res_partner.name` |
| Departamento | `res_partner.state_id` → `res_country_state` |
| Pedido confirmado | `sale_order.state = 'sale'` |
| Cotización | `sale_order.state = 'draft'` |
| Disponible | `stock_quant.quantity - reserved_quantity`, ubicaciones internas |

## Estado y próximos pasos

Bloqueado por dos cosas externas:

1. Acceso al Public Preview del conector PostgreSQL de Lakeflow Connect
   (se solicita al equipo de cuenta de Databricks).
2. La EC2 donde vive el sandbox, en la misma región del workspace.

Las fases 1 a 4 del RUNBOOK corren en cualquier lado mientras tanto.

Detalle completo en [RUNBOOK.md](RUNBOOK.md).