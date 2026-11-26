-- =====================================================================
--  Club Deportivo Olympic · Base de datos en la nube (Supabase)
--  Pegue todo este archivo en Supabase > SQL Editor > New query > Run.
--  Se puede ejecutar más de una vez sin dañar los datos.
-- =====================================================================

-- 1. Miembros: quién puede entrar al sistema (cuentas de Supabase Auth habilitadas por el administrador)
create table if not exists public.miembros (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  correo     text not null,
  rol        text not null default 'Consulta',
  activo     boolean not null default true,
  creado     timestamptz not null default now()
);

-- 2. Registros: todos los datos del aplicativo (jugadores, pagos, asistencia, torneos, etc.)
create table if not exists public.registros (
  store       text not null,
  id          text not null,
  data        jsonb,
  borrado     boolean not null default false,
  updated_at  timestamptz not null default now(),
  updated_by  uuid default auth.uid(),
  primary key (store, id)
);
create index if not exists registros_updated_idx on public.registros (updated_at);

-- 3. Funciones de apoyo (se ejecutan con permisos del sistema, no exponen datos)
create or replace function public.es_miembro() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.miembros m where m.user_id = auth.uid() and m.activo);
$$;

create or replace function public.es_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.miembros m where m.user_id = auth.uid() and m.activo and m.rol = 'Administrador');
$$;

create or replace function public.mi_correo() returns text
language sql stable security definer set search_path = public, auth as $$
  select lower(email) from auth.users where id = auth.uid();
$$;

-- El primer usuario que se registre queda como administrador (solo si todavía no hay miembros)
create or replace function public.crear_primer_admin() returns boolean
language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then return false; end if;
  if exists (select 1 from public.miembros) then return false; end if;
  insert into public.miembros (user_id, correo, rol) values (auth.uid(), public.mi_correo(), 'Administrador');
  return true;
end $$;

-- ¿Ya existe un administrador? (para mostrar la pantalla de primer ingreso)
create or replace function public.hay_miembros() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.miembros);
$$;

-- Fecha del servidor y usuario en cada cambio
create or replace function public.registros_marca() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := clock_timestamp();
  new.updated_by := auth.uid();
  -- El historial de cambios solo se agrega: nadie lo puede modificar ni borrar
  if new.store = 'audit' and tg_op = 'UPDATE' then
    raise exception 'El historial de cambios no se puede modificar';
  end if;
  -- Solo el administrador cambia rol, permisos o estado de los usuarios del sistema
  if new.store = 'users' and not public.es_admin() then
    if tg_op = 'INSERT' then
      -- un "upsert" sobre un usuario existente se revisa como actualización
      if not exists (select 1 from public.registros r where r.store = new.store and r.id = new.id) then
        raise exception 'Solo el administrador puede crear usuarios';
      end if;
      return new;
    end if;
    if (old.data->'role') is distinct from (new.data->'role')
       or (old.data->'perms') is distinct from (new.data->'perms')
       or (old.data->'active') is distinct from (new.data->'active')
       or (old.data->'coachId') is distinct from (new.data->'coachId')
       or (old.data->'groups') is distinct from (new.data->'groups')
       or (old.data->'username') is distinct from (new.data->'username')
       or new.borrado then
      raise exception 'Solo el administrador puede cambiar roles y permisos';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists registros_marca on public.registros;
create trigger registros_marca before insert or update on public.registros
  for each row execute function public.registros_marca();

-- 4. Seguridad por filas: sin sesión no se ve nada; solo miembros activos leen y escriben
alter table public.registros enable row level security;
alter table public.miembros  enable row level security;

drop policy if exists reg_leer on public.registros;
drop policy if exists reg_crear on public.registros;
drop policy if exists reg_editar on public.registros;
create policy reg_leer   on public.registros for select to authenticated using (public.es_miembro());
create policy reg_crear  on public.registros for insert to authenticated with check (public.es_miembro());
create policy reg_editar on public.registros for update to authenticated
  using (public.es_miembro())
  with check (public.es_miembro() and (store <> 'users' or public.es_admin() or lower(data->>'username') = public.mi_correo()));
-- No hay política de borrado: los registros se marcan como borrados (borrado = true)

drop policy if exists mie_leer on public.miembros;
drop policy if exists mie_crear on public.miembros;
drop policy if exists mie_editar on public.miembros;
create policy mie_leer   on public.miembros for select to authenticated using (user_id = auth.uid() or public.es_admin());
create policy mie_crear  on public.miembros for insert to authenticated with check (public.es_admin());
create policy mie_editar on public.miembros for update to authenticated using (public.es_admin()) with check (public.es_admin());

revoke all on public.registros, public.miembros from anon;
grant select, insert, update on public.registros to authenticated;
grant select, insert, update on public.miembros  to authenticated;
grant execute on function public.crear_primer_admin(), public.hay_miembros() to authenticated;
grant execute on function public.hay_miembros() to anon;
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
