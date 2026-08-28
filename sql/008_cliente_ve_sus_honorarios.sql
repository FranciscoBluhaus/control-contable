-- ============================================================================
-- REVERTIDO. La versión original de este archivo dejaba que el rol 'cliente'
-- viera sus propios honorarios (categoria='honorario') en cuentas_select,
-- para la sección "Honorarios" de "Mis Impuestos". Se decidió que NO: los
-- honorarios son información del estudio (lo que el cliente le debe al
-- contador por sus servicios), no algo que el cliente deba ver en su propio
-- panel — su "lo que debe" ya se refleja en sus propias compras/ventas.
--
-- Este archivo ahora deja cuentas_select exactamente como estaba antes de
-- esta migración (equivalente a la política original de 001): solo
-- super_admin ve categoria='honorario'. Es seguro volver a correrlo aunque
-- ya hayas aplicado la versión anterior — DROP + CREATE es idempotente.
-- ============================================================================

drop policy cuentas_select on cuentas;
create policy cuentas_select on cuentas
for select using (
  is_super_admin() or (
    (categoria = 'impuesto')
    and exists (
      select 1 from asignaciones_clientes a
      where a.cliente_id = cuentas.cliente_id and a.usuario_id = auth.uid()
    )
  )
);
