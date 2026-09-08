-- ============================================================================
-- 03 — Genie Agent de ventas: trusted assets
--
-- Orden:   DESPUÉS de 02_gold.sql.
-- Corre en: notebook SQL de Databricks, sobre un SQL warehouse.
-- Entrada: odoo_demo.gold.*
-- Salida:  siete funciones SQL que se registran como trusted assets del agente,
--          más el bloque de Instructions al final, para copiar y pegar en la UI.
--
-- Cuando Genie usa una de estas funciones, la respuesta sale con etiqueta
-- "Trusted": una señal de confianza que el usuario no técnico no puede sacar
-- leyendo el SQL generado. Para la demo en vivo, prepará las preguntas que vas
-- a hacer y volvelas trusted. Así la demo deja de ser una ruleta.
--
-- Los parámetros van con prefijo p_ para no chocar con nombres de columna.
-- ============================================================================

USE CATALOG odoo_demo;

-- 1 ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION gold.ventas_por_zona(
  p_desde DATE COMMENT 'Fecha inicial del período',
  p_hasta DATE COMMENT 'Fecha final del período'
)
RETURNS TABLE (zona STRING, gerente STRING, pedidos BIGINT, venta DECIMAL(18,2))
COMMENT 'Ventas confirmadas agrupadas por zona comercial y su gerente, dentro de un rango de fechas. Úsese para "cómo van las ventas por zona" o "qué zona vendió más".'
RETURN
  SELECT z.zona, z.gerente,
         COUNT(DISTINCT v.pedido_id) AS pedidos,
         SUM(v.subtotal)             AS venta
  FROM gold.fct_ventas v
  JOIN gold.dim_zona z ON z.zona_id = v.zona_id
  WHERE v.estado = 'sale' AND v.fecha BETWEEN p_desde AND p_hasta
  GROUP BY z.zona, z.gerente
  ORDER BY venta DESC;

-- 2 ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION gold.ranking_vendedores(
  p_desde DATE COMMENT 'Fecha inicial',
  p_hasta DATE COMMENT 'Fecha final',
  p_limite INT DEFAULT 10 COMMENT 'Cuántos vendedores devolver'
)
RETURNS TABLE (vendedor STRING, zona STRING, pedidos BIGINT,
               venta DECIMAL(18,2), ticket_promedio DECIMAL(18,2))
COMMENT 'Ranking de vendedores por monto vendido en un período, con su zona y ticket promedio. Úsese para "mejores vendedores" o "quién vendió más".'
RETURN
  SELECT d.vendedor, z.zona,
         COUNT(DISTINCT v.pedido_id) AS pedidos,
         SUM(v.subtotal)             AS venta,
         CAST(SUM(v.subtotal) / NULLIF(COUNT(DISTINCT v.pedido_id), 0) AS DECIMAL(18,2))
      AS ticket_promedio
  FROM gold.fct_ventas v
  JOIN gold.dim_vendedor d ON d.vendedor_id = v.vendedor_id
  LEFT JOIN gold.dim_zona z ON z.zona_id = v.zona_id
  WHERE v.estado = 'sale' AND v.fecha BETWEEN p_desde AND p_hasta
  GROUP BY d.vendedor, z.zona
  ORDER BY venta DESC
  LIMIT p_limite;

-- 3 ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION gold.top_productos(
  p_desde DATE, p_hasta DATE, p_limite INT DEFAULT 15
)
RETURNS TABLE (producto STRING, categoria STRING,
               unidades DECIMAL(18,3), venta DECIMAL(18,2))
COMMENT 'Productos más vendidos por monto en un período, con unidades y categoría. Úsese para "qué se vende más" o "top productos".'
RETURN
  SELECT pr.producto, pr.categoria,
         SUM(v.cantidad) AS unidades,
         SUM(v.subtotal) AS venta
  FROM gold.fct_ventas v
  JOIN gold.dim_producto pr ON pr.producto_id = v.producto_id
  WHERE v.estado = 'sale' AND v.fecha BETWEEN p_desde AND p_hasta
  GROUP BY pr.producto, pr.categoria
  ORDER BY venta DESC
  LIMIT p_limite;

-- 4 ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION gold.comparativo_anual(
  p_anio INT COMMENT 'Año a comparar contra el anterior'
)
RETURNS TABLE (mes INT, venta_actual DECIMAL(18,2),
               venta_anterior DECIMAL(18,2), variacion_pct DECIMAL(9,2))
COMMENT 'Ventas mensuales del año indicado contra el año anterior, con variación porcentual. Úsese para "cómo vamos contra el año pasado".'
RETURN
  WITH base AS (
    SELECT anio, mes, SUM(subtotal) AS venta
    FROM gold.fct_ventas
    WHERE estado = 'sale' AND anio IN (p_anio, p_anio - 1)
    GROUP BY anio, mes
  )
  SELECT COALESCE(a.mes, b.mes) AS mes,
         a.venta AS venta_actual,
         b.venta AS venta_anterior,
         CAST(100.0 * (a.venta - b.venta) / NULLIF(b.venta, 0) AS DECIMAL(9,2))
      AS variacion_pct
  FROM (SELECT * FROM base WHERE anio = p_anio) a
  FULL OUTER JOIN (SELECT * FROM base WHERE anio = p_anio - 1) b
    ON a.mes = b.mes
  ORDER BY mes;

-- 5 ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION gold.ventas_por_departamento(
  p_desde DATE, p_hasta DATE
)
RETURNS TABLE (departamento STRING, clientes BIGINT, venta DECIMAL(18,2))
COMMENT 'Ventas confirmadas por departamento de Honduras, con cuántos clientes distintos compraron. Úsese para preguntas geográficas o de cobertura regional.'
RETURN
  SELECT c.departamento,
         COUNT(DISTINCT v.cliente_id) AS clientes,
         SUM(v.subtotal)              AS venta
  FROM gold.fct_ventas v
  JOIN gold.dim_cliente c ON c.cliente_id = v.cliente_id
  WHERE v.estado = 'sale' AND v.fecha BETWEEN p_desde AND p_hasta
  GROUP BY c.departamento
  ORDER BY venta DESC;

-- 6 ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION gold.riesgo_quiebre(
  p_dias INT DEFAULT 30 COMMENT 'Ventana de venta reciente a considerar'
)
RETURNS TABLE (producto STRING, almacen STRING, disponible DECIMAL(18,3),
               vendido_periodo DECIMAL(18,3), dias_cobertura DECIMAL(9,1))
COMMENT 'Productos con inventario bajo frente a su venta reciente, con días de cobertura estimados. Úsese para "qué se me va a acabar" o "riesgo de quiebre de stock".'
RETURN
  WITH venta AS (
    SELECT producto_id, SUM(cantidad) AS unidades
    FROM gold.fct_ventas
    WHERE estado = 'sale' AND fecha >= CURRENT_DATE() - p_dias
    GROUP BY producto_id
  )
  SELECT pr.producto, i.almacen, i.disponible,
         COALESCE(vt.unidades, 0) AS vendido_periodo,
         CAST(i.disponible / NULLIF(vt.unidades / p_dias, 0) AS DECIMAL(9,1))
      AS dias_cobertura
  FROM gold.fct_inventario i
  JOIN gold.dim_producto pr ON pr.producto_id = i.producto_id
  LEFT JOIN venta vt ON vt.producto_id = i.producto_id
  WHERE vt.unidades > 0
  ORDER BY dias_cobertura ASC NULLS LAST;

-- 7 ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION gold.clientes_sin_compra(
  p_dias INT DEFAULT 60 COMMENT 'Días sin comprar para considerar al cliente inactivo'
)
RETURNS TABLE (cliente STRING, departamento STRING,
               ultima_compra DATE, dias_sin_comprar INT, venta_historica DECIMAL(18,2))
COMMENT 'Clientes que compraron antes pero llevan más de N días sin pedidos. Úsese para "clientes que se me están cayendo" o "cobertura de clientes".'
RETURN
  SELECT c.cliente, c.departamento,
         MAX(v.fecha) AS ultima_compra,
         DATEDIFF(CURRENT_DATE(), MAX(v.fecha)) AS dias_sin_comprar,
         SUM(v.subtotal) AS venta_historica
  FROM gold.fct_ventas v
  JOIN gold.dim_cliente c ON c.cliente_id = v.cliente_id
  WHERE v.estado = 'sale'
  GROUP BY c.cliente, c.departamento
  HAVING DATEDIFF(CURRENT_DATE(), MAX(v.fecha)) > p_dias
  ORDER BY venta_historica DESC;

-- ============================================================================
-- INSTRUCCIONES PARA EL AGENTE (copiar y pegar en la pestaña Instructions)
--
-- Van cortas y específicas. Las instrucciones generales se usan con moderación
-- y nunca para tapar metadata faltante: si algo se puede resolver con un
-- COMMENT en la columna, va en el COMMENT, no acá.
--
--   - "Ventas" significa la suma de subtotal con estado = 'sale'.
--     Las cotizaciones (draft) y los pedidos cancelados NO son ventas.
--   - Al contar pedidos usar siempre COUNT(DISTINCT pedido_id): la tabla
--     está al grano de línea, un pedido tiene varias filas.
--   - "Zona" es el equipo comercial. Cada zona tiene un gerente en dim_zona.
--     Si preguntan por gerente, agrupar por la zona que dirige.
--   - "Departamento" es la división geográfica de Honduras del cliente,
--     no un área de la empresa.
--   - Los montos están en lempiras (HNL) salvo que la columna moneda indique
--     otra cosa. Nunca sumar montos de monedas distintas sin advertirlo.
--   - El año fiscal coincide con el calendario.
--   - Para preguntas de ventas, preferir la vista gold.metricas_ventas,
--     que ya trae las dimensiones unidas.
--
-- Y en Sample questions, cargá las mismas siete que cubren las funciones:
--   ¿Cómo van las ventas por zona este trimestre?
--   ¿Quiénes son los cinco mejores vendedores del año?
--   ¿Qué productos se venden más en la Zona Norte?
--   ¿Cómo vamos contra el año pasado?
--   ¿En qué departamentos estamos vendiendo menos?
--   ¿Qué productos están en riesgo de quiebre?
--   ¿Qué clientes llevan más de dos meses sin comprarme?
-- ============================================================================
