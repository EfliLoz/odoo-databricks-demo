-- ============================================================================
-- 03 — Genie Agent de ventas: trusted assets
--
-- Orden:   DESPUÉS de 01_gold.sql. Es la tarea `genie` del job `medallion`.
-- Corre en: tarea SQL del bundle, sobre un SQL warehouse.
-- Entrada: las tablas de Gold de :catalog.:gold_schema (fijados por USE).
-- Salida:  siete funciones que se registran como trusted assets del agente,
--          más el bloque de Instructions al final para copiar en la UI.
--
-- Cuando Genie usa una de estas funciones, la respuesta sale con etiqueta
-- "Trusted": una señal de confianza que el usuario no técnico no puede sacar
-- leyendo el SQL generado. Para la demo en vivo, prepará las preguntas que vas
-- a hacer y volvelas trusted. Así la demo deja de ser una ruleta.
--
-- IDIOMA: nombres en inglés, COMMENT en español. Genie NO ve el cuerpo de la
-- función: se enruta por el COMMENT de la función y de sus parámetros, así que
-- el idioma del nombre es indiferente para el matching. Los COMMENT sí importan
-- y van en el idioma del gerente.
--
-- Los parámetros van con prefijo p_ para no chocar con nombres de columna.
-- ============================================================================

USE CATALOG IDENTIFIER(:catalog);
USE SCHEMA  IDENTIFIER(:gold_schema);

-- 1 ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sales_by_territory(
  p_from DATE COMMENT 'Fecha inicial del período',
  p_to   DATE COMMENT 'Fecha final del período'
)
RETURNS TABLE (territory STRING, manager STRING, orders BIGINT, sales DECIMAL(18,2))
COMMENT 'Ventas confirmadas agrupadas por zona comercial y su gerente, dentro de un rango de fechas. Úsese para "cómo van las ventas por zona" o "qué zona vendió más".'
RETURN
  SELECT t.territory, t.manager,
         COUNT(DISTINCT s.order_id) AS orders,
         SUM(s.subtotal)            AS sales
  FROM fact_sales s
  JOIN dim_territory t ON t.territory_id = s.territory_id
  WHERE s.order_status = 'sale' AND s.sale_date BETWEEN p_from AND p_to
  GROUP BY t.territory, t.manager
  ORDER BY sales DESC;

-- 2 ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION top_salespeople(
  p_from  DATE COMMENT 'Fecha inicial',
  p_to    DATE COMMENT 'Fecha final',
  p_limit INT DEFAULT 10 COMMENT 'Cuántos vendedores devolver'
)
RETURNS TABLE (salesperson STRING, territory STRING, orders BIGINT,
               sales DECIMAL(18,2), avg_ticket DECIMAL(18,2))
COMMENT 'Ranking de vendedores por monto vendido en un período, con su zona y ticket promedio. Úsese para "mejores vendedores" o "quién vendió más".'
RETURN
  -- Databricks exige que LIMIT sea una constante plegable, así que un
  -- parámetro de función NO puede ir ahí (INVALID_LIMIT_LIKE_EXPRESSION).
  -- El recorte se hace con ROW_NUMBER en un WHERE, que sí lo admite.
  SELECT salesperson, territory, orders, sales, avg_ticket
  FROM (
    SELECT sp.salesperson, t.territory,
           COUNT(DISTINCT s.order_id) AS orders,
           SUM(s.subtotal)            AS sales,
           CAST(SUM(s.subtotal) / NULLIF(COUNT(DISTINCT s.order_id), 0) AS DECIMAL(18,2))
        AS avg_ticket,
           ROW_NUMBER() OVER (ORDER BY SUM(s.subtotal) DESC) AS rn
    FROM fact_sales s
    JOIN dim_salesperson sp ON sp.salesperson_id = s.salesperson_id
    LEFT JOIN dim_territory t ON t.territory_id = s.territory_id
    WHERE s.order_status = 'sale' AND s.sale_date BETWEEN p_from AND p_to
    GROUP BY sp.salesperson, t.territory
  )
  WHERE rn <= p_limit
  ORDER BY sales DESC;

-- 3 ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION top_products(
  p_from DATE COMMENT 'Fecha inicial',
  p_to   DATE COMMENT 'Fecha final',
  p_limit INT DEFAULT 15 COMMENT 'Cuántos productos devolver'
)
RETURNS TABLE (product STRING, category STRING,
               units DECIMAL(18,3), sales DECIMAL(18,2))
COMMENT 'Productos más vendidos por monto en un período, con unidades y categoría. Úsese para "qué se vende más" o "top productos".'
RETURN
  -- Mismo motivo que en top_salespeople: LIMIT no acepta un parámetro.
  SELECT product, category, units, sales
  FROM (
    SELECT p.product, p.category,
           SUM(s.quantity) AS units,
           SUM(s.subtotal) AS sales,
           ROW_NUMBER() OVER (ORDER BY SUM(s.subtotal) DESC) AS rn
    FROM fact_sales s
    JOIN dim_product p ON p.product_id = s.product_id
    WHERE s.order_status = 'sale' AND s.sale_date BETWEEN p_from AND p_to
    GROUP BY p.product, p.category
  )
  WHERE rn <= p_limit
  ORDER BY sales DESC;

-- 4 ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sales_year_over_year(
  p_year INT COMMENT 'Año a comparar contra el anterior'
)
RETURNS TABLE (sale_month INT, sales_current DECIMAL(18,2),
               sales_previous DECIMAL(18,2), change_pct DECIMAL(9,2))
COMMENT 'Ventas mensuales del año indicado contra el año anterior, con variación porcentual. Úsese para "cómo vamos contra el año pasado".'
RETURN
  WITH base AS (
    SELECT sale_year, sale_month, SUM(subtotal) AS sales
    FROM fact_sales
    WHERE order_status = 'sale' AND sale_year IN (p_year, p_year - 1)
    GROUP BY sale_year, sale_month
  )
  SELECT COALESCE(a.sale_month, b.sale_month) AS sale_month,
         a.sales AS sales_current,
         b.sales AS sales_previous,
         CAST(100.0 * (a.sales - b.sales) / NULLIF(b.sales, 0) AS DECIMAL(9,2))
      AS change_pct
  FROM (SELECT * FROM base WHERE sale_year = p_year) a
  FULL OUTER JOIN (SELECT * FROM base WHERE sale_year = p_year - 1) b
    ON a.sale_month = b.sale_month
  ORDER BY sale_month;

-- 5 ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sales_by_state(
  p_from DATE COMMENT 'Fecha inicial',
  p_to   DATE COMMENT 'Fecha final'
)
RETURNS TABLE (state STRING, customers BIGINT, sales DECIMAL(18,2))
COMMENT 'Ventas confirmadas por departamento de Honduras, con cuántos clientes distintos compraron. Úsese para preguntas geográficas, por departamento o de cobertura regional.'
RETURN
  SELECT c.state,
         COUNT(DISTINCT s.customer_id) AS customers,
         SUM(s.subtotal)               AS sales
  FROM fact_sales s
  JOIN dim_customer c ON c.customer_id = s.customer_id
  WHERE s.order_status = 'sale' AND s.sale_date BETWEEN p_from AND p_to
  GROUP BY c.state
  ORDER BY sales DESC;

-- 6 ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stockout_risk(
  p_days INT DEFAULT 30 COMMENT 'Ventana de venta reciente a considerar'
)
RETURNS TABLE (product STRING, warehouse STRING, available DECIMAL(18,3),
               sold_in_period DECIMAL(18,3), days_of_cover DECIMAL(9,1))
COMMENT 'Productos con inventario bajo frente a su venta reciente, con días de cobertura estimados. Úsese para "qué se me va a acabar" o "riesgo de quiebre de stock".'
RETURN
  WITH recent AS (
    SELECT product_id, SUM(quantity) AS units
    FROM fact_sales
    WHERE order_status = 'sale' AND sale_date >= CURRENT_DATE() - p_days
    GROUP BY product_id
  )
  SELECT p.product, i.warehouse, i.available,
         COALESCE(r.units, 0) AS sold_in_period,
         CAST(i.available / NULLIF(r.units / p_days, 0) AS DECIMAL(9,1))
      AS days_of_cover
  FROM fact_inventory i
  JOIN dim_product p ON p.product_id = i.product_id
  LEFT JOIN recent r ON r.product_id = i.product_id
  WHERE r.units > 0
  ORDER BY days_of_cover ASC NULLS LAST;

-- 7 ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lapsed_customers(
  p_days INT DEFAULT 60 COMMENT 'Días sin comprar para considerar al cliente inactivo'
)
RETURNS TABLE (customer STRING, state STRING,
               last_order DATE, days_since_order INT, lifetime_sales DECIMAL(18,2))
COMMENT 'Clientes que compraron antes pero llevan más de N días sin pedidos. Úsese para "clientes que se me están cayendo" o "cobertura de clientes".'
RETURN
  SELECT c.customer, c.state,
         MAX(s.sale_date) AS last_order,
         DATEDIFF(CURRENT_DATE(), MAX(s.sale_date)) AS days_since_order,
         SUM(s.subtotal) AS lifetime_sales
  FROM fact_sales s
  JOIN dim_customer c ON c.customer_id = s.customer_id
  WHERE s.order_status = 'sale'
  GROUP BY c.customer, c.state
  HAVING DATEDIFF(CURRENT_DATE(), MAX(s.sale_date)) > p_days
  ORDER BY lifetime_sales DESC;

-- ============================================================================
-- CONFIGURACIÓN DEL AGENTE (se hace en la UI, no hay API)
--
-- 1. INSTRUCTIONS — copiar y pegar:
--
--   - Respondé siempre en español.
--   - "Ventas" significa la suma de subtotal con order_status = 'sale'.
--     Las cotizaciones (draft) y los pedidos cancelados NO son ventas.
--   - Al contar pedidos usar siempre COUNT(DISTINCT order_id): la tabla está
--     al grano de línea, un pedido tiene varias filas.
--   - "Zona" es territory: el equipo comercial. Cada zona tiene un gerente
--     (manager) en dim_territory. Si preguntan por gerente, agrupar por la
--     zona que dirige.
--   - "Departamento" es state: la división geográfica de Honduras del cliente,
--     no un área de la empresa ni el estado de un pedido.
--   - Los montos están en lempiras (HNL) salvo que la columna currency indique
--     otra cosa. Nunca sumar montos de monedas distintas sin advertirlo.
--   - El año fiscal coincide con el calendario.
--   - Para preguntas de ventas, preferir la vista sales_metrics, que ya trae
--     las dimensiones unidas.
--
-- 2. SYNONYMS por columna — ESTE PASO NO ES OPCIONAL.
--    Los identificadores están en inglés y el gerente pregunta en español.
--    Genie mapea el vocabulario del usuario a las columnas con los sinónimos,
--    así que sin esto la calidad de las respuestas cae. Cargar al menos:
--
--      territory        -> zona, región, equipo comercial
--      manager          -> gerente, jefe de zona, responsable
--      salesperson      -> vendedor, ejecutivo, asesor
--      customer         -> cliente
--      state            -> departamento, región geográfica
--      city             -> ciudad
--      product          -> producto, artículo
--      category         -> categoría, familia, línea
--      subtotal         -> venta, monto vendido, importe
--      quantity         -> cantidad, unidades
--      order_status     -> estado del pedido
--      sale_date        -> fecha, fecha del pedido
--      available        -> disponible, existencia libre
--      on_hand          -> existencia, inventario
--      order_id         -> pedido
--
-- 3. SAMPLE QUESTIONS — las siete que cubren las funciones:
--   ¿Cómo van las ventas por zona este trimestre?
--   ¿Quiénes son los cinco mejores vendedores del año?
--   ¿Qué productos se venden más en la Zona Norte?
--   ¿Cómo vamos contra el año pasado?
--   ¿En qué departamentos estamos vendiendo menos?
--   ¿Qué productos están en riesgo de quiebre?
--   ¿Qué clientes llevan más de dos meses sin comprarme?
-- ============================================================================
