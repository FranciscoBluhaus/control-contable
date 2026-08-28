-- ============================================================================
-- Conciliación bancaria: el rol 'cliente' pasa a ser SOLO LECTURA.
--
-- Hasta ahora INSERT/UPDATE/DELETE en conciliacion_movimientos usaban el
-- mismo predicado amplio que SELECT (is_super_admin() OR asignado vía
-- asignaciones_clientes), sin distinguir 'usuario' de 'cliente' — igual que
-- pasaba con comprobantes_compra/venta antes de 004. Aunque la UI nunca le
-- mostró al cliente ningún botón de subir/vincular/ignorar/crear/revertir,
-- eso no alcanza como control de acceso: hay que cerrarlo en RLS. Mismo
-- patrón exacto que ya usa 004 para comprobantes.
--
-- SELECT no se toca: el cliente conserva su propia lectura (es lo que
-- alimenta la sección de solo lectura en "Mis Comprobantes").
-- ============================================================================

drop policy conciliacion_insert on conciliacion_movimientos;
create policy conciliacion_insert on conciliacion_movimientos
for insert with check (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    join perfiles p on p.user_id = a.usuario_id
    where a.cliente_id = conciliacion_movimientos.cliente_id
      and a.usuario_id = auth.uid()
      and p.rol = 'usuario'
  )
);

drop policy conciliacion_update on conciliacion_movimientos;
create policy conciliacion_update on conciliacion_movimientos
for update using (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    join perfiles p on p.user_id = a.usuario_id
    where a.cliente_id = conciliacion_movimientos.cliente_id
      and a.usuario_id = auth.uid()
      and p.rol = 'usuario'
  )
) with check (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    join perfiles p on p.user_id = a.usuario_id
    where a.cliente_id = conciliacion_movimientos.cliente_id
      and a.usuario_id = auth.uid()
      and p.rol = 'usuario'
  )
);

drop policy conciliacion_delete on conciliacion_movimientos;
create policy conciliacion_delete on conciliacion_movimientos
for delete using (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    join perfiles p on p.user_id = a.usuario_id
    where a.cliente_id = conciliacion_movimientos.cliente_id
      and a.usuario_id = auth.uid()
      and p.rol = 'usuario'
  )
);
