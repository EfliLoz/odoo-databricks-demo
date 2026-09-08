-- ============================================================================
-- 01 — SILVER desde el esquema crudo de Odoo (vía Lakeflow Connect / Postgres)
--
-- Orden:   primero de los tres. 02_gold.sql depende de estas vistas.
-- Corre en: notebook SQL de Databricks, sobre un SQL warehouse.
-- Entrada: odoo_demo.bronze_pg.*  (destino del pipeline de ingesta)
-- Salida:  odoo_demo.silver.*
--
-- AJUSTAR antes de correr:
--   - el catálogo `odoo_demo` en el USE CATALOG de abajo
--   - el esquema `bronze_pg`, si tu pipeline de ingesta escribe en otro
--
-- Al leer el esquema crudo se pierden los campos "_nombre" que resuelve el
-- ORM: quedan enteros y llaves foráneas que toca unir a mano, más cuatro
-- trampas del esquema de Odoo que abajo se documentan una por una.
-- ============================================================================

USE CATALOG odoo_demo;
CREATE SCHEMA IF NOT EXISTS silver;

-- ----------------------------------------------------------------------------
-- TRAMPA 1: los campos traducibles son JSONB desde Odoo 16.
-- product_template.name no es texto, es {"en_US": "...", "es_ES": "..."}.
-- Un SELECT name directo te devuelve el JSON crudo en el dashboard.
-- Esta función normaliza y además funciona si el cliente corre una versión
-- vieja donde el campo todavía es texto plano.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION silver.txt(v STRING)
RETURNS STRING
COMMENT 'Extrae el texto de un campo traducible de Odoo (jsonb) con respaldo a es_ES, en_US o texto plano.'
RETURN COALESCE(
  get_json_object(v, '$.es_ES'),
  get_json_object(v, '$.es_419'),
  get_json_object(v, '$.en_US'),
  v
);

-- ----------------------------------------------------------------------------
-- TRAMPA 2: res_users NO tiene columna name.
-- El nombre del usuario vive en res_partner, vía res_users.partner_id.
-- Es el error número uno de quien consulta el esquema de Odoo por primera vez.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW silver.vendedores AS
SELECT
  CAST(u.id AS BIGINT)         AS vendedor_id,
  p.name                       AS vendedor,     -- res_partner.name SÍ es texto
  u.login                      AS correo,
  u.active                     AS activo
FROM bronze_pg.res_users u
LEFT JOIN bronze_pg.res_partner p ON p.id = u.partner_id;

-- ----------------------------------------------------------------------------
-- TRAMPA 3: product_product tampoco tiene name.
-- El nombre está en product_template, vía product_product.product_tmpl_id.
-- product_product solo guarda lo que distingue a la variante.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW silver.productos AS
SELECT
  CAST(pp.id AS BIGINT)                    AS producto_id,
  silver.txt(pt.name)                      AS producto,
  pp.default_code                          AS codigo,
  pp.barcode                               AS codigo_barras,
  silver.txt(pc.complete_name)             AS categoria,
  CAST(pt.list_price AS DECIMAL(18,4))     AS precio_lista,
  silver.txt(uom.name)                     AS unidad,
  pt.sale_ok                               AS vendible,
  pt.active                                AS activo
FROM bronze_pg.product_product pp
JOIN      bronze_pg.product_template pt ON pt.id = pp.product_tmpl_id
LEFT JOIN bronze_pg.product_category pc ON pc.id = pt.categ_id
LEFT JOIN bronze_pg.uom_uom          uom ON uom.id = pt.uom_id;

-- ----------------------------------------------------------------------------
-- Clientes con su geografía resuelta.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW silver.clientes AS
SELECT
  CAST(p.id AS BIGINT)      AS cliente_id,
  p.name                    AS cliente,
  p.vat                     AS rtn,
  p.city                    AS ciudad,
  st.name                   AS departamento,
  silver.txt(c.name)        AS pais,          -- res_country.name SÍ es traducible
  p.is_company              AS es_empresa,
  p.customer_rank           AS rango_cliente,
  p.active                  AS activo
FROM bronze_pg.res_partner p
LEFT JOIN bronze_pg.res_country_state st ON st.id = p.state_id
LEFT JOIN bronze_pg.res_country       c  ON c.id  = p.country_id;

-- ----------------------------------------------------------------------------
-- Zonas de venta. crm_team.user_id es el gerente responsable.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW silver.zonas AS
SELECT
  CAST(t.id AS BIGINT)      AS zona_id,
  silver.txt(t.name)        AS zona,
  CAST(t.user_id AS BIGINT) AS gerente_id,
  v.vendedor                AS gerente
FROM bronze_pg.crm_team t
LEFT JOIN silver.vendedores v ON v.vendedor_id = t.user_id;

-- ----------------------------------------------------------------------------
-- Pedidos. Los many2one llegan como enteros limpios: acá el carril directo
-- es más cómodo que la API, que devuelve [id, "etiqueta"].
--
-- amount_total y amount_untaxed SÍ existen en la tabla porque son computados
-- almacenados. En cambio display_name y qty_available NO existen: son
-- computados no almacenados y solo viven en memoria del ORM.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW silver.pedidos AS
SELECT
  CAST(o.id AS BIGINT)                   AS pedido_id,
  o.name                                 AS folio,
  o.client_order_ref                     AS referencia_app,
  CAST(o.partner_id AS BIGINT)           AS cliente_id,
  CAST(o.user_id AS BIGINT)              AS vendedor_id,
  CAST(o.team_id AS BIGINT)              AS zona_id,
  CAST(o.date_order AS TIMESTAMP)        AS fecha_pedido,
  o.state                                AS estado,
  cur.name                               AS moneda,
  CAST(o.amount_untaxed AS DECIMAL(18,2)) AS monto_sin_impuesto,
  CAST(o.amount_tax     AS DECIMAL(18,2)) AS impuesto,
  CAST(o.amount_total   AS DECIMAL(18,2)) AS monto_total
FROM bronze_pg.sale_order o
LEFT JOIN bronze_pg.res_currency cur ON cur.id = o.currency_id;

CREATE OR REPLACE VIEW silver.pedido_lineas AS
SELECT
  CAST(l.id AS BIGINT)                    AS linea_id,
  CAST(l.order_id AS BIGINT)              AS pedido_id,
  CAST(l.product_id AS BIGINT)            AS producto_id,
  CAST(l.product_uom_qty AS DECIMAL(18,3)) AS cantidad,
  CAST(l.qty_delivered   AS DECIMAL(18,3)) AS cantidad_entregada,
  CAST(l.price_unit      AS DECIMAL(18,4)) AS precio_unitario,
  CAST(l.discount        AS DECIMAL(9,4))  AS descuento_pct,
  CAST(l.price_subtotal  AS DECIMAL(18,2)) AS subtotal,
  CAST(l.price_total     AS DECIMAL(18,2)) AS total_con_impuesto
FROM bronze_pg.sale_order_line l
WHERE COALESCE(l.display_type, '') = '';   -- descarta secciones y notas

-- ----------------------------------------------------------------------------
-- TRAMPA 4: no existe una columna de existencias.
-- product_product.qty_available es computado no almacenado. La fuente real es
-- stock_quant, y hay que filtrar por ubicaciones de tipo 'internal': si sumás
-- todo, incluís ubicaciones virtuales (proveedores, clientes, pérdidas) y los
-- números salen absurdos.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW silver.inventario AS
SELECT
  CAST(q.product_id AS BIGINT)  AS producto_id,
  silver.txt(w.name)            AS almacen,
  silver.txt(loc.complete_name) AS ubicacion,
  SUM(CAST(q.quantity AS DECIMAL(18,3)))          AS existencia,
  SUM(CAST(q.reserved_quantity AS DECIMAL(18,3))) AS reservada,
  SUM(CAST(q.quantity AS DECIMAL(18,3))
      - CAST(q.reserved_quantity AS DECIMAL(18,3))) AS disponible
FROM bronze_pg.stock_quant q
JOIN      bronze_pg.stock_location  loc ON loc.id = q.location_id
LEFT JOIN bronze_pg.stock_warehouse w   ON w.id   = loc.warehouse_id
WHERE loc.usage = 'internal'
GROUP BY 1, 2, 3;

-- ============================================================================
-- De acá en adelante sigue 02_gold.sql, que consume estas vistas:
--   silver.clientes    -> dim_cliente
--   silver.zonas       -> dim_zona
--   silver.vendedores  -> dim_vendedor
--   silver.productos   -> dim_producto
--   silver.pedidos + silver.pedido_lineas -> fct_ventas
--   silver.inventario  -> fct_inventario
--
-- Y se elimina la deduplicación por write_date: el CDC ya entrega el estado
-- actual de cada fila, no un historial de extracciones.
-- ============================================================================
