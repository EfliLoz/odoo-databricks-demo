# Demo Odoo + Databricks

Pipeline de ventas e inventario desde un ERP Odoo hacia un lakehouse en
Databricks, con dashboard y consultas en lenguaje natural vía Genie.

El objetivo es comercial: mostrarle a un gerente que puede preguntar
*"¿cómo va la Zona Norte contra el año pasado?"* y recibir el número correcto,
sin tocar su Odoo y sin que nadie escriba SQL.

## Estado

Demo funcional, no producción. Depende de dos cosas que no se resuelven con
código:

- El **conector PostgreSQL de Lakeflow Connect está en Public Preview** — hay
  que solicitar acceso al equipo de cuenta de Databricks.
- El gateway debe alcanzar el puerto 5432 del Postgres de Odoo, así que el
  sandbox va en una **EC2 en la misma región del workspace**, no en una laptop.

## Requisitos

| Componente | Versión / nota |
|---|---|
| Docker + Compose | plugin `docker compose`, no `docker-compose` v1 |
| Odoo | 19 (imagen oficial) |
| PostgreSQL | 16, arrancado con `wal_level=logical` |
| Databricks | Unity Catalog, SQL warehouse, acceso al preview del conector |
| Python | 3.8+ (solo para los scripts del conector del app) |
| GNU Make | opcional, pero el `Makefile` encapsula los comandos frágiles |

## Estructura

Tres dominios autocontenidos. Lo de Odoo no se mezcla con lo de Databricks:

```
.
├── Makefile                     ← todos los comandos, con `make help`
│
├── odoo/                        EL SANDBOX
│   ├── docker-compose.yml         Odoo 19 + Postgres 16
│   ├── .env.example               credenciales y puertos
│   ├── config/odoo.conf
│   ├── addons/
│   └── scripts/                   localize_hn.py, seed_sales.py
│
├── databricks/                  EL BUNDLE  (bundle root)
│   ├── databricks.yml             variables y targets dev/prod
│   ├── resources/                 pipeline + job
│   └── src/
│       ├── pipeline/              7 materialized views de Silver
│       └── sql/                   00_setup, 01_gold, 02_genie
│
└── ingestion/                     EL PUENTE
    ├── contract.py                QUÉ se extrae de Odoo: fuente única
    ├── cdc/lakeflow_setup.sql     carril CDC (workspace de pago)
    └── batch/load_bronze.py       carril batch (Free Edition)
```

`ingestion/` es lo único que conoce los dos lados: define el contrato de las 17
tablas y lo llena por cualquiera de los dos carriles. Silver no sabe cuál
corrió, así que cambiar de carril no toca Gold, dashboard ni Genie.

## Arranque rápido

El detalle completo está en [RUNBOOK.md](RUNBOOK.md). La versión corta, desde
la raíz del repo:

```bash
make env          # crea odoo/.env a partir del ejemplo
make bootstrap    # Postgres + base con demo data + moneda HNL + módulos
make seed         # ~900 pedidos en 18 meses, 3-5 min
make load-bronze # carril batch: las 17 tablas -> bronze_pg
```

Y del lado de Databricks:

```bash
databricks bundle validate --strict --target dev --profile FREE
databricks bundle deploy            --target dev --profile FREE
databricks bundle run medallion     --target dev --profile FREE
```

`make help` lista todos los targets. Los tres pasos de `bootstrap` van en ese
orden a la fuerza: **el país y la moneda se fijan antes de instalar `account`**,
porque después ya no se pueden cambiar sin recrear la base.

Verificación antes de seguir a Databricks:

```bash
make wal-level    # tiene que decir 'logical'
make slots        # el slot creado, y cuánto WAL está reteniendo
make verify-cdc   # conteos de origen, para contrastar contra bronze_pg
```

Del lado de Databricks ya no se corren `.sql` sueltos: el orden es una
dependencia declarada en el job del bundle.

```bash
make bundle-validate    # entra a databricks/ y valida en modo estricto
make bundle-deploy
make bundle-run         # setup -> silver -> gold -> genie
```

## Flujo de datos

```
Odoo → PostgreSQL ──┬── carril cdc    (Lakeflow Connect) ──┐
                    └── carril batch  (CSV + COPY INTO)  ──┴→ bronze_pg
                                                                 ↓
                                                          silver → gold
                                                                 ↓
                                                  Dashboard AI/BI + Genie
```

Los dos carriles llenan el mismo contrato (`ingestion/contract.py`), así que
Silver no sabe cuál corrió. En un workspace Free Edition solo corre `batch`:
el gateway del carril CDC exige compute clásico.

## Decisiones de arquitectura

| Decisión | Motivo | Costo aceptado |
|---|---|---|
| CDC por Postgres, no por API | La API se topa en 2-3 ops/seg por worker; el carril directo rinde 5-10x y **sí captura borrados** | Solo aplica a clientes self-hosted |
| Modelo estrella en Gold | Genie responde mucho mejor sobre datos curados que sobre el esquema del ERP | Una capa más de SQL |
| Nombres de negocio en español | `zona`, `vendedor`, `departamento` en vez de `team_id`, `user_id`, `state_id` | Ninguno |
| Bronze desacoplado de Silver | Cambiar de carril (CDC ↔ API) no toca Gold, dashboard ni Genie | Una capa intermedia |

## Limitaciones conocidas

- **No sirve para Odoo Online ni Odoo.sh**: no hay acceso a la base. Esos
  prospectos necesitan el carril por API, que vive en el repo del app Flutter
  (`odoo_probe.py` / `odoo_extract.py`, fuera de este proyecto), y además el
  acceso a la API externa solo existe en los planes Custom de Odoo.
- **Una sola versión de Odoo por ahora.** Al saltarse el ORM, las diferencias
  de esquema entre 17, 18 y 19 son responsabilidad de Silver.
- **Un solo tenant.** Multi-cliente sería un pipeline por cliente hacia su
  propio esquema `bronze_pg_<cliente>`, uniendo en Gold.
- **La API que usa el app Flutter tiene fecha de muerte**: XML-RPC y JSON-RPC
  salen en Odoo 22 (otoño 2028) y en Online 21.1 (invierno 2027). El reemplazo
  es la External JSON-2 API, disponible desde Odoo 19.

## Pregunta de calificación comercial

Antes de agendar cualquier demo: **¿el Odoo del prospecto es self-hosted o está
en la nube de Odoo?** Si está en Odoo Online o Odoo.sh, este pipeline no aplica.
Y si está en Online con plan Standard o One App Free, tampoco hay API.