-- crm_team es el equipo comercial (la "zona" del negocio); su user_id es el
-- gerente responsable.
CREATE OR REFRESH MATERIALIZED VIEW silver_territories (
  CONSTRAINT territory_has_id EXPECT (territory_id IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Zonas de venta con su gerente responsable.'
AS SELECT
  CAST(t.id AS BIGINT)                     AS territory_id,
  ${catalog}.${silver_schema}.txt(t.name)  AS territory,
  CAST(t.user_id AS BIGINT)                AS manager_id,
  v.salesperson                            AS manager
FROM ${catalog}.${bronze_schema}.crm_team t
LEFT JOIN silver_salespeople v ON v.salesperson_id = CAST(t.user_id AS BIGINT);
