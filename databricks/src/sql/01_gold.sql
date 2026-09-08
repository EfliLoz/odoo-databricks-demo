-- ============================================================================
-- 01 — GOLD: modelo estrella de ventas e inventario.
--
-- Va como tarea SQL y NO dentro del pipeline declarativo a propósito: Gold
-- necesita constraints PK/FK, y las materialized views no los admiten. Es una
-- desviación consciente de la recomendación genérica de Databricks, porque
-- Genie usa esos constraints para inferir joins.
--
-- IDIOMA: identificadores en inglés, COMMENT en español. La documentación de
-- Genie pide metadatos en el idioma del usuario, y el usuario final es un
-- gerente comercial hondureño. Los COMMENT son el contexto principal del
-- agente; los nombres físicos se mapean a vocabulario de negocio con los
-- sinónimos por columna del Genie Agent. Nunca acortar ni quitar un COMMENT.
-- ============================================================================

USE CATALOG IDENTIFIER(:catalog);
USE SCHEMA  IDENTIFIER(:gold_schema);

-- ---------------------------------------------------------------- dimensiones
CREATE OR REPLACE TABLE dim_customer
COMMENT 'Clientes de la empresa, un renglón por cliente. El departamento es la división geográfica de Honduras donde está ubicado.'
AS SELECT customer_id, customer, tax_id, city, state, country, is_company, is_active
FROM IDENTIFIER(:catalog || '.' || :silver_schema || '.silver_customers');

ALTER TABLE dim_customer ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE dim_customer ADD CONSTRAINT pk_customer PRIMARY KEY (customer_id);
ALTER TABLE dim_customer ALTER COLUMN state
  COMMENT 'Departamento de Honduras: Cortés, Francisco Morazán, Atlántida, etc. Es la división geográfica del cliente, NO el estado de un pedido. Úsese para preguntas sobre región, departamento o ubicación geográfica.';
ALTER TABLE dim_customer ALTER COLUMN tax_id
  COMMENT 'RTN: Registro Tributario Nacional, el identificador fiscal hondureño del cliente.';
ALTER TABLE dim_customer ALTER COLUMN customer
  COMMENT 'Nombre del cliente.';

CREATE OR REPLACE TABLE dim_territory
COMMENT 'Zonas de venta (equipos comerciales). Cada zona tiene un gerente responsable y agrupa varios departamentos.'
AS SELECT territory_id, territory, manager_id, manager
FROM IDENTIFIER(:catalog || '.' || :silver_schema || '.silver_territories');

ALTER TABLE dim_territory ALTER COLUMN territory_id SET NOT NULL;
ALTER TABLE dim_territory ADD CONSTRAINT pk_territory PRIMARY KEY (territory_id);
ALTER TABLE dim_territory ALTER COLUMN territory
  COMMENT 'Zona comercial: Zona Norte, Zona Centro, Zona Sur, Zona Occidente.';
ALTER TABLE dim_territory ALTER COLUMN manager
  COMMENT 'Nombre del gerente responsable de la zona. Úsese para preguntas del tipo "ventas por gerente".';

CREATE OR REPLACE TABLE dim_salesperson
COMMENT 'Vendedores que levantan pedidos en campo.'
AS SELECT salesperson_id, salesperson, email, is_active
FROM IDENTIFIER(:catalog || '.' || :silver_schema || '.silver_salespeople');

ALTER TABLE dim_salesperson ALTER COLUMN salesperson_id SET NOT NULL;
ALTER TABLE dim_salesperson ADD CONSTRAINT pk_salesperson PRIMARY KEY (salesperson_id);
ALTER TABLE dim_salesperson ALTER COLUMN salesperson
  COMMENT 'Nombre del vendedor.';

CREATE OR REPLACE TABLE dim_product
COMMENT 'Catálogo de productos con su categoría, unidad de medida y precio de lista.'
AS SELECT product_id, product, product_code, barcode, category,
          list_price, uom, is_sellable, is_active
FROM IDENTIFIER(:catalog || '.' || :silver_schema || '.silver_products');

ALTER TABLE dim_product ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE dim_product ADD CONSTRAINT pk_product PRIMARY KEY (product_id);
ALTER TABLE dim_product ALTER COLUMN product
  COMMENT 'Nombre del producto.';
ALTER TABLE dim_product ALTER COLUMN category
  COMMENT 'Categoría del producto.';

-- ---------------------------------------------------------------------- hechos
-- Grano: línea de pedido. Permite responder por producto Y por pedido sin
-- doble conteo, siempre que los conteos de pedidos usen COUNT(DISTINCT).
CREATE OR REPLACE TABLE fact_sales
COMMENT 'Ventas al detalle, un renglón por línea de pedido. Para hablar de ventas reales hay que filtrar order_status = "sale": draft son cotizaciones y cancel son cancelados. La columna por defecto para sumar ventas es subtotal.'
AS SELECT
  l.line_id,
  o.order_id,
  o.order_ref,
  o.ordered_at,
  CAST(o.ordered_at AS DATE)        AS sale_date,
  YEAR(o.ordered_at)                AS sale_year,
  MONTH(o.ordered_at)               AS sale_month,
  DATE_TRUNC('MONTH', o.ordered_at) AS month_start,
  o.order_status,
  o.currency,
  o.customer_id,
  o.salesperson_id,
  o.territory_id,
  l.product_id,
  l.quantity,
  l.quantity_delivered,
  l.unit_price,
  l.discount_pct,
  l.subtotal,
  l.total_with_tax
FROM IDENTIFIER(:catalog || '.' || :silver_schema || '.silver_order_lines') l
JOIN IDENTIFIER(:catalog || '.' || :silver_schema || '.silver_orders') o
  ON o.order_id = l.order_id;

ALTER TABLE fact_sales ALTER COLUMN subtotal
  COMMENT 'Monto de la línea sin impuesto, con el descuento ya aplicado. Esta es la columna por defecto para sumar ventas.';
ALTER TABLE fact_sales ALTER COLUMN order_status
  COMMENT 'Estado del pedido: draft (cotización), sent (enviada al cliente), sale (confirmado), cancel (cancelado). Solo "sale" cuenta como venta.';
ALTER TABLE fact_sales ALTER COLUMN quantity_delivered
  COMMENT 'Cantidad ya despachada. Comparada contra quantity da el pendiente de entrega.';
ALTER TABLE fact_sales ALTER COLUMN currency
  COMMENT 'Moneda del pedido. Los montos están en lempiras (HNL) salvo que esta columna indique otra cosa. Nunca sumar montos de monedas distintas sin advertirlo.';
ALTER TABLE fact_sales ALTER COLUMN sale_date
  COMMENT 'Fecha del pedido.';

ALTER TABLE fact_sales ADD CONSTRAINT fk_sales_customer
  FOREIGN KEY (customer_id)    REFERENCES dim_customer(customer_id);
ALTER TABLE fact_sales ADD CONSTRAINT fk_sales_salesperson
  FOREIGN KEY (salesperson_id) REFERENCES dim_salesperson(salesperson_id);
ALTER TABLE fact_sales ADD CONSTRAINT fk_sales_territory
  FOREIGN KEY (territory_id)   REFERENCES dim_territory(territory_id);
ALTER TABLE fact_sales ADD CONSTRAINT fk_sales_product
  FOREIGN KEY (product_id)     REFERENCES dim_product(product_id);

CREATE OR REPLACE TABLE fact_inventory
COMMENT 'Existencias actuales por producto y almacén, solo ubicaciones internas. "available" es la cantidad libre, ya descontada la reservada para pedidos pendientes.'
AS SELECT product_id, warehouse, location, on_hand, reserved, available
FROM IDENTIFIER(:catalog || '.' || :silver_schema || '.silver_inventory');

ALTER TABLE fact_inventory ALTER COLUMN available
  COMMENT 'Cantidad disponible: existencia menos la reservada para pedidos pendientes.';
ALTER TABLE fact_inventory ADD CONSTRAINT fk_inventory_product
  FOREIGN KEY (product_id) REFERENCES dim_product(product_id);

-- ------------------------------------------------------------ capa semántica
-- Una vista ancha ya unida. Sin esto, cada quien calcula "venta neta" a su
-- manera y los números del chat no cuadran con los del dashboard, que es la
-- forma más rápida de perder la venta.
CREATE OR REPLACE VIEW sales_metrics
COMMENT 'Vista ancha de ventas con todas las dimensiones ya unidas. Es la fuente preferida para preguntas de negocio sobre ventas.'
AS SELECT
  s.sale_date, s.sale_year, s.sale_month, s.month_start, s.order_status, s.currency,
  c.customer, c.state, c.city,
  t.territory, t.manager,
  sp.salesperson,
  p.product, p.category,
  s.quantity, s.subtotal, s.total_with_tax, s.order_id
FROM fact_sales s
LEFT JOIN dim_customer    c  ON c.customer_id    = s.customer_id
LEFT JOIN dim_territory   t  ON t.territory_id   = s.territory_id
LEFT JOIN dim_salesperson sp ON sp.salesperson_id = s.salesperson_id
LEFT JOIN dim_product     p  ON p.product_id     = s.product_id;
