-- `state` es el departamento de Honduras (la división geográfica), no el
-- estado de un pedido. Viene de res_country_state, igual que en Odoo.
CREATE OR REFRESH MATERIALIZED VIEW silver_customers (
  CONSTRAINT customer_has_id EXPECT (customer_id IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Clientes con su geografía resuelta a departamento y país.'
AS SELECT
  CAST(p.id AS BIGINT)                      AS customer_id,
  p.name                                    AS customer,
  p.vat                                     AS tax_id,
  p.city                                    AS city,
  st.name                                   AS state,
  ${catalog}.${silver_schema}.txt(c.name)   AS country,  -- res_country.name SÍ es traducible
  CAST(p.is_company AS BOOLEAN)             AS is_company,
  CAST(p.customer_rank AS INT)              AS customer_rank,
  CAST(p.active AS BOOLEAN)                 AS is_active
FROM ${catalog}.${bronze_schema}.res_partner p
LEFT JOIN ${catalog}.${bronze_schema}.res_country_state st ON st.id = p.state_id
LEFT JOIN ${catalog}.${bronze_schema}.res_country       c  ON c.id  = p.country_id;
