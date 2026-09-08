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
make env          # crea infra/.env a partir de infra/.env.example
$EDITOR infra/.env
```

`infra/.env` lleva las credenciales de Postgres, los puertos publicados y —
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
| 2 | `db-create` | crea la base con demo data e idioma es_ES, **sin contabilidad** |
| 3 | `localize` | fija país Honduras y moneda HNL (`odoo/localize_hn.py`) |
| 4 | `account` | instala contabilidad, que ya agarra la localización del país |

El paso 3 **antes** del 4 no es negociable: sin país configurado, `account`
cae en `l10n_generic_coa` (US) y te quedás en dólares. Y la moneda de la
compañía no se puede cambiar una vez que hay asientos contables — si te
equivocás, `make reset` y volver a empezar.

Cada paso también corre suelto (`make db-create`, `make localize`, …) si algo
falla a la mitad y querés retomar.

Verificar si existe localización hondureña:

```bash
make check-l10n
```

Si existe, instalarlo con `-i l10n_hn` en vez de `account` y trae plan de
cuentas e impuestos hondureños. Si no existe, `make account` tal cual deja el
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

Por debajo es `docker compose run --rm -T odoo odoo shell -d demo --no-http <
odoo/seed_ventas.py`. **El `-T` es obligatorio.** Sin él compose no conecta el
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

El password sale de `REPL_PASSWORD` en `infra/.env`, no está quemado en el
`.sql`. `make cdc-setup` se niega a correr mientras siga en el valor de ejemplo.

---

## Fase 5 — Lakeflow Connect

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

```
databricks/01_silver.sql   → tipado, jsonb, joins del ORM
databricks/02_gold.sql     → estrella + comentarios + constraints
```

Correr **en orden numérico** en un notebook SQL: `02` consume las vistas que
crea `01`. Cada archivo declara en su encabezado qué consume, qué produce y
qué hay que ajustar (el catálogo `odoo_demo`, el esquema `bronze_pg`).

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
databricks/03_genie.sql    → siete trusted assets + el bloque de Instructions
```

Crear el agente sobre `gold.metricas_ventas`, `gold.fct_ventas`,
`gold.fct_inventario` y las cuatro dimensiones. Después:

1. **Instrucciones** — copiar el bloque comentado al final de `databricks/03_genie.sql`.
   Cortas y específicas. Nunca para tapar metadata faltante: si se resuelve con
   un `COMMENT` en la columna, va en el `COMMENT`.
2. **Trusted assets** — agregar las siete funciones de `databricks/03_genie.sql`.
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

Dashboard AI/BI sobre `gold.metricas_ventas`. Mínimo:

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
| `infra/docker-compose.yml` | 1 | EC2 |
| `infra/.env.example` | 1 | `make env` → `infra/.env` |
| `infra/config/odoo.conf` | 1 | montado en el contenedor |
| `odoo/localize_hn.py` | 2 | `make localize` |
| `odoo/seed_ventas.py` | 3 | `make seed` |
| `postgres/lakeflow_setup.sql` | 4 | `make cdc-setup` |
| `databricks/01_silver.sql` | 6 | notebook Databricks |
| `databricks/02_gold.sql` | 6 | notebook Databricks |
| `databricks/03_genie.sql` | 7 | notebook Databricks |

Los scripts del carril por API (`odoo_probe.py`, `odoo_extract.py`) no están en
este repo — ver *Fuera del alcance de la demo*.
