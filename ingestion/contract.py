"""
CONTRATO DE BRONZE — la única fuente de verdad sobre qué se extrae de Odoo.

Todos los carriles de ingesta escriben el mismo contrato en `bronze_pg`, y
Silver lee de ahí sin saber cuál corrió. Cambiar de carril no toca Silver, Gold,
el dashboard ni Genie.

    carril `cdc`    → Lakeflow Connect, contra el Postgres del cliente.
                      Prospectos reales. Necesita workspace de pago
                      (el gateway exige compute clásico) y alcanzar el 5432.
    carril `batch`  → exporta a CSV y carga con COPY INTO.
                      La demo en Free Edition, donde el carril CDC no corre.
    carril `api`    → XML-RPC / JSON-2, en el repo del app Flutter. No acá.

--------------------------------------------------------------------------
POR QUÉ ESTE ARCHIVO EXISTE
--------------------------------------------------------------------------

La demo tiene que funcionar contra cualquier Odoo del prospecto: Community o
Enterprise, versión 17, 18 o 19. Esas dos cosas se comportan muy distinto:

  EDICIÓN — casi no importa. Las 17 tablas de abajo son todas de módulos
  Community core (`base`, `sale`, `sales_team`, `product`, `uom`, `stock`).
  Enterprise es un superconjunto: agrega módulos, nunca renombra ni quita
  estos. Mientras la lista no crezca hacia tablas Enterprise-only, el mismo
  pipeline sirve para las dos ediciones.

  VERSIÓN — sí importa. Al leer el esquema crudo, saltándose el ORM, la deriva
  entre 17, 18 y 19 es nuestra. Se absorbe ACÁ y en ningún otro lado: el
  cargador introspecciona `information_schema.columns` del Odoo origen y
  rellena con NULL las columnas que esa versión no tenga. Bronze siempre sale
  con la misma forma, y Silver no necesita una rama por versión.

Bronze aterriza TODO como texto, a propósito: es la capa cruda y el casteo es
responsabilidad de Silver, que ya lo hace explícito. Eso también evita que un
cambio de tipo entre versiones de Odoo rompa la carga.

--------------------------------------------------------------------------
CÓMO SE MODIFICA
--------------------------------------------------------------------------

Agregar una columna acá es barato. Agregar una TABLA es una decisión
consciente: cada tabla nueva es más WAL en el carril CDC y más costo de
gateway. Odoo tiene ~900 tablas; estas 17 están elegidas, no son un "por si
acaso". Antes de sumar una, verificá que Silver de verdad la necesite.

Si agregás una columna que solo existe en Odoo 19, no pasa nada: en un Odoo 17
saldrá NULL y Silver la verá vacía. Ese es justamente el punto.
"""

# Cada entrada: nombre de tabla -> columnas que Silver necesita.
# El comentario dice para qué la usa Silver, para que se pueda podar con
# criterio en vez de arrastrar columnas "porque estaban".
TABLES = {
    # --- Ventas -----------------------------------------------------------
    "sale_order": [
        "id",                 # pedido_id
        "name",               # folio
        "client_order_ref",   # referencia del app Flutter
        "partner_id",         # -> res_partner
        "user_id",            # vendedor -> res_users
        "team_id",            # zona -> crm_team
        "date_order",
        "state",              # 'sale' = venta; 'draft' = cotización
        "currency_id",
        "amount_untaxed",     # computado ALMACENADO: sí existe en la tabla
        "amount_tax",
        "amount_total",
        "company_id",        # la demo trabaja sobre UNA compañía: ver silver_orders
    ],
    "sale_order_line": [
        "id",
        "order_id",
        "product_id",
        "product_uom_qty",
        "qty_delivered",
        "price_unit",
        "discount",
        "price_subtotal",     # la columna por defecto para sumar ventas
        "price_total",
        "display_type",       # filas de sección y nota: Silver las descarta
    ],
    # --- Terceros y geografía --------------------------------------------
    "res_partner": [
        "id",
        "name",               # res_partner.name SÍ es texto plano
        "vat",                # RTN hondureño
        "city",
        "state_id",           # departamento
        "country_id",
        "is_company",
        "customer_rank",
        "active",
    ],
    "res_users": [
        "id",
        "partner_id",         # res_users NO tiene columna name: está acá
        "login",
        "active",
    ],
    "res_company": ["id", "name", "currency_id"],
    "res_country": ["id", "name"],            # traducible (jsonb en Odoo 16+)
    "res_country_state": ["id", "name", "code", "country_id"],
    "res_currency": ["id", "name"],
    "crm_team": [
        "id",
        "name",
        "user_id",            # el gerente de la zona
    ],
    # --- Producto ---------------------------------------------------------
    "product_product": [
        "id",
        "product_tmpl_id",    # product_product NO tiene name: está en template
        "default_code",
        "barcode",
        "active",
    ],
    "product_template": [
        "id",
        "name",               # traducible (jsonb en Odoo 16+)
        "categ_id",
        "list_price",
        "uom_id",
        "sale_ok",
        "active",
    ],
    "product_category": ["id", "complete_name"],
    "product_pricelist": ["id", "name", "currency_id"],
    "uom_uom": ["id", "name"],
    # --- Inventario -------------------------------------------------------
    "stock_quant": [
        "id",
        "product_id",
        "location_id",
        "quantity",           # única fuente real: qty_available no existe
        "reserved_quantity",
    ],
    "stock_location": [
        "id",
        "complete_name",
        "usage",              # Silver filtra usage = 'internal'
        "warehouse_id",
    ],
    "stock_warehouse": ["id", "name", "code"],
}

# El carril CDC publica exactamente estas tablas. Se DERIVA del contrato, no se
# repite: `make cdc-setup` corre este módulo con --lista y le pasa el resultado
# a lakeflow_setup.sql como variable de psql. Si acá se agrega una tabla, el
# carril CDC la publica sin tocar el .sql.
REPLICATED_TABLES = sorted(TABLES)


def column_expressions(table_name, actual_columns):
    """
    Devuelve la lista de expresiones SELECT para una tabla, resolviendo la
    deriva entre versiones de Odoo.

    `actual_columns` es lo que devolvió information_schema para esa tabla en
    el Odoo origen. Las columnas del contrato que no existan en esa versión se
    emiten como NULL con su nombre, para que Bronze mantenga siempre la misma
    forma.

    Todo sale casteado a text: Bronze es la capa cruda y el tipado es
    responsabilidad de Silver.
    """
    existing = {c.lower() for c in actual_columns}
    exprs = []
    for col in TABLES[table_name]:
        if col.lower() in existing:
            exprs.append(f'CAST("{col}" AS text) AS "{col}"')
        else:
            exprs.append(f'CAST(NULL AS text) AS "{col}"')
    return exprs


def missing_columns(table_name, actual_columns):
    """Columnas del contrato ausentes en esta versión de Odoo."""
    existing = {c.lower() for c in actual_columns}
    return [c for c in TABLES[table_name] if c.lower() not in existing]


if __name__ == "__main__":
    import sys

    if "--lista" in sys.argv:
        # Lista separada por comas para `psql -v tablas=...`.
        print(",".join(REPLICATED_TABLES))
    else:
        print(f"{len(TABLES)} tablas, "
              f"{sum(len(c) for c in TABLES.values())} columnas")
        for t in REPLICATED_TABLES:
            print(f"  {t:<22} {len(TABLES[t])} columnas")
