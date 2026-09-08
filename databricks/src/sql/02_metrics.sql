-- ============================================================================
-- 02 — Metric View: la capa semántica en español
--
-- Orden:   DESPUÉS de 01_gold.sql. Es la tarea `metrics` del job `medallion`.
-- Entrada: la vista sales_metrics de Gold.
-- Salida:  una metric view que consumen Genie y el dashboard.
--
-- POR QUÉ EXISTE
-- Resuelve la tensión entre dos cosas que se pedían a la vez: identificadores
-- en inglés (portabilidad; es lo que ven JDBC, Power BI y quien herede el
-- repo) y vocabulario de negocio en español (el usuario final es un gerente
-- comercial hondureño, y la documentación de Genie pide metadatos en el idioma
-- del usuario).
--
-- En una metric view el `name` ES la etiqueta de negocio y el `expr` la
-- columna física. Así Gold queda en inglés y lo que ve Genie queda en español,
-- sin duplicar datos y —lo importante— versionado acá, no configurado a mano
-- en la UI del agente, que se pierde si alguien lo recrea.
--
-- OJO AL CONSULTARLA: las medidas se leen con MEASURE(), nunca directo, y no
-- pueden ir en WHERE ni en GROUP BY.
--   SELECT `Zona`, MEASURE(`Venta`) FROM ... GROUP BY `Zona`
--
-- `synonyms` NO está soportado en la versión YAML de este workspace (solo
-- name, expr y window; probado). No hace falta: el `name` ya hace el trabajo.
-- ============================================================================

USE CATALOG IDENTIFIER(:catalog);
USE SCHEMA  IDENTIFIER(:gold_schema);

CREATE OR REPLACE VIEW ventas
WITH METRICS
LANGUAGE YAML
COMMENT 'Métricas de ventas con vocabulario de negocio en español. Es la fuente preferida para Genie y el dashboard: ya trae las definiciones acordadas de venta, pedidos y ticket promedio, así que los números del chat y del dashboard siempre coinciden.'
AS $$
version: 0.1
source: sales_metrics
# "Venta" siempre significa pedido confirmado. Las cotizaciones (draft) y los
# cancelados no son ventas: el filtro vive acá para que nadie lo olvide.
filter: order_status = 'sale'

dimensions:
  - name: Zona
    expr: territory
  - name: Gerente
    expr: manager
  - name: Vendedor
    expr: salesperson
  - name: Cliente
    expr: customer
  - name: Departamento
    expr: state
  - name: Ciudad
    expr: city
  - name: Producto
    expr: product
  - name: Categoria
    expr: category
  - name: Moneda
    expr: currency
  - name: Fecha
    expr: sale_date
  - name: Anio
    expr: sale_year
  - name: Mes
    expr: sale_month
  - name: Mes inicio
    expr: month_start

measures:
  - name: Venta
    expr: SUM(subtotal)
  - name: Venta con impuesto
    expr: SUM(total_with_tax)
  - name: Pedidos
    expr: COUNT(DISTINCT order_id)
  - name: Unidades
    expr: SUM(quantity)
  - name: Clientes
    expr: COUNT(DISTINCT customer)
  # Ticket promedio: se define UNA vez acá. Si cada quien lo calcula a su
  # manera, los números del chat no cuadran con los del dashboard, que es la
  # forma más rápida de perder la venta.
  - name: Ticket promedio
    expr: SUM(subtotal) / NULLIF(COUNT(DISTINCT order_id), 0)
$$;
