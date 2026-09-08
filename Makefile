# Demo Odoo + Databricks — atajos del RUNBOOK.
#
# El repo tiene tres dominios que no se mezclan:
#   odoo/        el sandbox (compose, config, scripts del ORM)
#   databricks/  el bundle (databricks.yml, resources/, src/)
#   ingestion/  el puente: contract.py + los dos carriles hacia bronze_pg
#
# Todo se corre desde la raíz del repo. Cada target encapsula un comando del
# RUNBOOK, incluidas las partes que se rompen fácil:
#   - el `-T` obligatorio cuando se le pasa un script a odoo shell por stdin
#   - el orden país/currency ANTES de instalar account
#   - el orden publicación ANTES del slot (dentro del .sql)
#
#   make help    → lista de targets

-include odoo/.env
export

.SHELLFLAGS := -eu -o pipefail -c
SHELL := bash

ODOO_DB          ?= demo
POSTGRES_USER    ?= odoo
POSTGRES_PASSWORD ?= odoo_dev
POSTGRES_PORT    ?= 5432
L10N             ?= l10n_hn
REPL_USER        ?= databricks_replication
REPL_PASSWORD    ?= cambiar_este_password
REPL_PUBLICATION ?= databricks_pub
REPL_SLOT        ?= databricks_slot

DATABRICKS_PROFILE ?= FREE
TARGET             ?= dev
CATALOG            ?= workspace
BRONZE_SCHEMA      ?= bronze_pg

COMPOSE := docker compose -f odoo/docker-compose.yml

# Conexión libpq al Odoo del sandbox, para las herramientas que corren fuera
# del contenedor (el cargador batch). Contra el Postgres de un cliente se
# sobreescriben estas cuatro y el cargador funciona igual.
PGENV := PGHOST=localhost PGPORT=$(POSTGRES_PORT) PGUSER=$(POSTGRES_USER) \
         PGPASSWORD=$(POSTGRES_PASSWORD) PGDATABASE=$(ODOO_DB)
PSQL    := $(COMPOSE) exec -T db psql -U $(POSTGRES_USER) -d $(ODOO_DB) -v ON_ERROR_STOP=1

.DEFAULT_GOAL := help
.PHONY: help env up down ps logs restart reset \
        db-up db-recreate wal-level psql slots slot-drop cdc-setup \
        load-bronze export-bronze \
        bundle-vars bundle-validate bundle-deploy bundle-run \
        check-version check-version-clean \
        bootstrap db-create localize modules check-l10n seed currency company \
        odoo-shell verify-cdc

## ---------------------------------------------------------------- general --

help:  ## Esta ayuda
	@echo "Demo Odoo + Databricks"
	@echo ""
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Secuencia de cero: make bootstrap && make seed && make cdc-setup"

env:  ## Crear odoo/.env a partir del ejemplo
	@test -f odoo/.env && echo "odoo/.env ya existe, no lo toco." \
	  || { cp odoo/.env.example odoo/.env; echo "Creado odoo/.env — editá las credenciales."; }

## ------------------------------------------------------------ ciclo de vida --

up:  ## Levantar Odoo + Postgres
	$(COMPOSE) up -d

down:  ## Bajar los contenedores (conserva los volúmenes)
	$(COMPOSE) down

ps:  ## Estado de los servicios
	$(COMPOSE) ps

logs:  ## Seguir los logs de Odoo
	$(COMPOSE) logs -f odoo

restart:  ## Reiniciar Odoo
	$(COMPOSE) restart odoo

reset:  ## RESET TOTAL: borra los volúmenes. Hay que rehacer bootstrap.
	@printf 'Esto BORRA la base y el filestore. Escribí "si" para continuar: '; \
	read -r ans; [ "$$ans" = "si" ] || { echo "Cancelado."; exit 1; }
	$(COMPOSE) down -v

## ------------------------------------------------------------- fases 2 y 3 --

db-up:  ## Solo Postgres, y esperar a que esté healthy
	$(COMPOSE) up -d --wait db

db-recreate:  ## Recrear el contenedor de Postgres (tras tocar el compose)
	$(COMPOSE) up -d --force-recreate --wait db

bootstrap: db-up db-create localize modules up  ## Fase 2 completa, de cero a Odoo arriba
	@echo ""
	@echo "Odoo arriba en http://localhost:$${ODOO_PORT:-8069} (admin/admin)."
	@echo "Siguiente: make seed"

db-create:  ## Crear la base con demo data, SOLO base (sin ventas ni contabilidad)
	# Solo `base`: sale_management arrastra `account` como dependencia, y con
	# demo data eso crea asientos contables. Después de eso la moneda de la
	# compañía ya no se puede cambiar, y `make localize` falla.
	$(COMPOSE) run --rm odoo odoo -d $(ODOO_DB) --with-demo \
	  -i base --load-language=es_ES --stop-after-init


localize:  ## País y moneda HNL. OBLIGATORIO antes de `make modules`.
	$(COMPOSE) run --rm -T odoo odoo shell -d $(ODOO_DB) --no-http < odoo/scripts/localize_hn.py

check-l10n:  ## ¿Existe la localización hondureña en esta base?
	@$(PSQL) -c "select name, state from ir_module_module where name like 'l10n_hn%';"

modules:  ## Localización, ventas e inventario, ya con el país fijado
	# EN DOS PASOS Y EN ESTE ORDEN. La localización va PRIMERO: instalar
	# `account` a secas aplica el plan genérico (US) a la compañía principal y
	# eso sobrescribe la moneda que fijó `localize`. Instalando la localización
	# del país antes, la compañía principal se queda con su plan y su moneda.
	# Se detecta en la base en vez de asumirla: si no existe, cae en `account`.
	@loc=$$($(PSQL) -Atc "SELECT name FROM ir_module_module WHERE name = '$(L10N)' LIMIT 1"); \
	 if [ -n "$$loc" ]; then \
	   echo ">> Localización $(L10N) disponible: se instala primero."; \
	   first="$(L10N)"; \
	 else \
	   echo ">> AVISO: $(L10N) no existe en este Odoo. Se instala account (plan genérico)."; \
	   echo "   La moneda puede quedar en USD: verificá con 'make currency'."; \
	   first="account"; \
	 fi; \
	 $(COMPOSE) run --rm odoo odoo -d $(ODOO_DB) -i "$$first" --stop-after-init
	$(COMPOSE) run --rm odoo odoo -d $(ODOO_DB) \
	  -i sale_management,stock --stop-after-init

currency:  ## Verificar la moneda y el plan de cuentas de cada compañía
	@$(PSQL) -c "SELECT c.name AS company, cur.name AS currency, \
	  COALESCE(c.chart_template,'(ninguno)') AS plan FROM res_company c \
	  JOIN res_currency cur ON cur.id = c.currency_id ORDER BY c.id;"

company:  ## Preparar la compañía de la demo (almacén y acceso del admin)
	$(COMPOSE) run --rm -T odoo odoo shell -d $(ODOO_DB) --no-http \
	  < odoo/scripts/prepare_company.py

seed: company  ## ~900 pedidos, 4 zonas, departamentos de HN (3-5 min)
	$(COMPOSE) run --rm -T odoo odoo shell -d $(ODOO_DB) --no-http < odoo/scripts/seed_sales.py

odoo-shell:  ## Shell interactivo del ORM de Odoo
	$(COMPOSE) run --rm odoo odoo shell -d $(ODOO_DB) --no-http

## ----------------------------------------------------------------- fase 4 --

wal-level:  ## Verificar que Postgres arrancó con wal_level=logical
	@$(PSQL) -c "SHOW wal_level;"

cdc-setup:  ## Usuario, replica identity, publicación y slot (en ese orden)
	@test "$(REPL_PASSWORD)" != "cambiar_este_password" \
	  || { echo "ERROR: cambiá REPL_PASSWORD en odoo/.env antes de correr esto."; exit 1; }
	$(PSQL) \
	  -v repl_user=$(REPL_USER) \
	  -v repl_password=$(REPL_PASSWORD) \
	  -v repl_publication=$(REPL_PUBLICATION) \
	  -v repl_slot=$(REPL_SLOT) \
	  -v tablas="$$(python3 ingestion/contract.py --lista)" \
	  < ingestion/cdc/lakeflow_setup.sql

psql:  ## psql interactivo contra la base de Odoo
	$(COMPOSE) exec db psql -U $(POSTGRES_USER) -d $(ODOO_DB)

## --------------------------------------------- portabilidad entre versiones --

# Levanta un Odoo de la VERSION indicada contra el MISMO Postgres, en una base
# aparte, y compara el esquema real contra ingestion/contract.py. Es la forma de
# saber si el cargador tolera esa versión sin adivinar: reporta qué columnas del
# contrato no existen ahí. Verificado contra 17, 18 y 19: 17/17 tablas en todas.
check-version:  ## Verificar el contrato contra otra versión de Odoo (VERSION=17)
	@test -n "$(VERSION)" || { echo "Usá: make check-version VERSION=17"; exit 1; }
	@echo ">> Creando base demo_v$(VERSION) con Odoo $(VERSION)..."
	@docker run --rm --network odoo-sandbox_default \
	  -e HOST=db -e PORT=5432 \
	  -e POSTGRES_USER=$(POSTGRES_USER) -e POSTGRES_PASSWORD=$(POSTGRES_PASSWORD) \
	  odoo:$(VERSION) odoo -d demo_v$(VERSION) \
	  -i base,sale_management,stock --stop-after-init >/dev/null 2>&1 \
	  || echo "   (la base ya existía o falló el arranque; se sigue con lo que haya)"
	@echo ">> Comparando el esquema contra el contrato..."
	@PGHOST=localhost PGPORT=$(POSTGRES_PORT) PGUSER=$(POSTGRES_USER) \
	  PGPASSWORD=$(POSTGRES_PASSWORD) PGDATABASE=demo_v$(VERSION) \
	  python3 ingestion/check_schema.py

check-version-clean:  ## Borrar la base de prueba de una versión (VERSION=17)
	@test -n "$(VERSION)" || { echo "Usá: make check-version-clean VERSION=17"; exit 1; }
	@$(COMPOSE) exec -T db psql -U $(POSTGRES_USER) -d postgres \
	  -c "DROP DATABASE IF EXISTS demo_v$(VERSION) WITH (FORCE);" && echo "  demo_v$(VERSION) borrada"

## ------------------------------------------------- carril batch (Bronze) --

load-bronze:  ## Cargar las 17 tablas de Odoo en bronze_pg (carril batch)
	$(PGENV) python3 ingestion/batch/load_bronze.py \
	  --profile $(DATABRICKS_PROFILE) --catalog $(CATALOG) --schema $(BRONZE_SCHEMA)

export-bronze:  ## Solo exportar los .jsonl, sin tocar Databricks (depuración)
	$(PGENV) python3 ingestion/batch/load_bronze.py --export-only --output /tmp/bronze_jsonl

## ------------------------------------------------------ bundle Databricks --
# El bundle root es databricks/ (ahí vive databricks.yml), así que estos
# targets entran a ese directorio. El CLI busca databricks.yml hacia arriba
# desde el cwd, no acepta una ruta al archivo.

# warehouse_id es un id de TU workspace: no tiene default en databricks.yml a
# propósito, para que el repo no publique infraestructura de nadie. Este target
# lo detecta y lo deja en .databricks/, que está fuera de git.
bundle-vars:  ## Detectar el SQL warehouse y escribir los overrides del bundle
	@mkdir -p databricks/.databricks/bundle/$(TARGET)
	@wid=$$(databricks warehouses list --profile $(DATABRICKS_PROFILE) -o json \
	         | python3 -c "import sys,json; w=json.load(sys.stdin); print(w[0]['id'] if w else '')"); \
	 if [ -z "$$wid" ]; then \
	   echo "ERROR: no hay ningún SQL warehouse en el workspace."; exit 1; \
	 fi; \
	 printf '{\n  "warehouse_id": "%s"\n}\n' "$$wid" \
	   > databricks/.databricks/bundle/$(TARGET)/variable-overrides.json; \
	 echo "  warehouse_id=$$wid -> databricks/.databricks/bundle/$(TARGET)/variable-overrides.json"

bundle-validate: bundle-vars  ## Validar el bundle en modo estricto
	cd databricks && databricks bundle validate --strict \
	  --target $(TARGET) --profile $(DATABRICKS_PROFILE)

bundle-deploy:  ## Desplegar el bundle al workspace
	cd databricks && databricks bundle deploy \
	  --target $(TARGET) --profile $(DATABRICKS_PROFILE)

bundle-run:  ## Correr el job completo: setup -> silver -> gold -> genie
	cd databricks && databricks bundle run medallion \
	  --target $(TARGET) --profile $(DATABRICKS_PROFILE)

## -------------------------------------------------------------- operación --

slots:  ## VIGILANCIA: slots y WAL retenido. Un slot inactivo llena el disco.
	@$(PSQL) -c "SELECT slot_name, active, \
	  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retenido \
	  FROM pg_replication_slots;"

slot-drop:  ## Borrar el slot a mano (no se borra al eliminar el pipeline)
	@printf 'Borrar el slot $(REPL_SLOT)? El CDC pierde su posición. Escribí "si": '; \
	read -r ans; [ "$$ans" = "si" ] || { echo "Cancelado."; exit 1; }
	@$(PSQL) -c "SELECT pg_drop_replication_slot('$(REPL_SLOT)');"

verify-cdc:  ## Conteos de origen, para contrastar contra bronze_pg en Databricks
	@$(PSQL) -c "SELECT 'sale_order' t, count(*) FROM sale_order \
	  UNION ALL SELECT 'sale_order_line', count(*) FROM sale_order_line \
	  UNION ALL SELECT 'res_partner', count(*) FROM res_partner \
	  UNION ALL SELECT 'stock_quant', count(*) FROM stock_quant;"
