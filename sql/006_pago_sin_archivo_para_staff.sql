-- ============================================================================
-- Permite que `pagos.archivo_url` quede en null.
--
-- Hasta ahora era NOT NULL porque solo el cliente creaba filas en `pagos`
-- (siempre con su voucher/sustento adjunto). Ahora super_admin/usuario también
-- pueden registrar un pago "de conciliación" (sin archivo) al marcar
-- manualmente un comprobante como sustentado/cobrado — el archivo sigue
-- siendo opcional para ellos, no para el cliente (eso se controla en la UI,
-- no hace falta tocar RLS: `pagos_insert` ya permite a cualquiera de los tres
-- roles asignados insertar, sin restricción por columna).
-- ============================================================================

alter table pagos alter column archivo_url drop not null;
