-- ============================================================================
-- Conciliación bancaria: además de pagos (comprobantes de compra/venta),
-- ahora también puede conciliar abonos de impuestos (cuentas.categoria =
-- 'impuesto' — honorarios quedan fuera a propósito, es información privada
-- del estudio, igual que en "Mis Impuestos").
--
-- Un conciliacion_movimiento podía apuntar solo a un pago (pago_id, FK a
-- pagos). Un abono vive en una tabla distinta (abonos), así que necesita su
-- propia columna — nunca deben llenarse las dos a la vez (un movimiento se
-- concilia con UNA sola cosa, sea pago o abono).
-- ============================================================================

alter table conciliacion_movimientos
  add column if not exists abono_id uuid references abonos(id);

alter table conciliacion_movimientos drop constraint if exists chk_conciliacion_pago_o_abono;
alter table conciliacion_movimientos add constraint chk_conciliacion_pago_o_abono
  check (pago_id is null or abono_id is null);
