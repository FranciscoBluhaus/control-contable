-- ============================================================================
-- SIRE (RVIE/RCE) — Etapa A: desglose fino que exige el "archivo de
-- reemplazo" de SUNAT (Anexo 3 y Anexo 11), que hoy no capturamos.
--
-- Columnas compartidas (comprobantes_compra Y comprobantes_venta): la base
-- imponible/gravámenes ya vienen desglosados en el propio comprobante — un
-- comprobante SIEMPRE tiene un solo bi_gravada/exonerado/inafecto/isc/icbper,
-- sin importar si es compra o venta, así que es una sola columna por
-- concepto, reutilizada por ambas tablas (no una tabla "gravámenes" aparte,
-- sería sobre-ingeniería para 5 clientes).
--
-- doc_modificado_*: solo aplica cuando tipo_comprobante es Nota de
-- crédito/débito — referencia al comprobante original que modifican (dato
-- que la propia NC/ND siempre imprime, es legalmente obligatorio).
--
-- clasificacion_credito_igv (compra) vs clasificacion_operacion (venta): dos
-- columnas separadas a propósito, aunque comparten el mismo enum DG/DGNG/DNG
-- — para una compra, describe a qué tipo de operación del cliente se destinó
-- esa compra (decide el % de crédito fiscal de IGV que puede tomar). Para
-- una venta no existe "crédito" (eso es del comprador, no del vendedor) —
-- ahí sirve para que el estudio clasifique sus propias ventas
-- gravadas/exoneradas/inafectas, dato que además alimenta el cálculo de
-- prorrata de las compras DGNG. Es una decisión de negocio, nunca la lee el
-- OCR — default 'DG' (el caso más común) pero editable por comprobante.
-- ============================================================================

alter table comprobantes_compra
  add column if not exists fecha_vencimiento date,
  add column if not exists bi_gravada numeric(12,2),
  add column if not exists monto_exonerado numeric(12,2) not null default 0,
  add column if not exists monto_inafecto numeric(12,2) not null default 0,
  add column if not exists isc numeric(12,2) not null default 0,
  add column if not exists icbper numeric(12,2) not null default 0,
  add column if not exists tipo_cambio numeric(4,3),
  add column if not exists doc_modificado_fecha_emision date,
  add column if not exists doc_modificado_tipo_cp text,
  add column if not exists doc_modificado_serie text,
  add column if not exists doc_modificado_numero text,
  add column if not exists clasificacion_credito_igv text not null default 'DG',
  add column if not exists clasificacion_bienes_servicios text;

alter table comprobantes_compra drop constraint if exists chk_compra_clasificacion_credito_igv;
alter table comprobantes_compra add constraint chk_compra_clasificacion_credito_igv
  check (clasificacion_credito_igv in ('DG','DGNG','DNG'));

alter table comprobantes_venta
  add column if not exists fecha_vencimiento date,
  add column if not exists bi_gravada numeric(12,2),
  add column if not exists monto_exonerado numeric(12,2) not null default 0,
  add column if not exists monto_inafecto numeric(12,2) not null default 0,
  add column if not exists isc numeric(12,2) not null default 0,
  add column if not exists icbper numeric(12,2) not null default 0,
  add column if not exists tipo_cambio numeric(4,3),
  add column if not exists doc_modificado_fecha_emision date,
  add column if not exists doc_modificado_tipo_cp text,
  add column if not exists doc_modificado_serie text,
  add column if not exists doc_modificado_numero text,
  add column if not exists clasificacion_operacion text not null default 'DG',
  add column if not exists valor_exportacion numeric(12,2) not null default 0;

alter table comprobantes_venta drop constraint if exists chk_venta_clasificacion_operacion;
alter table comprobantes_venta add constraint chk_venta_clasificacion_operacion
  check (clasificacion_operacion in ('DG','DGNG','DNG'));
