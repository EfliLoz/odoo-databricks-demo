-- TRAMPA: product_product tampoco tiene name. Está en product_template, vía
-- product_product.product_tmpl_id. product_product solo guarda lo que
-- distingue a la variante.
CREATE OR REFRESH MATERIALIZED VIEW silver_products (
  CONSTRAINT product_has_id EXPECT (product_id IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Catálogo de productos con categoría, unidad de medida y precio de lista.'
AS SELECT
  CAST(pp.id AS BIGINT)                            AS product_id,
  ${catalog}.${silver_schema}.txt(pt.name)         AS product,
  pp.default_code                                  AS product_code,
  pp.barcode                                       AS barcode,
  ${catalog}.${silver_schema}.txt(pc.complete_name) AS category,
  CAST(pt.list_price AS DECIMAL(18,4))             AS list_price,
  ${catalog}.${silver_schema}.txt(uom.name)        AS uom,
  CAST(pt.sale_ok AS BOOLEAN)                      AS is_sellable,
  CAST(pt.active AS BOOLEAN)                       AS is_active
FROM ${catalog}.${bronze_schema}.product_product pp
JOIN      ${catalog}.${bronze_schema}.product_template pt ON pt.id = pp.product_tmpl_id
LEFT JOIN ${catalog}.${bronze_schema}.product_category pc ON pc.id = pt.categ_id
LEFT JOIN ${catalog}.${bronze_schema}.uom_uom uom        ON uom.id = pt.uom_id;
