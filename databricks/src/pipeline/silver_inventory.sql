-- TRAMPA: no existe una columna de existencias. product_product.qty_available
-- es computado no almacenado. La fuente real es stock_quant, y hay que filtrar
-- ubicaciones de tipo 'internal': si sumás todo, incluís ubicaciones virtuales
-- (proveedores, clientes, pérdidas) y los números salen absurdos.
CREATE OR REFRESH MATERIALIZED VIEW silver_inventory
COMMENT 'Existencias por producto y almacén, solo ubicaciones internas.'
AS SELECT
  CAST(q.product_id AS BIGINT)                        AS product_id,
  ${catalog}.${silver_schema}.txt(w.name)             AS warehouse,
  ${catalog}.${silver_schema}.txt(loc.complete_name)  AS location,
  SUM(CAST(q.quantity AS DECIMAL(18,3)))              AS on_hand,
  SUM(CAST(q.reserved_quantity AS DECIMAL(18,3)))     AS reserved,
  SUM(CAST(q.quantity AS DECIMAL(18,3))
      - CAST(q.reserved_quantity AS DECIMAL(18,3)))   AS available
FROM ${catalog}.${bronze_schema}.stock_quant q
JOIN      ${catalog}.${bronze_schema}.stock_location  loc ON loc.id = q.location_id
LEFT JOIN ${catalog}.${bronze_schema}.stock_warehouse w   ON w.id   = loc.warehouse_id
JOIN      ${catalog}.${bronze_schema}.res_company     co  ON co.id  = q.company_id
JOIN      ${catalog}.${bronze_schema}.res_currency    ccur ON ccur.id = co.currency_id
WHERE loc.usage = 'internal'
  -- Mismo filtro de compañía que silver_orders. Sin esto el inventario sale de
  -- OTRA compañía que la demo data de Odoo deja creada, y el dashboard cruza
  -- ventas de una empresa con existencias de otra sin ningún error visible.
  AND ccur.name = '${demo_currency}'
GROUP BY 1, 2, 3;
