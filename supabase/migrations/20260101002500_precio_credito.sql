-- ════════════════════════════════════════════════════════════════════
-- Smile Lab · Presupuestos — 26 · El precio en crédito
--
-- La lista de precios del consultorio tiene dos columnas: efectivo o
-- transferencia, y «precio de lista en 3 cuotas sin interés con
-- crédito, los miércoles». Hasta acá el sistema guardaba un solo precio
-- por celda, así que el segundo número vivía en la planilla y el
-- presupuesto que recibía el paciente no lo decía.
--
-- El precio en crédito es OTRO precio de la misma prestación, no un
-- recargo calculado: la planilla no aplica un porcentaje parejo (la
-- consulta va de $ 45.000 a $ 50.000, el resto sube un 5 %). Por eso se
-- guarda tal cual, igual que el de efectivo, y viaja con la misma regla:
--
--   1. `aranceles.monto_credito` es parte de la vigencia. Append-only
--      como el resto: un precio en crédito nuevo es una vigencia nueva.
--      Null = esa celda no tiene precio en crédito.
--   2. El ítem del presupuesto lo COPIA (`monto_credito`) y congela lo
--      que queda a cargo pagando así (`a_cargo_credito`). Nunca se
--      resuelve por join.
--   3. La cabecera congela `total_a_cargo_credito`. Null cuando ningún
--      ítem tiene precio en crédito: el documento no ofrece la opción.
--
-- Cobertura: la obra social cubre lo mismo pague como pague el
-- paciente, así que el a-cargo en crédito sale de la misma cuenta de
-- siempre sobre el otro monto: `calcular_cobertura(monto_credito, …)`.
-- Con «ninguna» —el caso particular— es el precio en crédito entero.
--
-- Total en crédito con ítems mezclados: el que no tiene precio en
-- crédito suma su a-cargo de efectivo. Es lo que el consultorio cobra
-- de verdad por esa línea, pague como pague.
--
-- De paso, esta migración trae la versión de `crear_presupuesto()` de la
-- 25 (el afiliado de su obra social), que la reemplaza entera.
-- ════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────
-- 1) Columnas
-- ─────────────────────────────────────────────────────────────

alter table aranceles
  add column if not exists monto_credito numeric(12,2);

alter table aranceles
  drop constraint if exists aranceles_monto_credito_no_negativo,
  add constraint aranceles_monto_credito_no_negativo
    check (monto_credito is null or monto_credito >= 0);

comment on column aranceles.monto_credito is
  'Precio de lista pagando con crédito (3 cuotas sin interés, miércoles). '
  'Null = esta celda no tiene precio en crédito. Append-only como monto.';

alter table presupuesto_items
  add column if not exists monto_credito   numeric(12,2),
  add column if not exists a_cargo_credito numeric(12,2);

alter table presupuesto_items
  drop constraint if exists presupuesto_items_credito_coherente,
  add constraint presupuesto_items_credito_coherente
    check (
      (monto_credito is null and a_cargo_credito is null)
      or (monto_credito >= 0 and a_cargo_credito between 0 and monto_credito)
    );

alter table presupuestos
  add column if not exists total_a_cargo_credito numeric(12,2);

alter table presupuestos
  drop constraint if exists presupuestos_total_credito_no_negativo,
  add constraint presupuestos_total_credito_no_negativo
    check (total_a_cargo_credito is null or total_a_cargo_credito >= 0);

-- ─────────────────────────────────────────────────────────────
-- 2) El total en crédito también queda congelado al emitir
--
-- Misma guarda de la 20 con la columna nueva en la lista.
-- ─────────────────────────────────────────────────────────────

create or replace function guard_presupuesto_emitido() returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.estado = 'borrador' then
    return new;
  end if;

  if new.estado = 'borrador' then
    raise exception
      'Un presupuesto emitido no vuelve a borrador: duplicalo en lugar de reabrirlo';
  end if;

  if new.numero                is distinct from old.numero
     or new.paciente_id        is distinct from old.paciente_id
     or new.profesional_id     is distinct from old.profesional_id
     or new.obra_social_id     is distinct from old.obra_social_id
     or new.obra_social_nombre is distinct from old.obra_social_nombre
     or new.paciente_nombre    is distinct from old.paciente_nombre
     or new.paciente_dni       is distinct from old.paciente_dni
     or new.paciente_afiliado  is distinct from old.paciente_afiliado
     or new.profesional_nombre is distinct from old.profesional_nombre
     or new.profesional_matricula is distinct from old.profesional_matricula
     or new.fecha_emision      is distinct from old.fecha_emision
     or new.valido_hasta       is distinct from old.valido_hasta
     or new.subtotal           is distinct from old.subtotal
     or new.total_cobertura    is distinct from old.total_cobertura
     or new.total_a_cargo      is distinct from old.total_a_cargo
     or new.total_a_cargo_credito is distinct from old.total_a_cargo_credito
     or new.observaciones      is distinct from old.observaciones
     or new.duplicado_de       is distinct from old.duplicado_de
     or new.created_by         is distinct from old.created_by
     or new.created_at         is distinct from old.created_at
     or new.clave_alta         is distinct from old.clave_alta
  then
    raise exception
      'Los valores de un presupuesto emitido no se editan: duplicalo con los valores de hoy';
  end if;

  return new;
end $$;

-- ─────────────────────────────────────────────────────────────
-- 3) Nueva vigencia con precio en crédito
--
-- El parámetro nuevo va al final y con default: la app que está en
-- producción llama con seis argumentos nombrados y tiene que seguir
-- andando mientras se despliega la nueva. Se borra la firma vieja para
-- que no queden dos funciones y PostgREST no tenga que elegir.
-- ─────────────────────────────────────────────────────────────

drop function if exists nueva_vigencia(uuid, uuid, numeric, tipo_cobertura, numeric, date);

create or replace function nueva_vigencia(
  p_prestacion    uuid,
  p_obra_social   uuid,
  p_monto         numeric,
  p_cob_tipo      tipo_cobertura,
  p_cob_valor     numeric,
  p_desde         date,
  p_monto_credito numeric default null
) returns uuid
language plpgsql security definer
set search_path = public
as $$
declare v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'No autenticado';
  end if;

  -- La vigencia nueva no puede empezar antes o el mismo día que la abierta:
  -- dejaría un rango cerrado inválido (vigente_hasta < vigente_desde).
  if exists (
    select 1 from aranceles
     where prestacion_id = p_prestacion
       and obra_social_id is not distinct from p_obra_social
       and vigente_hasta is null
       and vigente_desde >= p_desde
  ) then
    raise exception
      'La vigencia nueva tiene que arrancar después del % de la vigencia actual',
      (select vigente_desde from aranceles
        where prestacion_id = p_prestacion
          and obra_social_id is not distinct from p_obra_social
          and vigente_hasta is null);
  end if;

  update aranceles
     set vigente_hasta = p_desde - interval '1 day'
   where prestacion_id = p_prestacion
     and obra_social_id is not distinct from p_obra_social
     and vigente_hasta is null;

  insert into aranceles (prestacion_id, obra_social_id, monto, monto_credito,
                         cobertura_tipo, cobertura_valor, vigente_desde, created_by)
  values (p_prestacion, p_obra_social, p_monto, p_monto_credito,
          p_cob_tipo, p_cob_valor, p_desde, auth.uid())
  returning id into v_id;

  return v_id;
end $$;

revoke execute on function nueva_vigencia(uuid, uuid, numeric, tipo_cobertura, numeric, date, numeric) from public, anon;
grant execute on function nueva_vigencia(uuid, uuid, numeric, tipo_cobertura, numeric, date, numeric) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- 4) El aumento masivo sube los dos precios
--
-- Sin esto, un +10 % abría una vigencia nueva con el precio en crédito
-- en null: el aumento borraba la opción de pagar con crédito sin que
-- nadie lo pidiera. Misma cuenta que `montoConAumento()`.
-- ─────────────────────────────────────────────────────────────

create or replace function aumento_masivo(
  p_rubro        text,
  p_obra_social  uuid,
  p_solo_particular boolean,
  p_pct          numeric,
  p_desde        date
) returns int
language plpgsql security definer
set search_path = public
as $$
declare
  r record;
  n int := 0;
begin
  if auth.uid() is null then
    raise exception 'No autenticado';
  end if;

  for r in
    select a.prestacion_id, a.obra_social_id, a.monto, a.monto_credito,
           a.cobertura_tipo, a.cobertura_valor
      from aranceles a
      join prestaciones p on p.id = a.prestacion_id
     where a.vigente_hasta is null
       and a.vigente_desde < p_desde
       and (p_rubro is null or p.rubro = p_rubro)
       and (
         case
           when p_solo_particular then a.obra_social_id is null
           when p_obra_social is not null then a.obra_social_id = p_obra_social
           else true
         end
       )
  loop
    perform nueva_vigencia(
      r.prestacion_id,
      r.obra_social_id,
      round(r.monto * (100 + p_pct) / 100),
      r.cobertura_tipo,
      r.cobertura_valor,
      p_desde,
      round(r.monto_credito * (100 + p_pct) / 100)
    );
    n := n + 1;
  end loop;

  return n;
end $$;

revoke execute on function aumento_masivo(text, uuid, boolean, numeric, date) from public, anon;
grant execute on function aumento_masivo(text, uuid, boolean, numeric, date) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- 5) Las vistas de la pantalla 10
--
-- `a.*` se expande al crear la vista: sin recrearlas, la columna nueva
-- no aparece. Y `create or replace` sólo deja agregar al final, así que
-- van con drop. Mismas definiciones que la 07.
-- ─────────────────────────────────────────────────────────────

drop view if exists aranceles_vigentes;

create view aranceles_vigentes with (security_invoker = true) as
select a.*, p.nombre as prestacion, p.codigo, p.rubro,
       coalesce(os.nombre || coalesce(' ' || os.plan, ''), 'Particular') as obra_social,
       (select count(*) from presupuesto_items pi where pi.arancel_id = a.id) as usos
  from aranceles a
  join prestaciones p on p.id = a.prestacion_id
  left join obras_sociales os on os.id = a.obra_social_id
 where a.vigente_desde <= current_date
   and (a.vigente_hasta is null or a.vigente_hasta >= current_date);

drop view if exists aranceles_programados;

create view aranceles_programados with (security_invoker = true) as
select a.*, p.nombre as prestacion, p.codigo, p.rubro,
       coalesce(os.nombre || coalesce(' ' || os.plan, ''), 'Particular') as obra_social,
       (a.vigente_desde - current_date) as dias_para_arrancar
  from aranceles a
  join prestaciones p on p.id = a.prestacion_id
  left join obras_sociales os on os.id = a.obra_social_id
 where a.vigente_desde > current_date;

grant select on aranceles_vigentes, aranceles_programados to authenticated;

-- ─────────────────────────────────────────────────────────────
-- 6) El alta congela el precio en crédito
--
-- Igual a la 25 más el crédito: el ítem lo trae del arancel (el wizard
-- lo copia al elegir la prestación) y la base resuelve el a-cargo.
-- ─────────────────────────────────────────────────────────────

create or replace function crear_presupuesto(p_payload jsonb)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare
  v_id            uuid;
  v_numero        text;
  v_clave         uuid;
  v_pac           pacientes%rowtype;
  v_prof          profesionales%rowtype;
  v_os_nombre     text;
  v_os_id         uuid;
  v_afiliado      text;
  v_estado        estado_presupuesto;
  v_item          jsonb;
  v_cuota         jsonb;
  v_orden         int := 0;
  v_monto         numeric;
  v_tipo          tipo_cobertura;
  v_valor         numeric;
  v_cob           numeric;
  v_credito       numeric;
  v_cargo_credito numeric;
  v_hay_credito   boolean := false;
  v_subtotal      numeric := 0;
  v_total_cob     numeric := 0;
  v_total_cargo   numeric := 0;
  v_total_credito numeric := 0;
  v_acum          numeric := 0;
  v_cuotas_n      int;
  v_cuotas_creadas int := 0;
  v_cuota_monto   numeric;
begin
  if auth.uid() is null then
    raise exception 'No autenticado';
  end if;

  -- ── Idempotencia: ¿esta alta ya emitió un documento? ──
  v_clave := nullif(p_payload ->> 'clave_alta', '')::uuid;
  if v_clave is not null then
    select id into v_id from presupuestos where clave_alta = v_clave;
    if v_id is not null then
      return v_id;
    end if;
  end if;

  v_estado := coalesce((p_payload ->> 'estado')::estado_presupuesto, 'realizado');
  if v_estado not in ('borrador','realizado','enviado') then
    raise exception 'Estado inicial inválido: %', v_estado;
  end if;

  if jsonb_array_length(coalesce(p_payload -> 'items', '[]'::jsonb)) = 0 then
    raise exception 'Un presupuesto necesita al menos una prestación';
  end if;

  select * into v_pac from pacientes where id = (p_payload ->> 'paciente_id')::uuid;
  if not found then raise exception 'Paciente inexistente'; end if;

  select * into v_prof from profesionales where id = (p_payload ->> 'profesional_id')::uuid;
  if not found then raise exception 'Profesional inexistente'; end if;

  v_os_id := nullif(p_payload ->> 'obra_social_id', '')::uuid;
  select nombre || coalesce(' ' || plan, '') into v_os_nombre
    from obras_sociales where id = v_os_id;

  -- ── El afiliado, sólo si es de ESTA obra social ──
  -- Sin obra social (particular) no hay afiliado que mostrar; con una
  -- distinta a la de la ficha, el número de la ficha no aplica. En los
  -- dos casos el documento sale sin número, que es la verdad.
  v_afiliado := case
                  when v_os_id is not null and v_os_id = v_pac.obra_social_id
                    then v_pac.nro_afiliado
                  else null
                end;

  insert into presupuestos (
    paciente_id, profesional_id, obra_social_id, obra_social_nombre,
    paciente_nombre, paciente_dni, paciente_telefono, paciente_afiliado,
    profesional_nombre, profesional_matricula,
    fecha_emision, valido_hasta, observaciones, nota_interna,
    estado, created_by, clave_alta
  ) values (
    v_pac.id, v_prof.id, v_os_id, v_os_nombre,
    v_pac.nombre, v_pac.dni, v_pac.telefono, v_afiliado,
    v_prof.nombre, v_prof.matricula,
    coalesce((p_payload ->> 'fecha_emision')::date, current_date),
    coalesce((p_payload ->> 'valido_hasta')::date, current_date + 30),
    nullif(p_payload ->> 'observaciones', ''),
    nullif(p_payload ->> 'nota_interna', ''),
    'borrador', auth.uid(), v_clave
  )
  returning id, numero into v_id, v_numero;

  -- ── Ítems: snapshot completo, cobertura resuelta en el servidor ──
  for v_item in select * from jsonb_array_elements(p_payload -> 'items')
  loop
    v_monto   := (v_item ->> 'monto')::numeric;
    v_tipo    := coalesce((v_item ->> 'cobertura_tipo')::tipo_cobertura, 'ninguna');
    v_valor   := coalesce((v_item ->> 'cobertura_valor')::numeric, 0);
    v_cob     := calcular_cobertura(v_monto, v_tipo, v_valor);
    v_credito := nullif(v_item ->> 'monto_credito', '')::numeric;

    if v_credito is not null then
      v_cargo_credito := v_credito - calcular_cobertura(v_credito, v_tipo, v_valor);
      v_hay_credito   := true;
    else
      v_cargo_credito := null;
    end if;

    insert into presupuesto_items (
      presupuesto_id, orden, prestacion_id, arancel_id,
      nombre, codigo, descripcion, detalle,
      monto, cobertura_tipo, cobertura_valor, cobertura_monto, a_cargo,
      monto_credito, a_cargo_credito,
      editado, cobertura_original_tipo, cobertura_original_valor, motivo_override
    ) values (
      v_id, v_orden,
      nullif(v_item ->> 'prestacion_id', '')::uuid,
      nullif(v_item ->> 'arancel_id', '')::uuid,
      v_item ->> 'nombre',
      nullif(v_item ->> 'codigo', ''),
      nullif(v_item ->> 'descripcion', ''),
      nullif(v_item ->> 'detalle', ''),
      v_monto, v_tipo, v_valor, v_cob, v_monto - v_cob,
      v_credito, v_cargo_credito,
      coalesce((v_item ->> 'editado')::boolean, false),
      nullif(v_item ->> 'cobertura_original_tipo', '')::tipo_cobertura,
      nullif(v_item ->> 'cobertura_original_valor', '')::numeric,
      nullif(v_item ->> 'motivo_override', '')
    );

    v_subtotal      := v_subtotal + v_monto;
    v_total_cob     := v_total_cob + v_cob;
    v_total_cargo   := v_total_cargo + (v_monto - v_cob);
    v_total_credito := v_total_credito + coalesce(v_cargo_credito, v_monto - v_cob);
    v_orden         := v_orden + 1;
  end loop;

  -- ── Cuotas: el porcentaje manda, la última absorbe el redondeo ──
  v_cuotas_n := jsonb_array_length(coalesce(p_payload -> 'cuotas', '[]'::jsonb));
  if v_cuotas_n > 0 then
    if abs(coalesce((
      select sum((c ->> 'porcentaje')::numeric)
        from jsonb_array_elements(p_payload -> 'cuotas') c
    ), 0) - 100) > 0.01 then
      raise exception 'Las condiciones de pago tienen que sumar 100 %%';
    end if;

    v_orden := 0;
    for v_cuota in select * from jsonb_array_elements(p_payload -> 'cuotas')
    loop
      if v_orden = v_cuotas_n - 1 then
        v_cuota_monto := v_total_cargo - v_acum;      -- resto exacto
      else
        v_cuota_monto := round(v_total_cargo * ((v_cuota ->> 'porcentaje')::numeric / 100.0));
        v_acum := v_acum + v_cuota_monto;
      end if;

      insert into presupuesto_cuotas (presupuesto_id, orden, etiqueta, porcentaje, monto)
      values (v_id, v_orden, v_cuota ->> 'etiqueta',
              nullif(v_cuota ->> 'porcentaje', '')::numeric, v_cuota_monto);

      v_orden := v_orden + 1;
      v_cuotas_creadas := v_cuotas_creadas + 1;
    end loop;
  end if;

  update presupuestos
     set subtotal = v_subtotal,
         total_cobertura = v_total_cob,
         total_a_cargo = v_total_cargo,
         total_a_cargo_credito = case when v_hay_credito then v_total_credito end,
         estado = v_estado,
         estado_desde = now()
   where id = v_id;

  insert into presupuesto_eventos (presupuesto_id, tipo, descripcion, estado_nuevo, autor_id, autor_nombre)
  values (v_id, 'creado',
          'Presupuesto ' || v_numero || ' creado con ' ||
          jsonb_array_length(p_payload -> 'items') || ' prestación(es)' ||
          case when v_cuotas_creadas > 0
               then ' y ' || v_cuotas_creadas || ' condición(es) de pago'
               else ' y pago en un solo momento' end,
          v_estado, auth.uid(), actor_nombre());

  return v_id;

exception
  when unique_violation then
    if v_clave is null then raise; end if;
    select id into v_id from presupuestos where clave_alta = v_clave;
    if v_id is null then raise; end if;
    return v_id;
end $$;

revoke execute on function crear_presupuesto(jsonb) from public, anon;
grant execute on function crear_presupuesto(jsonb) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- 7) Duplicar trae el precio en crédito de hoy
--
-- Igual a la 14 más el crédito. Con arancel vigente, el de hoy (que
-- puede no tener precio en crédito: entonces el duplicado no lo ofrece).
-- Sin arancel vigente, el que traía el ítem original.
-- ─────────────────────────────────────────────────────────────

create or replace function duplicar_presupuesto(p_id uuid)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare
  v_orig        presupuestos%rowtype;
  v_new         uuid;
  v_numero      text;
  v_it          record;
  v_ar          aranceles%rowtype;
  v_os_item     uuid;
  v_monto       numeric;
  v_tipo        tipo_cobertura;
  v_valor       numeric;
  v_cob         numeric;
  v_credito     numeric;
  v_cargo_credito numeric;
  v_hay_credito boolean := false;
  v_arancel_id  uuid;
  v_vig_dias    int;
  v_subtotal    numeric := 0;
  v_total_cob   numeric := 0;
  v_total_cargo numeric := 0;
  v_total_credito numeric := 0;
  v_orden       int := 0;
  v_overrides   int := 0;
  v_cuota       record;
  v_cuotas_n    int;
  v_acum        numeric := 0;
  v_cuota_monto numeric;
begin
  if auth.uid() is null then
    raise exception 'No autenticado';
  end if;

  select * into v_orig from presupuestos where id = p_id;
  if not found then raise exception 'Presupuesto inexistente'; end if;

  select coalesce(max(p.vigencia_dias), 30) into v_vig_dias
    from presupuesto_items pi
    join prestaciones p on p.id = pi.prestacion_id
   where pi.presupuesto_id = p_id;

  insert into presupuestos (
    paciente_id, profesional_id, obra_social_id, obra_social_nombre,
    paciente_nombre, paciente_dni, paciente_telefono, paciente_afiliado,
    profesional_nombre, profesional_matricula,
    fecha_emision, valido_hasta, observaciones,
    estado, duplicado_de, created_by
  )
  select
    p.paciente_id, p.profesional_id, p.obra_social_id, p.obra_social_nombre,
    -- Nombre, DNI y teléfono se refrescan desde la ficha: son datos de
    -- contacto, no precios.
    coalesce(pac.nombre, p.paciente_nombre),
    coalesce(pac.dni, p.paciente_dni),
    coalesce(pac.telefono, p.paciente_telefono),
    -- El afiliado pertenece a UNA obra social: sólo se refresca si la
    -- ficha sigue en la misma que el presupuesto. Si el paciente cambió
    -- de cobertura, mezclar los dos daría un documento incoherente.
    case
      when pac.obra_social_id is not distinct from p.obra_social_id
        then coalesce(pac.nro_afiliado, p.paciente_afiliado)
      else p.paciente_afiliado
    end,
    p.profesional_nombre, p.profesional_matricula,
    current_date, current_date + v_vig_dias, p.observaciones,
    'borrador', p.id, auth.uid()
  from presupuestos p
  left join pacientes pac on pac.id = p.paciente_id
  where p.id = p_id
  returning id, numero into v_new, v_numero;

  for v_it in
    select * from presupuesto_items where presupuesto_id = p_id order by orden
  loop
    if v_it.arancel_id is not null then
      select obra_social_id into v_os_item from aranceles where id = v_it.arancel_id;
    else
      v_os_item := v_orig.obra_social_id;
    end if;

    v_ar := null;
    if v_it.prestacion_id is not null then
      select * into v_ar from arancel_vigente(v_it.prestacion_id, v_os_item);
    end if;

    if v_ar.id is not null then
      v_monto      := v_ar.monto;
      v_credito    := v_ar.monto_credito;
      v_tipo       := v_ar.cobertura_tipo;
      v_valor      := v_ar.cobertura_valor;
      v_arancel_id := v_ar.id;
    else
      v_monto      := v_it.monto;
      v_credito    := v_it.monto_credito;
      v_tipo       := v_it.cobertura_tipo;
      v_valor      := v_it.cobertura_valor;
      v_arancel_id := v_it.arancel_id;
    end if;

    v_cob := calcular_cobertura(v_monto, v_tipo, v_valor);

    if v_credito is not null then
      v_cargo_credito := v_credito - calcular_cobertura(v_credito, v_tipo, v_valor);
      v_hay_credito   := true;
    else
      v_cargo_credito := null;
    end if;

    insert into presupuesto_items (
      presupuesto_id, orden, prestacion_id, arancel_id,
      nombre, codigo, descripcion, detalle,
      monto, cobertura_tipo, cobertura_valor, cobertura_monto, a_cargo,
      monto_credito, a_cargo_credito
    ) values (
      v_new, v_orden, v_it.prestacion_id, v_arancel_id,
      coalesce((select nombre from prestaciones where id = v_it.prestacion_id), v_it.nombre),
      v_it.codigo,
      coalesce((select descripcion from prestaciones where id = v_it.prestacion_id), v_it.descripcion),
      v_it.detalle,
      v_monto, v_tipo, v_valor, v_cob, v_monto - v_cob,
      v_credito, v_cargo_credito
    );

    v_subtotal      := v_subtotal + v_monto;
    v_total_cob     := v_total_cob + v_cob;
    v_total_cargo   := v_total_cargo + (v_monto - v_cob);
    v_total_credito := v_total_credito + coalesce(v_cargo_credito, v_monto - v_cob);
    v_orden         := v_orden + 1;
  end loop;

  select count(*) into v_cuotas_n from presupuesto_cuotas where presupuesto_id = p_id;
  if v_cuotas_n > 0 then
    v_orden := 0;
    for v_cuota in
      select etiqueta, porcentaje from presupuesto_cuotas
       where presupuesto_id = p_id order by orden
    loop
      if v_orden = v_cuotas_n - 1 then
        -- Piso en 0: un negativo abortaría la emisión entera contra el
        -- check de `presupuesto_cuotas`.
        v_cuota_monto := greatest(0::numeric, v_total_cargo - v_acum);
      else
        v_cuota_monto := round(v_total_cargo * (coalesce(v_cuota.porcentaje, 0) / 100.0));
        v_acum := v_acum + v_cuota_monto;
      end if;

      insert into presupuesto_cuotas (presupuesto_id, orden, etiqueta, porcentaje, monto)
      values (v_new, v_orden, v_cuota.etiqueta, v_cuota.porcentaje, v_cuota_monto);

      v_orden := v_orden + 1;
    end loop;
  end if;

  update presupuestos
     set subtotal = v_subtotal,
         total_cobertura = v_total_cob,
         total_a_cargo = v_total_cargo,
         total_a_cargo_credito = case when v_hay_credito then v_total_credito end
   where id = v_new;

  select count(*) into v_overrides
    from presupuesto_items where presupuesto_id = p_id and editado;

  insert into presupuesto_eventos (presupuesto_id, tipo, descripcion, estado_nuevo, autor_id, autor_nombre)
  values (v_new, 'duplicado',
          'Duplicado de ' || v_orig.numero || ' con los valores vigentes al ' ||
          to_char(current_date, 'DD/MM/YYYY') ||
          case when v_overrides > 0
               then '. No se heredaron ' || v_overrides || ' cobertura(s) editada(s) a mano.'
               else '' end,
          'borrador', auth.uid(), actor_nombre());

  insert into presupuesto_eventos (presupuesto_id, tipo, descripcion, autor_id, autor_nombre)
  values (p_id, 'duplicado', 'Se duplicó en ' || v_numero, auth.uid(), actor_nombre());

  return v_new;
end $$;

revoke execute on function duplicar_presupuesto(uuid) from public, anon;
grant execute on function duplicar_presupuesto(uuid) to authenticated;
