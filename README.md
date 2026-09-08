# Odoo → Databricks: del ERP a preguntas en español

Un gerente comercial escribe *"¿cómo va la Zona Norte contra el año pasado?"* y
recibe el número correcto. No sabe SQL, no abre el ERP, y nadie preparó esa
consulta de antemano.

Este repositorio es el pipeline completo que hace eso posible: ventas e
inventario de un ERP **Odoo 19** replicados a un lakehouse en **Databricks**,
con un modelo estrella gobernado, un dashboard AI/BI y un agente Genie — todo
desplegable con un comando.

```
Odoo → PostgreSQL ──┬── carril cdc    (Lakeflow Connect) ──┐
                    └── carril batch  (JSON Lines)       ──┴→ bronze_pg
                                                                 ↓
                                                          silver → gold
                                                                 ↓
                                                       metric view (español)
                                                                 ↓
                                              Dashboard AI/BI + Genie Agent
```

## Por qué es interesante

No es un tutorial de medallón sobre datos limpios. El origen es el esquema
crudo de un ERP real, leído **sin pasar por el ORM**, y ahí es donde está el
trabajo de verdad:

- **`res_users` no tiene columna `name`.** Ni `product_product`. Los nombres
  viven en otras tablas y hay que unirlos a mano.
- **Los campos traducibles son JSONB desde Odoo 16.** `product_template.name`
  no es texto, es `{"en_US": "...", "es_ES": "..."}`. Un `SELECT name` pelado
  pinta JSON crudo en el dashboard.
- **No existe una columna de existencias.** `qty_available` es computado no
  almacenado; la fuente real es `stock_quant` filtrando ubicaciones internas, o
  se cuelan proveedores y pérdidas y los números salen absurdos.
- **Odoo 19 renombró `res.users.groups_id` a `group_ids`**, y con demo data
  crea tres compañías donde la que tiene la moneda correcta nace sin almacén.

Cada una de esas cuesta una tarde si se descubre en vivo. Están documentadas
como reglas duras en [CLAUDE.md](CLAUDE.md) y resueltas en el código.

## Decisiones de arquitectura

| Decisión | Por qué | Costo aceptado |
|---|---|---|
| **Contrato de ingesta explícito** ([`ingestion/contract.py`](ingestion/contract.py)) | 17 tablas elegidas, no las ~900 de Odoo. Una sola lista alimenta los dos carriles | Agregar una tabla es una decisión consciente |
| **Dos carriles hacia el mismo Bronze** | El CDC no corre en cualquier workspace; el batch sí. Silver no sabe cuál corrió | Una capa de indirección |
| **La deriva de versiones se absorbe en el cargador** | Introspecciona `information_schema` y emite NULL para columnas que esa versión no tiene. Silver queda estable entre Odoo 17, 18 y 19 | El cargador es más complejo |
| **Bronze aterriza todo como STRING** | El casteo es de Silver. Un cambio de tipo entre versiones no rompe la carga | Silver castea explícitamente |
| **Gold como tablas, no materialized views** | Necesita constraints PK/FK: Genie los usa para inferir joins | Se sale del pipeline declarativo |
| **Metric View como capa semántica** | El `name` es la etiqueta de negocio, el `expr` la columna física y los `synonyms` cubren cómo lo dice el usuario. Esquema en inglés, vocabulario en español, **versionado en el repo** y no en la UI | Una capa más |
| **Identificadores en inglés, `COMMENT` en español** | Databricks no exige inglés, pero es lo estándar. Los `COMMENT` son el contexto principal de Genie y su doc pide el idioma del usuario | Hay que mantener las dos convenciones |

## El stack, como código

Todo se despliega con un bundle. No hay nada configurado a mano en la UI:

```
databricks/
  databricks.yml                    variables y targets dev/prod
  resources/
    medallion.pipeline.yml          Silver: 7 materialized views con expectativas
    medallion.job.yml               setup → silver → gold → metrics → genie
    ventas.dashboard.yml            el dashboard AI/BI
    ventas.genie_space.yml          el Genie Agent (fuentes, sinónimos, instrucciones)
  src/
    pipeline/                       Silver
    sql/                            Gold, metric view y trusted assets
    dashboards/                     el .lvdash.json, con el botón "Ask Genie"
```

El dashboard enlaza al agente por **referencia de recurso**
(`${resources.genie_spaces.ventas.id}`), no por id fijo: el dashboard de `dev`
abre el agente de `dev`. Una sola URL para el gerente.

## Cómo correrlo

Necesitás Docker y el CLI de Databricks (≥ v0.294). El sandbox de Odoo corre
en cualquier lado; el lado Databricks necesita un workspace con Unity Catalog.

```bash
make env           # credenciales y puertos en odoo/.env
make bootstrap     # Postgres + Odoo 19 + moneda HNL + módulos
make seed          # ~580 pedidos en 18 meses, 4 zonas, inventario
make load-bronze   # carril batch: las 17 tablas → bronze_pg

make bundle-deploy # pipeline + gold + metric view + dashboard + agente
make bundle-run
```

`make help` lista los 30 targets. Cada uno encapsula algo que se rompe fácil —
el `-T` obligatorio de `odoo shell`, el orden localización→módulos, el orden
publicación→slot.

## Estructura

Tres dominios que no se mezclan:

```
odoo/         EL SANDBOX      compose, config, scripts del ORM
databricks/   EL BUNDLE       pipeline, gold, dashboard, agente
ingestion/    EL PUENTE       contrato + los dos carriles hacia bronze_pg
```

`ingestion/` es lo único que conoce los dos lados. Si algo de Databricks
necesita saber de Odoo, va ahí.

## Limitaciones conocidas

Está probado end-to-end, pero es una demo y conviene ser explícito:

- **El carril CDC necesita un workspace de pago.** El gateway de Lakeflow
  Connect exige compute clásico. En Free Edition solo corre el carril batch,
  que no captura borrados entre corridas.
- **Lakebase no es una alternativa.** Se probó: su CDC nativo falla con
  `Lakebase CDF is not supported for catalogs using Default Storage`.
- **Un solo tenant.** Multi-cliente sería un pipeline por cliente hacia su
  propio esquema, uniendo en Gold. Es deuda deliberada.
- **Multi-versión resuelto, no probado contra 17 y 18.** El cargador está
  diseñado para tolerar la deriva; solo se ejecutó contra Odoo 19.
- **No sirve para Odoo Online ni Odoo.sh**: no hay acceso a la base.

## Detalle

- [RUNBOOK.md](RUNBOOK.md) — el paso a paso completo, fase por fase
- [CLAUDE.md](CLAUDE.md) — las reglas duras: lo que rompe el pipeline y por qué
