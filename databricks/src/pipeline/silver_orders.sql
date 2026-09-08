-- amount_total y amount_untaxed SÍ existen en la tabla porque son computados
-- ALMACENADOS. En cambio display_name y qty_available NO: son computados no
-- almacenados y solo viven en memoria del ORM.
CREATE OR REFRESH MATERIALIZED VIEW silver_orders (
  CONSTRAINT order_has_id     EXPECT (order_id IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT status_is_known  EXPECT (order_status IN ('draft','sent','sale','cancel','done'))
)
COMMENT 'Cabecera de pedidos de venta.'
AS SELECT
  CAST(o.id AS BIGINT)                    AS order_id,
  o.name                                  AS order_ref,
  o.client_order_ref                      AS external_ref,
  CAST(o.partner_id AS BIGINT)            AS customer_id,
  CAST(o.user_id AS BIGINT)               AS salesperson_id,
  CAST(o.team_id AS BIGINT)               AS territory_id,
  CAST(o.date_order AS TIMESTAMP)         AS ordered_at,
  o.state                                 AS order_status,
  cur.name                                AS currency,
  CAST(o.amount_untaxed AS DECIMAL(18,2)) AS amount_untaxed,
  CAST(o.amount_tax     AS DECIMAL(18,2)) AS tax_amount,
  CAST(o.amount_total   AS DECIMAL(18,2)) AS amount_total
FROM ${catalog}.${bronze_schema}.sale_order o
LEFT JOIN ${catalog}.${bronze_schema}.res_currency cur ON cur.id = o.currency_id;
