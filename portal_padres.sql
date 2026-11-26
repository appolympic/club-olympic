-- =====================================================================
--  Club Deportivo Olympic · Actualización: Portal de padres y acudientes
--  Pegue este archivo en Supabase > SQL Editor > New query > Run.
--  Se puede ejecutar más de una vez. No borra datos.
-- =====================================================================

-- Jugadores a cargo de cada acudiente
alter table public.miembros add column if not exists jugadores text[] not null default '{}';

-- El personal del club (todos los roles menos Acudiente) sigue viendo y editando todo
create or replace function public.es_miembro() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.miembros m where m.user_id = auth.uid() and m.activo and m.rol <> 'Acudiente');
$$;

create or replace function public.es_acudiente() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.miembros m where m.user_id = auth.uid() and m.activo and m.rol = 'Acudiente');
$$;

create or replace function public.mis_jugadores() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce((select m.jugadores from public.miembros m where m.user_id = auth.uid() and m.activo and m.rol = 'Acudiente'), '{}');
$$;

-- Qué registros puede leer un acudiente: solo los de sus hijos (la base de datos lo filtra, no el navegador)
create or replace function public.ve_acudiente(p_store text, p_id text, p_data jsonb, p_borrado boolean) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare j text[];
begin
  if not public.es_acudiente() then return false; end if;
  j := public.mis_jugadores();
  if p_borrado or p_data is null then
    return p_store in ('players','payments','attendance','tournaments','uniorders','tariffs');
  end if;
  return case p_store
    when 'settings' then true
    when 'tariffs' then true
    when 'players' then p_id = any(j)
    when 'payments' then (p_data->>'playerId') = any(j)
    when 'attendance' then coalesce(p_data->'present','[]'::jsonb) ?| j or coalesce(p_data->'absent','[]'::jsonb) ?| j
                        or coalesce(p_data->'justified','[]'::jsonb) ?| j or coalesce(p_data->'late','[]'::jsonb) ?| j
    when 'tournaments' then coalesce(p_data->'convocados','[]'::jsonb) ?| j
    when 'uniorders' then jsonb_typeof(p_data->'lines') = 'array'
                        and exists (select 1 from jsonb_array_elements(p_data->'lines') l where l->>'playerId' = any(j))
    when 'users' then lower(p_data->>'username') = public.mi_correo()
    else false
  end;
end $$;

drop policy if exists reg_leer_acudiente on public.registros;
create policy reg_leer_acudiente on public.registros for select to authenticated
  using (public.ve_acudiente(store, id, data, borrado));
-- El acudiente no tiene permiso de crear ni modificar: las políticas de escritura usan es_miembro()
