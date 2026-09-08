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
version: 1.1
source: sales_metrics
# "Venta" siempre significa pedido confirmado. Las cotizaciones (draft) y los
# cancelados no son ventas: el filtro vive acá para que nadie lo olvide.
filter: order_status = 'sale'

dimensions:
  - name: Zona
    expr: territory
    synonyms: [zona comercial, territorio, region, equipo comercial, equipo de ventas]
    comment: Zona comercial del pedido. Cada una tiene un gerente responsable.
  - name: Gerente
    expr: manager
    synonyms: [jefe de zona, responsable de zona, jefe comercial]
    comment: Gerente responsable de la zona comercial.
  - name: Vendedor
    expr: salesperson
    synonyms: [ejecutivo, asesor, ejecutivo de ventas, representante]
    comment: Vendedor que levantó el pedido en campo.
  - name: Cliente
    expr: customer
    synonyms: [comprador, cuenta]
  - name: Departamento
    expr: state
    synonyms: [departamento de Honduras, region geografica, provincia]
    comment: >-
      División geográfica de Honduras donde está el cliente (Cortés, Francisco
      Morazán, Atlántida...). NO es un área de la empresa ni el estado del pedido.
  - name: Ciudad
    expr: city
    synonyms: [municipio, localidad]
  - name: Producto
    expr: product
    synonyms: [articulo, item, sku]
  - name: Categoria
    expr: category
    synonyms: [familia, linea de producto, rubro]
  - name: Moneda
    expr: currency
    synonyms: [divisa]
  - name: Fecha
    expr: sale_date
    synonyms: [fecha del pedido, dia]
  - name: Anio
    expr: sale_year
    synonyms: [año, ejercicio]
  - name: Mes
    expr: sale_month
  - name: Mes inicio
    expr: month_start
    synonyms: [mes, periodo mensual]

measures:
  - name: Venta
    expr: SUM(subtotal)
    synonyms: [ventas, monto vendido, importe, facturacion, ingresos]
    comment: Suma del subtotal de las líneas de pedidos confirmados, sin impuesto.
    format:
      type: currency
      currency_code: HNL
  - name: Venta con impuesto
    expr: SUM(total_with_tax)
    synonyms: [venta bruta, total con impuesto]
    format:
      type: currency
      currency_code: HNL
  - name: Pedidos
    expr: COUNT(DISTINCT order_id)
    synonyms: [ordenes, cantidad de pedidos, numero de pedidos]
    comment: Pedidos distintos. La tabla está al grano de línea, por eso el DISTINCT.
  - name: Unidades
    expr: SUM(quantity)
    synonyms: [cantidad, volumen, piezas]
  - name: Clientes
    expr: COUNT(DISTINCT customer)
    synonyms: [cantidad de clientes, compradores distintos]
  # Ticket promedio: se define UNA vez acá. Si cada quien lo calcula a su
  # manera, los números del chat no cuadran con los del dashboard, que es la
  # forma más rápida de perder la venta.
  - name: Ticket promedio
    expr: SUM(subtotal) / NULLIF(COUNT(DISTINCT order_id), 0)
    synonyms: [ticket medio, venta promedio por pedido, valor promedio]
    format:
      type: currency
      currency_code: HNL
$$;
