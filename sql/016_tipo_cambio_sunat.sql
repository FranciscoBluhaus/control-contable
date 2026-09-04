-- ============================================================================
-- Caché de tipo de cambio oficial SUNAT (cotización SBS), por fecha publicada.
--
-- Se usa para autocompletar el campo "Tipo de cambio" de comprobantes en USD
-- cuando se guarda sin ese dato — el Worker consulta la página oficial de SUNAT
-- (e-consulta.sunat.gob.pe) una sola vez por fecha y el resultado queda cacheado
-- aquí para no repetir la consulta.
--
-- Sin cliente_id a propósito: es dato de referencia público, igual para
-- cualquier cliente del estudio — no hay boundary multi-tenant que aplicar.
-- Guarda compra Y venta (SUNAT publica ambos) aunque hoy el sistema solo usa
-- venta (numeral 17 del artículo 5 del Reglamento de la Ley del IGV — aplica
-- tanto a Registro de Ventas como de Compras) — guardar los dos evita tener
-- que volver a consultar si mañana se necesita el de compra por otro motivo.
-- ============================================================================

create table if not exists tipo_cambio_sunat (
  fecha date primary key,
  compra numeric(6,3) not null,
  venta numeric(6,3) not null,
  created_at timestamptz not null default now()
);

alter table tipo_cambio_sunat enable row level security;

-- Cualquier usuario autenticado puede leer y cachear — es data pública oficial,
-- sin información sensible del estudio ni de sus clientes.
drop policy if exists tipo_cambio_sunat_select on tipo_cambio_sunat;
create policy tipo_cambio_sunat_select on tipo_cambio_sunat
  for select to authenticated using (true);

drop policy if exists tipo_cambio_sunat_insert on tipo_cambio_sunat;
create policy tipo_cambio_sunat_insert on tipo_cambio_sunat
  for insert to authenticated with check (true);
