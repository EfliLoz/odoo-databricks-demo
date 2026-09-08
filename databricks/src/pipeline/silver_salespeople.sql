-- TRAMPA: res_users NO tiene columna name. El nombre del usuario vive en
-- res_partner, vía res_users.partner_id. Es el error número uno de quien
-- consulta el esquema de Odoo por primera vez.
CREATE OR REFRESH MATERIALIZED VIEW silver_salespeople (
  CONSTRAINT salesperson_has_id EXPECT (salesperson_id IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Vendedores y gerentes, con el nombre ya resuelto desde res_partner.'
AS SELECT
  CAST(u.id AS BIGINT)      AS salesperson_id,
  p.name                    AS salesperson,   -- res_partner.name SÍ es texto
  u.login                   AS email,
  CAST(u.active AS BOOLEAN) AS is_active
FROM ${catalog}.${bronze_schema}.res_users u
LEFT JOIN ${catalog}.${bronze_schema}.res_partner p ON p.id = u.partner_id;
