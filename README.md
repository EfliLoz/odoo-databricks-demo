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

```
.
├── Makefile                     ← todos los comandos del RUNBOOK, con `make help`
├── README.md
├── CLAUDE.md                    ← contexto para Claude Code
├── RUNBOOK.md                   ← el paso a paso completo, 9 fases
├── infra/
│   ├── docker-compose.yml       Odoo 19 + Postgres 16 con replicación lógica
│   ├── .env.example             credenciales y puertos (copiar a .env)
│   ├── config/odoo.conf
│   └── addons/                  montado en /mnt/extra-addons, vacío a propósito
├── odoo/
│   ├── localize_hn.py           país y moneda HNL, ANTES de instalar account
│   └── seed_ventas.py           ~900 pedidos, 4 zonas, departamentos de HN
├── postgres/
│   └── lakeflow_setup.sql       usuario, replica identity, publicación, slot
└── databricks/
    ├── 01_silver.sql            tipado, jsonb, joins del ORM
    ├── 02_gold.sql              modelo estrella + comentarios + constraints
    └── 03_genie.sql             trusted assets e instrucciones del agente
```

Los `.sql` de `databricks/` se corren en un notebook **en orden numérico**:
`02` depende de las vistas que crea `01`, y `03` de las tablas que crea `02`.

> **No están en este repo:** `odoo_probe.py` y `odoo_extract.py`, el carril por
> API. Viven en el proyecto del app Flutter, que es el que sigue necesitando la
> API porque escribe pedidos y tiene que funcionar contra clientes en SaaS.
> Para esta demo están fuera del camino crítico — ver *Limitaciones conocidas*.

## Arranque rápido

El detalle completo está en [RUNBOOK.md](RUNBOOK.md). La versión corta, desde
la raíz del repo:

```bash
make env          # crea infra/.env a partir del ejemplo — editá las credenciales
make bootstrap    # Postgres + base con demo data + moneda HNL + contabilidad
make seed         # ~900 pedidos en 18 meses, 3-5 min
make cdc-setup    # usuario de replicación, publicación y slot
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

Después, en Databricks: crear la conexión y el pipeline de Lakeflow Connect, y
correr `databricks/01_silver.sql`, `02_gold.sql` y `03_genie.sql` en ese orden.

## Flujo de datos

```
Odoo 19 → PostgreSQL → Lakeflow Connect (CDC) → bronze_pg → silver → gold
                                                                        ↓
                                                        Dashboard AI/BI + Genie
```

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