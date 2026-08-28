-- ============================================================================
-- Retención (compra y venta) + Moneda (PEN/USD) en comprobantes.
--
-- RETENCIÓN: nuevas columnas monto_retencion/porcentaje_retencion en ambas
-- tablas. Aplica también a venta (no solo compra) porque, igual que ya pasa
-- con la detracción, si a tu cliente le retienen renta al pagarle, el neto
-- que realmente cobra es menor. El trigger de estado debe comparar contra
-- el NETO en ambos casos:
--   - compra: se compara contra (monto_total - monto_retencion), calculado
--     al vuelo — no se guarda como columna nueva.
--   - venta: neto_cobrar ya es una columna guardada; el frontend pasa a
--     calcularla como (monto_total - detraccion_monto - retencion_monto).
--     El trigger no cambia para venta, sigue leyendo neto_cobrar tal cual.
--
-- MONEDA: nueva columna moneda ('PEN'/'USD', default 'PEN') en ambas tablas.
-- No se toca ningún cálculo de agregación acá — eso se resuelve en el
-- frontend agrupando por moneda antes de sumar (nunca se mezclan soles con
-- dólares en un mismo total).
-- ============================================================================

alter table comprobantes_compra
  add column if not exists monto_retencion numeric(12,2),
  add column if not exists porcentaje_retencion numeric(5,2),
  add column if not exists moneda text not null default 'PEN';
alter table comprobantes_compra
  add constraint comprobantes_compra_moneda_check check (moneda in ('PEN','USD'));

alter table comprobantes_venta
  add column if not exists monto_retencion numeric(12,2),
  add column if not exists porcentaje_retencion numeric(5,2),
  add column if not exists moneda text not null default 'PEN';
alter table comprobantes_venta
  add constraint comprobantes_venta_moneda_check check (moneda in ('PEN','USD'));

-- Trigger: la rama de compra ahora compara contra el neto (monto_total -
-- monto_retencion) en vez del bruto. La rama de venta no cambia.
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
    select monto_total - coalesce(monto_retencion, 0) into v_total
    from comprobantes_compra where id = v_id_compra;
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

-- Backfill de compra: los registros existentes tienen monto_retencion NULL
-- (0 vía coalesce), así que esto es un no-op para datos viejos — se incluye
-- solo por seguridad/consistencia, ya que la fórmula del estado cambió.
with saldos_compra as (
  select cc.id,
         coalesce((select sum(p.monto) from pagos p where p.comprobante_compra_id = cc.id), 0) as pagado,
         (cc.monto_total - coalesce(cc.monto_retencion, 0)) - coalesce((select sum(p.monto) from pagos p where p.comprobante_compra_id = cc.id), 0) as saldo
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
