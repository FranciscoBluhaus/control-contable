-- ============================================================================
-- Módulo de Comprobantes (compras/ventas/pagos) — feature/comprobantes
-- Paso 1 del plan (CONTEXTO_PROYECTO.md): tablas nuevas + RLS.
--
-- Cómo aplicar: pega este archivo completo en el SQL Editor de Supabase
-- (Database > SQL Editor) y ejecútalo una sola vez. Es idempotente donde
-- fue razonable (checks "if not exists" / "on conflict"), pero de todas
-- formas pruébalo primero en un proyecto/rama de desarrollo si tienes uno.
--
-- Patrón de roles reutilizado (igual que ya usan `clientes`/`cuentas`):
--   - super_admin: acceso total a las 3 tablas nuevas.
--   - usuario (personal del estudio): acceso a comprobantes/pagos de los
--     clientes que tenga en `asignaciones_clientes`, igual que hoy ya
--     puede con `cuentas` de categoría 'impuesto'.
--   - cliente (rol NUEVO, no existía en el sistema): mismo mecanismo — se
--     le crea UNA fila en `asignaciones_clientes` que apunta a su propia
--     empresa, y con eso ya cae dentro del mismo predicado de RLS que
--     'usuario'. No se creó una tabla ni columna nueva para esto: se
--     reusa `asignaciones_clientes` tal cual, un cliente-login = una
--     asignación a su propio cliente_id.
--
-- Decisión de negocio confirmada por el usuario: comprobantes_venta NO
-- queda restringido a super_admin — usuario asignado y el propio cliente
-- también pueden crear/editar, igual que ya pasa con cuentas/impuesto.
-- Por eso las 3 tablas comparten el mismo predicado en las 4 operaciones
-- (select/insert/update/delete), sin excepciones por rol.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) TABLAS
-- ----------------------------------------------------------------------------

create table if not exists comprobantes_compra (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references clientes(id) on delete restrict,
  archivo_url text not null,              -- path en el bucket de Storage 'comprobantes'
  ruc_proveedor text,
  razon_social_proveedor text,
  fecha_emision date,
  tipo_comprobante text,                  -- factura, boleta, recibo por honorarios, etc.
  numero_comprobante text,
  monto_total numeric(12,2),
  monto_igv numeric(12,2),
  estado text not null default 'pendiente_sustento'
    check (estado in ('pendiente_sustento','sustentado')),
  ocr_raw jsonb,                          -- respuesta cruda de Gemini, para auditoría
  subido_por uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists comprobantes_venta (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references clientes(id) on delete restrict,
  archivo_url text not null,
  ruc_cliente_final text,                 -- a quién le factura el cliente del estudio
  razon_social_cliente_final text,
  fecha_emision date,
  tipo_comprobante text,
  numero_comprobante text,
  monto_total numeric(12,2),
  detraccion_pct numeric(5,2),
  detraccion_monto numeric(12,2),
  neto_cobrar numeric(12,2),
  estado text not null default 'pendiente_cobro'
    check (estado in ('pendiente_cobro','cobrado')),
  ocr_raw jsonb,
  subido_por uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists pagos (
  id uuid primary key default gen_random_uuid(),
  comprobante_compra_id uuid references comprobantes_compra(id) on delete cascade,
  comprobante_venta_id uuid references comprobantes_venta(id) on delete cascade,
  archivo_url text not null,              -- voucher/captura de banco
  monto numeric(12,2),
  fecha_pago date,
  metodo text,                            -- transferencia, detracción, efectivo, etc.
  subido_por uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  constraint chk_un_comprobante check (
    (comprobante_compra_id is not null)::int + (comprobante_venta_id is not null)::int = 1
  )
);

create index if not exists idx_comprobantes_compra_cliente on comprobantes_compra(cliente_id);
create index if not exists idx_comprobantes_venta_cliente on comprobantes_venta(cliente_id);
create index if not exists idx_pagos_compra on pagos(comprobante_compra_id);
create index if not exists idx_pagos_venta on pagos(comprobante_venta_id);

-- ----------------------------------------------------------------------------
-- 2) RLS — mismo predicado en las 3 tablas, mismo patrón que `cuentas`
-- ----------------------------------------------------------------------------

alter table comprobantes_compra enable row level security;
alter table comprobantes_venta enable row level security;
alter table pagos enable row level security;

-- comprobantes_compra ---------------------------------------------------

create policy comprobantes_compra_select on comprobantes_compra
for select using (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    where a.cliente_id = comprobantes_compra.cliente_id and a.usuario_id = auth.uid()
  )
);

create policy comprobantes_compra_insert on comprobantes_compra
for insert with check (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    where a.cliente_id = comprobantes_compra.cliente_id and a.usuario_id = auth.uid()
  )
);

create policy comprobantes_compra_update on comprobantes_compra
for update using (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    where a.cliente_id = comprobantes_compra.cliente_id and a.usuario_id = auth.uid()
  )
) with check (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    where a.cliente_id = comprobantes_compra.cliente_id and a.usuario_id = auth.uid()
  )
);

create policy comprobantes_compra_delete on comprobantes_compra
for delete using (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    where a.cliente_id = comprobantes_compra.cliente_id and a.usuario_id = auth.uid()
  )
);

-- comprobantes_venta -----------------------------------------------------

create policy comprobantes_venta_select on comprobantes_venta
for select using (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    where a.cliente_id = comprobantes_venta.cliente_id and a.usuario_id = auth.uid()
  )
);

create policy comprobantes_venta_insert on comprobantes_venta
for insert with check (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    where a.cliente_id = comprobantes_venta.cliente_id and a.usuario_id = auth.uid()
  )
);

create policy comprobantes_venta_update on comprobantes_venta
for update using (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    where a.cliente_id = comprobantes_venta.cliente_id and a.usuario_id = auth.uid()
  )
) with check (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    where a.cliente_id = comprobantes_venta.cliente_id and a.usuario_id = auth.uid()
  )
);

create policy comprobantes_venta_delete on comprobantes_venta
for delete using (
  is_super_admin() or exists (
    select 1 from asignaciones_clientes a
    where a.cliente_id = comprobantes_venta.cliente_id and a.usuario_id = auth.uid()
  )
);

-- pagos --------------------------------------------------------------------
-- pagos no tiene cliente_id propio: se llega a él vía el comprobante padre,
-- igual que `abonos` llega a su cliente_id vía `cuentas`.

create policy pagos_select on pagos
for select using (
  is_super_admin()
  or exists (
    select 1 from comprobantes_compra cc
    join asignaciones_clientes a on a.cliente_id = cc.cliente_id
    where cc.id = pagos.comprobante_compra_id and a.usuario_id = auth.uid()
  )
  or exists (
    select 1 from comprobantes_venta cv
    join asignaciones_clientes a on a.cliente_id = cv.cliente_id
    where cv.id = pagos.comprobante_venta_id and a.usuario_id = auth.uid()
  )
);

create policy pagos_insert on pagos
for insert with check (
  is_super_admin()
  or exists (
    select 1 from comprobantes_compra cc
    join asignaciones_clientes a on a.cliente_id = cc.cliente_id
    where cc.id = pagos.comprobante_compra_id and a.usuario_id = auth.uid()
  )
  or exists (
    select 1 from comprobantes_venta cv
    join asignaciones_clientes a on a.cliente_id = cv.cliente_id
    where cv.id = pagos.comprobante_venta_id and a.usuario_id = auth.uid()
  )
);

create policy pagos_update on pagos
for update using (
  is_super_admin()
  or exists (
    select 1 from comprobantes_compra cc
    join asignaciones_clientes a on a.cliente_id = cc.cliente_id
    where cc.id = pagos.comprobante_compra_id and a.usuario_id = auth.uid()
  )
  or exists (
    select 1 from comprobantes_venta cv
    join asignaciones_clientes a on a.cliente_id = cv.cliente_id
    where cv.id = pagos.comprobante_venta_id and a.usuario_id = auth.uid()
  )
) with check (
  is_super_admin()
  or exists (
    select 1 from comprobantes_compra cc
    join asignaciones_clientes a on a.cliente_id = cc.cliente_id
    where cc.id = pagos.comprobante_compra_id and a.usuario_id = auth.uid()
  )
  or exists (
    select 1 from comprobantes_venta cv
    join asignaciones_clientes a on a.cliente_id = cv.cliente_id
    where cv.id = pagos.comprobante_venta_id and a.usuario_id = auth.uid()
  )
);

create policy pagos_delete on pagos
for delete using (
  is_super_admin()
  or exists (
    select 1 from comprobantes_compra cc
    join asignaciones_clientes a on a.cliente_id = cc.cliente_id
    where cc.id = pagos.comprobante_compra_id and a.usuario_id = auth.uid()
  )
  or exists (
    select 1 from comprobantes_venta cv
    join asignaciones_clientes a on a.cliente_id = cv.cliente_id
    where cv.id = pagos.comprobante_venta_id and a.usuario_id = auth.uid()
  )
);

-- ----------------------------------------------------------------------------
-- 3) Trigger: deriva `estado` automáticamente a partir de los pagos
--    ("pendiente_sustento" -> "sustentado" cuando aparece un pago vinculado,
--    y viceversa si se borra). Así el estado no se edita a mano desde la UI,
--    tal como lo describe el flujo de negocio del plan.
--    SECURITY DEFINER: corre con permisos de owner, así no depende de que
--    quien sube el pago (cliente/usuario) tenga UPDATE directo sobre estado.
-- ----------------------------------------------------------------------------

create or replace function trg_actualizar_estado_comprobante()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (tg_op = 'DELETE') then
    if old.comprobante_compra_id is not null then
      update comprobantes_compra set estado = case
        when exists(select 1 from pagos where comprobante_compra_id = old.comprobante_compra_id)
        then 'sustentado' else 'pendiente_sustento' end
      where id = old.comprobante_compra_id;
    end if;
    if old.comprobante_venta_id is not null then
      update comprobantes_venta set estado = case
        when exists(select 1 from pagos where comprobante_venta_id = old.comprobante_venta_id)
        then 'cobrado' else 'pendiente_cobro' end
      where id = old.comprobante_venta_id;
    end if;
    return old;
  else
    if new.comprobante_compra_id is not null then
      update comprobantes_compra set estado = 'sustentado' where id = new.comprobante_compra_id;
    end if;
    if new.comprobante_venta_id is not null then
      update comprobantes_venta set estado = 'cobrado' where id = new.comprobante_venta_id;
    end if;
    return new;
  end if;
end;
$$;

drop trigger if exists pagos_actualiza_estado on pagos;
create trigger pagos_actualiza_estado
after insert or delete on pagos
for each row execute function trg_actualizar_estado_comprobante();

-- ----------------------------------------------------------------------------
-- 4) Storage: bucket privado 'comprobantes' + políticas con el mismo patrón
--    Convención de path: <cliente_id>/<algo>.ext  (el primer segmento del
--    path DEBE ser el cliente_id en texto, es lo que usan las políticas
--    de abajo para saber a qué cliente pertenece el archivo).
-- ----------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('comprobantes', 'comprobantes', false)
on conflict (id) do nothing;

create policy comprobantes_storage_select on storage.objects
for select using (
  bucket_id = 'comprobantes' and (
    is_super_admin() or exists (
      select 1 from asignaciones_clientes a
      where a.usuario_id = auth.uid()
        and a.cliente_id::text = (storage.foldername(name))[1]
    )
  )
);

create policy comprobantes_storage_insert on storage.objects
for insert with check (
  bucket_id = 'comprobantes' and (
    is_super_admin() or exists (
      select 1 from asignaciones_clientes a
      where a.usuario_id = auth.uid()
        and a.cliente_id::text = (storage.foldername(name))[1]
    )
  )
);

create policy comprobantes_storage_update on storage.objects
for update using (
  bucket_id = 'comprobantes' and (
    is_super_admin() or exists (
      select 1 from asignaciones_clientes a
      where a.usuario_id = auth.uid()
        and a.cliente_id::text = (storage.foldername(name))[1]
    )
  )
);

create policy comprobantes_storage_delete on storage.objects
for delete using (
  bucket_id = 'comprobantes' and (
    is_super_admin() or exists (
      select 1 from asignaciones_clientes a
      where a.usuario_id = auth.uid()
        and a.cliente_id::text = (storage.foldername(name))[1]
    )
  )
);

-- ============================================================================
-- PENDIENTE — fuera del alcance de este archivo, para pasos siguientes del plan:
--
-- 1. `perfiles.rol` necesita aceptar el valor 'cliente' además de
--    'super_admin'/'usuario'. No hay CHECK constraint visible en `perfiles`
--    que lo bloquee (bootstrapPerfil() ya inserta valores libres), pero
--    confírmalo en Supabase antes de usarlo. La política
--    `perfiles_insert_self` solo permite auto-insertarse como 'usuario' (o
--    'super_admin' si la tabla está vacía) — eso está BIEN así: un cliente
--    NO debe poder auto-registrarse con ese rol. Su perfil lo debe crear el
--    super_admin (perfiles_update_admin / o insertando directo como owner),
--    igual que hoy se invita a un 'usuario'.
--
-- 2. La Edge Function `admin-create-user` (la que usa "Invitar usuario",
--    index.html:3638) hoy solo recibe {email} y siempre crea rol='usuario'.
--    Para invitar clientes hay que extenderla a aceptar {email, rol,
--    cliente_id} y, tras crear el auth.user + perfil, insertar también la
--    fila en asignaciones_clientes. Esa función vive en Supabase (Deno),
--    no en este repo — nos hace falta su código fuente o recrearla.
--
-- 3. Falta la UI: vista "Mis Comprobantes" para cliente, vista de carga de
--    ventas para admin/usuario, e integración del OCR (Gemini vía
--    Cloudflare Worker). Eso es el paso 3+ del plan, no este archivo.
-- ============================================================================
