-- ============================================================================
-- Conciliación bancaria con IA — Etapa A (núcleo de solo lectura).
--
-- Cada vez que se sube un estado de cuenta (PDF), el Worker de OCR extrae sus
-- movimientos y el frontend los guarda tal cual en esta tabla, uno por fila,
-- todos etiquetados con el mismo `archivo_estado_cuenta` (funciona como
-- identificador de "lote" — no hace falta una tabla aparte para agrupar
-- lotes). `periodo_inicio`/`periodo_fin` quedan repetidos en cada fila del
-- mismo lote a propósito: es la forma más simple de saber, sin un JOIN
-- extra, qué rango de fechas cubre ese estado de cuenta (necesario para el
-- grupo "en el sistema pero no en el banco", que solo debe mirar pagos
-- dentro del período efectivamente revisado).
--
-- `pago_id` y `estado` ya existen desde ahora aunque en la Etapa A el
-- match se calcula al vuelo en el frontend (no se escribe todavía) —
-- se necesitan tal cual para la Etapa B (conciliar/ignorar manualmente),
-- así se evita una segunda migración solo para agregar dos columnas.
-- ============================================================================

create table if not exists conciliacion_movimientos (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid references clientes(id) not null,
  archivo_estado_cuenta text not null,
  periodo_inicio date,
  periodo_fin date,
  fecha date,
  monto numeric(12,2),
  moneda text not null default 'PEN' check (moneda in ('PEN','USD')),
  tipo text not null check (tipo in ('abono','cargo')),
  descripcion text,
  pago_id uuid references pagos(id),
  estado text not null default 'pendiente' check (estado in ('pendiente','conciliado','ignorado')),
  subido_por uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);

create index if not exists idx_conciliacion_cliente on conciliacion_movimientos(cliente_id);
create index if not exists idx_conciliacion_archivo on conciliacion_movimientos(archivo_estado_cuenta);

alter table conciliacion_movimientos enable row level security;

-- Mismo predicado amplio que ya usan comprobantes_compra/venta y pagos:
-- super_admin ve todo, 'usuario' solo clientes que tiene asignados. El rol
-- 'cliente' NO tiene acceso — la conciliación bancaria es una herramienta
-- interna del estudio (Etapa C, todavía no implementada, decidirá si algo
-- de esto se expone al cliente).
drop policy if exists conciliacion_select on conciliacion_movimientos;
create policy conciliacion_select on conciliacion_movimientos
for select using (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    where a.cliente_id = conciliacion_movimientos.cliente_id and a.usuario_id = auth.uid()
  )
);

drop policy if exists conciliacion_insert on conciliacion_movimientos;
create policy conciliacion_insert on conciliacion_movimientos
for insert with check (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    where a.cliente_id = conciliacion_movimientos.cliente_id and a.usuario_id = auth.uid()
  )
);

drop policy if exists conciliacion_update on conciliacion_movimientos;
create policy conciliacion_update on conciliacion_movimientos
for update using (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    where a.cliente_id = conciliacion_movimientos.cliente_id and a.usuario_id = auth.uid()
  )
) with check (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    where a.cliente_id = conciliacion_movimientos.cliente_id and a.usuario_id = auth.uid()
  )
);

drop policy if exists conciliacion_delete on conciliacion_movimientos;
create policy conciliacion_delete on conciliacion_movimientos
for delete using (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    where a.cliente_id = conciliacion_movimientos.cliente_id and a.usuario_id = auth.uid()
  )
);
