-- ============================================================================
-- 02 — GOLD: modelo estrella de ventas e inventario
--
-- Orden:   DESPUÉS de 01_silver.sql, que crea las vistas que esto consume.
-- Corre en: notebook SQL de Databricks, sobre un SQL warehouse.
-- Entrada: odoo_demo.silver.*
-- Salida:  odoo_demo.gold.*  (lo que ven el dashboard y Genie)
--
-- Los COMMENT y los constraints NO son adorno: Genie usa los comentarios de
-- tabla y columna como contexto principal, y las llaves declaradas para saber
-- cómo unir. Una tabla sin comentarios da respuestas mediocres por más limpia
-- que esté la data.
--
-- Nombres en español de negocio, no técnicos: Genie responde mucho mejor a
-- "zona" y "vendedor" que a team_id y user_id.
-- ============================================================================

USE CATALOG odoo_demo;
CREATE SCHEMA IF NOT EXISTS gold;

-- ---------------------------------------------------------------- dimensiones
CREATE OR REPLACE TABLE gold.dim_cliente
COMMENT 'Clientes de la empresa, un renglón por cliente. El departamento es la división geográfica de Honduras donde está ubicado.'
AS SELECT cliente_id, cliente, rtn, ciudad, departamento, pais, es_empresa, activo
FROM silver.clientes;

ALTER TABLE gold.dim_cliente ALTER COLUMN cliente_id SET NOT NULL;
ALTER TABLE gold.dim_cliente ADD CONSTRAINT pk_cliente PRIMARY KEY (cliente_id);
ALTER TABLE gold.dim_cliente ALTER COLUMN departamento
  COMMENT 'Departamento de Honduras: Cortés, Francisco Morazán, Atlántida, etc. Úsese para preguntas sobre región o ubicación geográfica.';
ALTER TABLE gold.dim_cliente ALTER COLUMN rtn
  COMMENT 'Registro Tributario Nacional, el identificador fiscal hondureño del cliente.';

CREATE OR REPLACE TABLE gold.dim_zona
COMMENT 'Zonas de venta (equipos comerciales). Cada zona tiene un gerente responsable y agrupa varios departamentos.'
AS SELECT zona_id, zona, gerente_id, gerente FROM silver.zonas;

ALTER TABLE gold.dim_zona ALTER COLUMN zona_id SET NOT NULL;
ALTER TABLE gold.dim_zona ADD CONSTRAINT pk_zona PRIMARY KEY (zona_id);
ALTER TABLE gold.dim_zona ALTER COLUMN gerente
  COMMENT 'Nombre del gerente responsable de la zona. Úsese para preguntas del tipo "ventas por gerente".';

CREATE OR REPLACE TABLE gold.dim_vendedor
COMMENT 'Vendedores que levantan pedidos en campo.'
AS SELECT vendedor_id, vendedor, correo, activo FROM silver.vendedores;

ALTER TABLE gold.dim_vendedor ALTER COLUMN vendedor_id SET NOT NULL;
ALTER TABLE gold.dim_vendedor ADD CONSTRAINT pk_vendedor PRIMARY KEY (vendedor_id);

CREATE OR REPLACE TABLE gold.dim_producto
COMMENT 'Catálogo de productos con su categoría, unidad de medida y precio de lista.'
AS SELECT producto_id, producto, codigo, codigo_barras, categoria,
          precio_lista, unidad, vendible, activo
FROM silver.productos;

ALTER TABLE gold.dim_producto ALTER COLUMN producto_id SET NOT NULL;
ALTER TABLE gold.dim_producto ADD CONSTRAINT pk_producto PRIMARY KEY (producto_id);

-- ---------------------------------------------------------------------- hechos
-- Grano: línea de pedido. Permite responder por producto Y por pedido sin
-- doble conteo, siempre que los conteos de pedidos usen COUNT(DISTINCT).
CREATE OR REPLACE TABLE gold.fct_ventas
COMMENT 'Ventas al detalle, un renglón por línea de pedido. Para hablar de ventas reales hay que filtrar estado = "sale": draft son cotizaciones y cancel son cancelados. La columna por defecto para sumar ventas es subtotal.'
AS SELECT
  l.linea_id,
  p.pedido_id,
  p.folio,
  p.fecha_pedido,
  CAST(p.fecha_pedido AS DATE) AS fecha,
  YEAR(p.fecha_pedido)         AS anio,
  MONTH(p.fecha_pedido)        AS mes,
  DATE_TRUNC('MONTH', p.fecha_pedido) AS mes_inicio,
  p.estado,
  p.moneda,
  p.cliente_id,
  p.vendedor_id,
  p.zona_id,
  l.producto_id,
  l.cantidad,
  l.cantidad_entregada,
  l.precio_unitario,
  l.descuento_pct,
  l.subtotal,
  l.total_con_impuesto
FROM silver.pedido_lineas l
JOIN silver.pedidos p ON p.pedido_id = l.pedido_id;

ALTER TABLE gold.fct_ventas ALTER COLUMN subtotal
  COMMENT 'Monto de la línea sin impuesto, con el descuento ya aplicado. Esta es la columna por defecto para sumar ventas.';
ALTER TABLE gold.fct_ventas ALTER COLUMN estado
  COMMENT 'Estado del pedido: draft (cotización), sent (enviada al cliente), sale (confirmado), cancel (cancelado).';
ALTER TABLE gold.fct_ventas ALTER COLUMN cantidad_entregada
  COMMENT 'Cantidad ya despachada. Comparada contra cantidad da el pendiente de entrega.';

ALTER TABLE gold.fct_ventas ADD CONSTRAINT fk_ventas_cliente
  FOREIGN KEY (cliente_id)  REFERENCES gold.dim_cliente(cliente_id);
ALTER TABLE gold.fct_ventas ADD CONSTRAINT fk_ventas_vendedor
  FOREIGN KEY (vendedor_id) REFERENCES gold.dim_vendedor(vendedor_id);
ALTER TABLE gold.fct_ventas ADD CONSTRAINT fk_ventas_zona
  FOREIGN KEY (zona_id)     REFERENCES gold.dim_zona(zona_id);
ALTER TABLE gold.fct_ventas ADD CONSTRAINT fk_ventas_producto
  FOREIGN KEY (producto_id) REFERENCES gold.dim_producto(producto_id);

CREATE OR REPLACE TABLE gold.fct_inventario
COMMENT 'Existencias actuales por producto y almacén, solo ubicaciones internas. "disponible" es la cantidad libre, ya descontada la reservada para pedidos pendientes.'
AS SELECT producto_id, almacen, ubicacion, existencia, reservada, disponible
FROM silver.inventario;

ALTER TABLE gold.fct_inventario ADD CONSTRAINT fk_inv_producto
  FOREIGN KEY (producto_id) REFERENCES gold.dim_producto(producto_id);

-- ------------------------------------------------------------ capa semántica
-- Una vista ancha ya unida. Sin esto, cada quien calcula "venta neta" a su
-- manera y los números del chat no cuadran con los del dashboard, que es la
-- forma más rápida de perder la venta.
CREATE OR REPLACE VIEW gold.metricas_ventas
COMMENT 'Vista ancha de ventas con todas las dimensiones ya unidas. Es la fuente preferida para preguntas de negocio sobre ventas.'
AS SELECT
  v.fecha, v.anio, v.mes, v.mes_inicio, v.estado, v.moneda,
  c.cliente, c.departamento, c.ciudad,
  z.zona, z.gerente,
  d.vendedor,
  pr.producto, pr.categoria,
  v.cantidad, v.subtotal, v.total_con_impuesto, v.pedido_id
FROM gold.fct_ventas v
LEFT JOIN gold.dim_cliente  c  ON c.cliente_id  = v.cliente_id
LEFT JOIN gold.dim_zona     z  ON z.zona_id     = v.zona_id
LEFT JOIN gold.dim_vendedor d  ON d.vendedor_id = v.vendedor_id
LEFT JOIN gold.dim_producto pr ON pr.producto_id = v.producto_id;
