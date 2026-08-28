-- ============================================================================
-- Corrige una regresión de sql/004_restringir_edicion_cliente.sql.
--
-- Esa migración endureció UPDATE/DELETE de comprobantes_venta a solo
-- super_admin/usuario — correcto y acordado explícitamente ("el cliente NO
-- debe poder editar/eliminar la venta en sí, la registra el staff"). Pero de
-- paso también restringió el INSERT al mismo predicado, cerrando algo que sí
-- se había acordado antes (cuando se diseñó el módulo de Ventas): que el
-- propio cliente pudiera CREAR su comprobante de venta, no solo el staff.
--
-- Esta migración solo toca INSERT. Deja UPDATE/DELETE tal como quedaron en
-- 004 (staff-only) — eso sigue siendo correcto.
--
-- Regla final: comprobantes_venta se puede CREAR por super_admin, por
-- 'usuario' con ese cliente asignado, o por el propio 'cliente' — siempre
-- acotado a su propio cliente_id vía asignaciones_clientes. Mismo predicado
-- (sin distinguir rol) que ya usa comprobantes_compra_insert desde 001.
-- ============================================================================

drop policy comprobantes_venta_insert on comprobantes_venta;
create policy comprobantes_venta_insert on comprobantes_venta
for insert with check (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    where a.cliente_id = comprobantes_venta.cliente_id and a.usuario_id = auth.uid()
  )
);
