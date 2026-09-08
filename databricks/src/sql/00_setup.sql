-- ============================================================================
-- 00 — Esquemas y la función de campos traducibles.
--
-- Corre ANTES del pipeline de Silver: las vistas usan silver.txt() y un
-- pipeline declarativo no puede crear UDFs.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS IDENTIFIER(:catalog || '.' || :silver_schema);
CREATE SCHEMA IF NOT EXISTS IDENTIFIER(:catalog || '.' || :gold_schema);

-- TRAMPA: los campos traducibles de Odoo son JSONB desde la versión 16.
-- product_template.name no es texto, es {"en_US": "...", "es_ES": "..."}.
-- Un SELECT name pelado pinta JSON crudo en el dashboard.
--
-- El COALESCE final devuelve el valor tal cual, así que esto también funciona
-- contra un Odoo 15 o anterior donde el campo todavía es texto plano. Esa es
-- la razón de que exista la función en vez de inlinear get_json_object.
CREATE OR REPLACE FUNCTION
  IDENTIFIER(:catalog || '.' || :silver_schema || '.txt')(v STRING)
RETURNS STRING
COMMENT 'Extrae el texto de un campo traducible de Odoo (jsonb) con respaldo a es_ES, es_419, en_US o texto plano.'
RETURN COALESCE(
  get_json_object(v, '$.es_ES'),
  get_json_object(v, '$.es_419'),
  get_json_object(v, '$.en_US'),
  v
);
