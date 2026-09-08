CREATE OR REFRESH MATERIALIZED VIEW silver_order_lines (
  CONSTRAINT line_has_order EXPECT (order_id IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Líneas de pedido, sin las filas de sección y nota.'
AS SELECT
  CAST(l.id AS BIGINT)                     AS line_id,
  CAST(l.order_id AS BIGINT)               AS order_id,
  CAST(l.product_id AS BIGINT)             AS product_id,
  CAST(l.product_uom_qty AS DECIMAL(18,3)) AS quantity,
  CAST(l.qty_delivered   AS DECIMAL(18,3)) AS quantity_delivered,
  CAST(l.price_unit      AS DECIMAL(18,4)) AS unit_price,
  CAST(l.discount        AS DECIMAL(9,4))  AS discount_pct,
  CAST(l.price_subtotal  AS DECIMAL(18,2)) AS subtotal,
  CAST(l.price_total     AS DECIMAL(18,2)) AS total_with_tax
FROM ${catalog}.${bronze_schema}.sale_order_line l
WHERE COALESCE(l.display_type, '') = '';   -- descarta secciones y notas
