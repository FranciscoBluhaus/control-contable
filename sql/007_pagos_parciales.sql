-- ============================================================================
-- Pagos parciales para comprobantes_compra / comprobantes_venta.
--
-- Antes: cualquier pago (aunque fuera parcial) marcaba el comprobante como
-- 100% sustentado/cobrado. Ahora se suman TODOS los pagos vinculados y se
-- compara contra monto_total (compra) o neto_cobrar (venta) — igual que ya
-- hace abonado()/saldo()/estadoCuenta() en el frontend para "cuentas"
-- (impuestos/honorarios), solo que aquí en SQL porque el trigger corre en
-- la base de datos.
--
-- Nuevo estado intermedio: 'parcial_sustento' / 'parcial_cobro'.
-- ============================================================================

-- 1) Constraints: agregar el estado intermedio -----------------------------

alter table comprobantes_compra drop constraint comprobantes_compra_estado_check;
alter table comprobantes_compra add constraint comprobantes_compra_estado_check
  check (estado in ('pendiente_sustento', 'parcial_sustento', 'sustentado'));

alter table comprobantes_venta drop constraint comprobantes_venta_estado_check;
alter table comprobantes_venta add constraint comprobantes_venta_estado_check
  check (estado in ('pendiente_cobro', 'parcial_cobro', 'cobrado'));

-- 2) Trigger: suma todos los pagos en vez de solo comprobar que exista uno --

create or replace function trg_actualizar_estado_comprobante()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id_compra uuid;
  v_id_venta uuid;
  v_total numeric;
  v_pagado numeric;
  v_saldo numeric;
begin
  v_id_compra := coalesce(new.comprobante_compra_id, old.comprobante_compra_id);
  v_id_venta := coalesce(new.comprobante_venta_id, old.comprobante_venta_id);

  if v_id_compra is not null then
    select monto_total into v_total from comprobantes_compra where id = v_id_compra;
    select coalesce(sum(monto), 0) into v_pagado from pagos where comprobante_compra_id = v_id_compra;
    v_saldo := coalesce(v_total, 0) - v_pagado;
    update comprobantes_compra set estado = case
      when v_saldo <= 0.005 then 'sustentado'
      when v_pagado > 0 then 'parcial_sustento'
      else 'pendiente_sustento'
    end
    where id = v_id_compra;
  end if;

  if v_id_venta is not null then
    select neto_cobrar into v_total from comprobantes_venta where id = v_id_venta;
    select coalesce(sum(monto), 0) into v_pagado from pagos where comprobante_venta_id = v_id_venta;
    v_saldo := coalesce(v_total, 0) - v_pagado;
    update comprobantes_venta set estado = case
      when v_saldo <= 0.005 then 'cobrado'
      when v_pagado > 0 then 'parcial_cobro'
      else 'pendiente_cobro'
    end
    where id = v_id_venta;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

-- El trigger (creado en 001) ya apunta a esta función por nombre, no hace
-- falta recrearlo — reemplazar la función con CREATE OR REPLACE alcanza.

-- 3) Backfill: recalcula el estado de TODO lo existente con la lógica nueva.
-- Necesario porque `monto` en pagos nunca fue obligatorio — un comprobante
-- ya marcado "sustentado"/"cobrado" con un pago sin monto quedaría
-- inconsistente hasta que alguien vuelva a tocar sus pagos.

with saldos_compra as (
  select cc.id,
         coalesce((select sum(p.monto) from pagos p where p.comprobante_compra_id = cc.id), 0) as pagado,
         cc.monto_total - coalesce((select sum(p.monto) from pagos p where p.comprobante_compra_id = cc.id), 0) as saldo
  from comprobantes_compra cc
)
update comprobantes_compra cc
set estado = case
  when s.saldo <= 0.005 then 'sustentado'
  when s.pagado > 0 then 'parcial_sustento'
  else 'pendiente_sustento'
end
from saldos_compra s
where s.id = cc.id;

with saldos_venta as (
  select cv.id,
         coalesce((select sum(p.monto) from pagos p where p.comprobante_venta_id = cv.id), 0) as pagado,
         cv.neto_cobrar - coalesce((select sum(p.monto) from pagos p where p.comprobante_venta_id = cv.id), 0) as saldo
  from comprobantes_venta cv
)
update comprobantes_venta cv
set estado = case
  when s.saldo <= 0.005 then 'cobrado'
  when s.pagado > 0 then 'parcial_cobro'
  else 'pendiente_cobro'
end
from saldos_venta s
where s.id = cv.id;
