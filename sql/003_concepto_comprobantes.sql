-- ============================================================================
-- Agrega el campo "concepto" (descripción del servicio/producto facturado)
-- a comprobantes_compra y comprobantes_venta.
-- ============================================================================

alter table comprobantes_compra add column if not exists concepto text;
alter table comprobantes_venta add column if not exists concepto text;
