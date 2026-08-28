-- ============================================================================
-- Restringe la edición de comprobantes, con una excepción para el propio
-- dueño mientras el comprobante sigue "abierto".
--
-- Hasta ahora UPDATE/DELETE en comprobantes_compra y comprobantes_venta, y el
-- INSERT de comprobantes_venta, usaban el mismo predicado amplio que el resto
-- del módulo (is_super_admin() OR asignado vía asignaciones_clientes), sin
-- distinguir 'usuario' de 'cliente'. Eso significa que aunque la UI no le
-- muestre un botón de editar, un usuario con rol 'cliente' SÍ podía hacerlo
-- vía API/consola — ocultar el botón no alcanza, hay que cerrarlo en RLS.
--
-- Reglas finales (acordadas):
--
-- 1) comprobantes_compra — el cliente dueño puede UPDATE/DELETE su propio
--    comprobante SOLO mientras estado = 'pendiente_sustento'. En cuanto pasa a
--    'sustentado' (ya tiene un pago vinculado) queda congelado para él: de ahí
--    en adelante solo super_admin/usuario lo corrigen (botón "Editar" ya
--    existente). El `with check` exige que, tras la edición, el estado siga
--    siendo 'pendiente_sustento' — así el cliente tampoco puede "auto-
--    sustentarse" cambiando el campo a mano.
--
-- 2) comprobantes_venta — sigue exclusivamente del staff (el cliente nunca la
--    crea ni la edita: la emite el estudio). Sin cambios respecto al ajuste
--    anterior.
--
-- 3) pagos — el cliente NO puede editar un pago ya subido (evita que reasigne
--    el archivo/monto de un voucher sin dejar rastro de qué cambió). Lo que sí
--    puede es ELIMINAR el voucher de cobro (pago ligado a una venta, y que
--    además subió él mismo — subido_por = auth.uid()) en cualquier momento —
--    el trigger `pagos_actualiza_estado`
--    ya revierte automáticamente la venta a 'pendiente_cobro' al borrarlo, y
--    desde la UI puede volver a subir uno nuevo. Se eligió esta opción (la
--    "más simple" que planteaste) en vez de rastrear si el staff ya hizo un
--    ajuste posterior sobre esa venta, porque esa segunda condición requeriría
--    una columna nueva (ej. "confirmado_en"/"ajustado_por_staff") y lógica
--    adicional para mantenerla consistente — más superficie para un bug de
--    seguridad, para un beneficio marginal (evitar que el cliente "deshaga" un
--    cobro ya visto por el staff, algo que igual pueden corregir manualmente
--    si pasa). Importante: esto NO aplica al pago que sustenta una compra —
--    ese sigue las reglas del punto 1 (una vez que existe el pago, la compra
--    ya está "sustentada" y congelada; si el cliente pudiera borrar ESE pago,
--    burlaría el congelamiento reabriendo la compra). Por eso el permiso de
--    borrar pago del cliente se limita explícitamente a pagos con
--    comprobante_venta_id (nunca comprobante_compra_id).
-- ============================================================================

-- comprobantes_compra: UPDATE — super_admin, usuario asignado siempre, o el
-- cliente dueño solo mientras pendiente_sustento (y sin poder cambiar el estado).
drop policy comprobantes_compra_update on comprobantes_compra;
create policy comprobantes_compra_update on comprobantes_compra
for update using (
  is_super_admin()
  or exists (
    select 1 from asignaciones_clientes a
    join perfiles p on p.user_id = a.usuario_id
    where a.cliente_id = comprobantes_compra.cliente_id
      and a.usuario_id = auth.uid()
      and p.rol = 'usuario'
  )
  or (
    comprobantes_compra.estado = 'pendiente_sustento'
    and exists (
      select 1 from asignaciones_clientes a
      join perfiles p on p.user_id = a.usuario_id
      where a.cliente_id = comprobantes_compra.cliente_id
        and a.usuario_id = auth.uid()
        and p.rol = 'cliente'
    )
  )
) with check (
  is_super_admin()
  or exists (
    select 1 from asignaciones_clientes a
    join perfiles p on p.user_id = a.usuario_id
    where a.cliente_id = comprobantes_compra.cliente_id
      and a.usuario_id = auth.uid()
      and p.rol = 'usuario'
  )
  or (
    comprobantes_compra.estado = 'pendiente_sustento'
    and exists (
      select 1 from asignaciones_clientes a
      join perfiles p on p.user_id = a.usuario_id
      where a.cliente_id = comprobantes_compra.cliente_id
        and a.usuario_id = auth.uid()
        and p.rol = 'cliente'
    )
  )
);

-- comprobantes_compra: DELETE — mismo criterio que el UPDATE.
drop policy comprobantes_compra_delete on comprobantes_compra;
create policy comprobantes_compra_delete on comprobantes_compra
for delete using (
  is_super_admin()
  or exists (
    select 1 from asignaciones_clientes a
    join perfiles p on p.user_id = a.usuario_id
    where a.cliente_id = comprobantes_compra.cliente_id
      and a.usuario_id = auth.uid()
      and p.rol = 'usuario'
  )
  or (
    comprobantes_compra.estado = 'pendiente_sustento'
    and exists (
      select 1 from asignaciones_clientes a
      join perfiles p on p.user_id = a.usuario_id
      where a.cliente_id = comprobantes_compra.cliente_id
        and a.usuario_id = auth.uid()
        and p.rol = 'cliente'
    )
  )
);

-- comprobantes_venta: INSERT/UPDATE/DELETE solo para super_admin o usuario asignado.
drop policy comprobantes_venta_insert on comprobantes_venta;
create policy comprobantes_venta_insert on comprobantes_venta
for insert with check (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    join perfiles p on p.user_id = a.usuario_id
    where a.cliente_id = comprobantes_venta.cliente_id
      and a.usuario_id = auth.uid()
      and p.rol = 'usuario'
  )
);

drop policy comprobantes_venta_update on comprobantes_venta;
create policy comprobantes_venta_update on comprobantes_venta
for update using (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    join perfiles p on p.user_id = a.usuario_id
    where a.cliente_id = comprobantes_venta.cliente_id
      and a.usuario_id = auth.uid()
      and p.rol = 'usuario'
  )
) with check (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    join perfiles p on p.user_id = a.usuario_id
    where a.cliente_id = comprobantes_venta.cliente_id
      and a.usuario_id = auth.uid()
      and p.rol = 'usuario'
  )
);

drop policy comprobantes_venta_delete on comprobantes_venta;
create policy comprobantes_venta_delete on comprobantes_venta
for delete using (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    join perfiles p on p.user_id = a.usuario_id
    where a.cliente_id = comprobantes_venta.cliente_id
      and a.usuario_id = auth.uid()
      and p.rol = 'usuario'
  )
);

-- pagos: DELETE — super_admin y usuario asignado conservan acceso total (compra
-- y venta, como ya tenían). Se agrega una rama nueva para 'cliente', limitada
-- SOLO a pagos de venta (comprobante_venta_id) — nunca de compra, por la razón
-- explicada arriba (borrar el sustento de una compra ya sustentada burlaría su
-- congelamiento). No se toca pagos_select/insert/update: el cliente sigue
-- pudiendo subir su voucher; no gana permiso de editarlo in-place.
drop policy pagos_delete on pagos;
create policy pagos_delete on pagos
for delete using (
  is_super_admin()
  or exists (
    select 1 from comprobantes_compra cc
    join asignaciones_clientes a on a.cliente_id = cc.cliente_id
    join perfiles p on p.user_id = a.usuario_id
    where cc.id = pagos.comprobante_compra_id
      and a.usuario_id = auth.uid()
      and p.rol = 'usuario'
  )
  or exists (
    select 1 from comprobantes_venta cv
    join asignaciones_clientes a on a.cliente_id = cv.cliente_id
    join perfiles p on p.user_id = a.usuario_id
    where cv.id = pagos.comprobante_venta_id
      and a.usuario_id = auth.uid()
      and p.rol = 'usuario'
  )
  or (
    pagos.subido_por = auth.uid() -- solo el voucher que él mismo subió, no cualquiera de "su" venta
    and exists (
      select 1 from comprobantes_venta cv
      join asignaciones_clientes a on a.cliente_id = cv.cliente_id
      join perfiles p on p.user_id = a.usuario_id
      where cv.id = pagos.comprobante_venta_id
        and a.usuario_id = auth.uid()
        and p.rol = 'cliente'
    )
  )
);
