# Demo Odoo + Databricks — atajos del RUNBOOK.
#
# Todo se corre desde la raíz del repo. Cada target encapsula un comando del
# RUNBOOK, incluidas las partes que se rompen fácil:
#   - el `-T` obligatorio cuando se le pasa un script a odoo shell por stdin
#   - el orden país/moneda ANTES de instalar account
#   - el orden publicación ANTES del slot (dentro del .sql)
#
#   make help    → lista de targets

-include infra/.env
export

.SHELLFLAGS := -eu -o pipefail -c
SHELL := bash

ODOO_DB          ?= demo
POSTGRES_USER    ?= odoo
REPL_USER        ?= databricks_replication
REPL_PASSWORD    ?= cambiar_este_password
REPL_PUBLICATION ?= databricks_pub
REPL_SLOT        ?= databricks_slot

COMPOSE := docker compose -f infra/docker-compose.yml
PSQL    := $(COMPOSE) exec -T db psql -U $(POSTGRES_USER) -d $(ODOO_DB) -v ON_ERROR_STOP=1

.DEFAULT_GOAL := help
.PHONY: help env up down ps logs restart reset \
        db-up db-recreate wal-level psql slots slot-drop cdc-setup \
        bootstrap db-create localize account check-l10n seed \
        odoo-shell verify-cdc

## ---------------------------------------------------------------- general --

help:  ## Esta ayuda
	@echo "Demo Odoo + Databricks"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Secuencia de cero: make bootstrap && make seed && make cdc-setup"

env:  ## Crear infra/.env a partir del ejemplo
	@test -f infra/.env && echo "infra/.env ya existe, no lo toco." \
	  || { cp infra/.env.example infra/.env; echo "Creado infra/.env — editá las credenciales."; }

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

bootstrap: db-up db-create localize account up  ## Fase 2 completa, de cero a Odoo arriba
	@echo ""
	@echo "Odoo arriba en http://localhost:$${ODOO_PORT:-8069} (admin/admin)."
	@echo "Siguiente: make seed"

db-create:  ## Crear la base con demo data (sin contabilidad todavía)
	$(COMPOSE) run --rm odoo odoo -d $(ODOO_DB) \
	  -i base,sale_management,stock --load-language=es_ES --stop-after-init

localize:  ## País y moneda HNL. OBLIGATORIO antes de `make account`.
	$(COMPOSE) run --rm -T odoo odoo shell -d $(ODOO_DB) --no-http < odoo/localize_hn.py

check-l10n:  ## ¿Existe la localización hondureña en esta base?
	@$(PSQL) -c "select name, state from ir_module_module where name like 'l10n_hn%';"

account:  ## Instalar contabilidad (agarra la localización del país ya fijado)
	$(COMPOSE) run --rm odoo odoo -d $(ODOO_DB) -i account --stop-after-init

seed:  ## ~900 pedidos, 4 zonas, departamentos de HN (3-5 min)
	$(COMPOSE) run --rm -T odoo odoo shell -d $(ODOO_DB) --no-http < odoo/seed_ventas.py

odoo-shell:  ## Shell interactivo del ORM de Odoo
	$(COMPOSE) run --rm odoo odoo shell -d $(ODOO_DB) --no-http

## ----------------------------------------------------------------- fase 4 --

wal-level:  ## Verificar que Postgres arrancó con wal_level=logical
	@$(PSQL) -c "SHOW wal_level;"

cdc-setup:  ## Usuario, replica identity, publicación y slot (en ese orden)
	@test "$(REPL_PASSWORD)" != "cambiar_este_password" \
	  || { echo "ERROR: cambiá REPL_PASSWORD en infra/.env antes de correr esto."; exit 1; }
	$(PSQL) \
	  -v repl_user=$(REPL_USER) \
	  -v repl_password=$(REPL_PASSWORD) \
	  -v repl_publication=$(REPL_PUBLICATION) \
	  -v repl_slot=$(REPL_SLOT) \
	  < postgres/lakeflow_setup.sql

psql:  ## psql interactivo contra la base de Odoo
	$(COMPOSE) exec db psql -U $(POSTGRES_USER) -d $(ODOO_DB)

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
