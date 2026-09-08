# CLAUDE.md

Contexto para trabajar en este repositorio.

## Qué es esto

Pipeline Odoo → Databricks para una demo comercial: ventas e inventario de un
ERP Odoo replicados a un lakehouse, con dashboard AI/BI y un agente Genie que
responde en español. El público final es un gerente comercial, no un analista.

```
Odoo 19 → PostgreSQL → Lakeflow Connect (CDC) → bronze_pg → silver → gold
                                                                       ↓
                                                       Dashboard AI/BI + Genie
```

## Estructura

```
Makefile              todos los comandos de abajo, con `make help`
infra/                docker-compose.yml, .env.example, config/odoo.conf, addons/
odoo/                 localize_hn.py, seed_ventas.py  (corren en `odoo shell`)
postgres/             lakeflow_setup.sql              (corre en `psql`)
databricks/           01_silver.sql, 02_gold.sql, 03_genie.sql  (notebook SQL)
```

Las credenciales viven en `infra/.env` (no versionado, plantilla en
`infra/.env.example`). Está junto al compose a propósito: Compose busca el
`.env` en el directorio del archivo de compose, no en la raíz del repo.

## Comandos

Todo desde la **raíz del repo**, vía `make`. Los targets encapsulan las partes
que se rompen fácil, así que preferilos a escribir los comandos a mano.

```bash
make help          # lista de targets

make env           # crear infra/.env desde el ejemplo
make bootstrap     # db-up → db-create → localize → account → up
make seed          # ~900 pedidos de demo
make cdc-setup     # usuario de replicación, publicación y slot

make up / down / logs / ps / restart
make reset         # down -v: borra volúmenes, pide confirmación

make wal-level     # ¿arrancó Postgres en logical?
make slots         # VIGILANCIA: slots y WAL retenido
make slot-drop     # borrar el slot a mano
make verify-cdc    # conteos de origen para contrastar contra bronze_pg
make psql          # psql interactivo
make odoo-shell    # shell del ORM
```

Si hace falta el comando crudo, sale de `make -n <target>`.

Los `.sql` de `databricks/` se corren en un notebook, **en orden numérico**.
`02_gold.sql` depende de las vistas que crea `01_silver.sql`, y `03_genie.sql`
de las tablas que crea `02_gold.sql`.

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
- **Una base creada sin demo data no se puede rellenar después.** Se bota y se
  recrea.
- **`odoo.conf` no lleva credenciales de base a propósito.** El entrypoint de
  la imagen oficial inyecta `db_host`/`db_port`/`db_user`/`db_password` como
  argumentos, pero **solo si no están en el config file**: si los agregás ahí,
  el archivo gana y `infra/.env` deja de tener efecto en silencio.

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
  `tablas_replicadas` de `postgres/lakeflow_setup.sql`, que alimenta tanto el
  `REPLICA IDENTITY` como la `CREATE PUBLICATION`. No duplicar la lista.
- **El password de replicación no se quema en el `.sql`.** Entra como variable
  de psql (`-v repl_password=...`) desde `REPL_PASSWORD` en `infra/.env`.
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

### Gold y Genie

- **Los `COMMENT` son funcionales, no documentación.** Genie los usa como
  contexto principal. Nunca quitarlos ni acortarlos "para limpiar".
- **Los constraints PK/FK son informacionales pero necesarios**: Genie los usa
  para inferir joins.
- **Nombres de negocio en español** en Gold: `zona`, `vendedor`, `gerente`,
  `departamento`. Nunca exponer `team_id`, `user_id`, `state_id` hacia arriba.
- `fct_ventas` está al **grano de línea de pedido**. Cualquier conteo de
  pedidos usa `COUNT(DISTINCT pedido_id)`.
- "Venta" siempre significa `subtotal` con `estado = 'sale'`. Las cotizaciones
  (`draft`) y los cancelados no son ventas.

## Convenciones

- Comentarios y nombres de negocio **en español**; nombres de columnas técnicas
  del origen se dejan como vienen en Bronze.
- SQL en archivos versionados, no inline en notebooks. Los notebooks solo
  ejecutan los archivos.
- Los scripts Python son de stdlib pura, sin dependencias externas. Si algo
  necesita una librería, primero justificarlo.
- Un cambio en Silver que cambie nombres de columna obliga a revisar Gold y los
  trusted assets de `03_genie.sql`. No dejarlos desincronizados.

## Qué NO hacer

- **No cambiar el pipeline de la demo al carril por API.** Se evaluó y se
  descartó: la API se topa en 2-3 ops/seg por worker. Los scripts del carril
  por API (`odoo_probe.py`, `odoo_extract.py`) son para el app Flutter, otro
  proyecto, y **no están en este repo**.
- **No agregar dependencias de módulos Enterprise de Odoo.** La demo tiene que
  correr en Community.
- **No asumir que existe `l10n_hn`.** Verificar en la base antes de usarlo;
  si no existe se usa el plan genérico con moneda HNL.
- **No generalizar a multi-tenant ni multi-versión todavía.** Es deuda
  deliberada: se hace cuando aparezca el segundo cliente y muestre en qué se
  diferencia.
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