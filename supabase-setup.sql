-- =====================================================================
--  Lector de cartillas · Configuración de Supabase
--  Pega TODO este script en Supabase › SQL Editor › New query y presiona Run.
--  Se puede ejecutar más de una vez sin problema.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- Tablas ----------
create table if not exists public.perfiles (
  id uuid primary key references auth.users(id) on delete cascade,
  usuario text unique not null,
  nombre text not null default '',
  rol text not null default 'tutor' check (rol in ('admin', 'tutor')),
  activo boolean not null default true,
  debe_cambiar boolean not null default false,
  creado timestamptz not null default now()
);

-- Evaluaciones, simulacros UNI y hojas calificadas (cada fila guarda un objeto del programa)
create table if not exists public.docs (
  id text primary key,
  kind text not null check (kind in ('exam', 'res', 'grp')),
  data jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);
create index if not exists docs_kind_idx on public.docs (kind);

-- Exámenes virtuales (lo que ve el alumno: sin la clave)
create table if not exists public.quizzes (
  id uuid primary key default gen_random_uuid(),
  exam_id text not null,
  titulo text not null,
  minutos int not null default 60 check (minutos between 1 and 600),
  n_preguntas int not null default 0,
  pdf_url text,
  activo boolean not null default true,
  mostrar_nota boolean not null default true,
  creado_por uuid default auth.uid(),
  creado timestamptz not null default now()
);
create index if not exists quizzes_exam_idx on public.quizzes (exam_id);

-- Intentos de los alumnos (un intento por DNI en cada examen virtual)
create table if not exists public.intentos (
  id uuid primary key default gen_random_uuid(),
  quiz_id uuid not null references public.quizzes(id) on delete cascade,
  dni text not null,
  nombre text not null,
  token uuid not null default gen_random_uuid(),
  inicio timestamptz not null default now(),
  fin_limite timestamptz not null,
  respuestas jsonb not null default '[]'::jsonb,
  enviado boolean not null default false,
  enviado_at timestamptz,
  resultado jsonb,
  unique (quiz_id, dni)
);

-- ---------- Funciones de permisos ----------
create or replace function public.es_activo() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfiles where id = auth.uid() and activo);
$$;

create or replace function public.es_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfiles where id = auth.uid() and activo and rol = 'admin');
$$;

-- ---------- Seguridad por filas (RLS) ----------
alter table public.perfiles enable row level security;
alter table public.docs enable row level security;
alter table public.quizzes enable row level security;
alter table public.intentos enable row level security;

drop policy if exists perfiles_leer on public.perfiles;
create policy perfiles_leer on public.perfiles for select to authenticated using (true);
drop policy if exists perfiles_admin on public.perfiles;
create policy perfiles_admin on public.perfiles for all to authenticated using (public.es_admin()) with check (public.es_admin());

drop policy if exists docs_leer on public.docs;
create policy docs_leer on public.docs for select to authenticated using (public.es_activo());
drop policy if exists docs_insertar on public.docs;
create policy docs_insertar on public.docs for insert to authenticated with check (public.es_activo());
drop policy if exists docs_editar on public.docs;
create policy docs_editar on public.docs for update to authenticated using (public.es_activo()) with check (public.es_activo());
drop policy if exists docs_borrar on public.docs;
create policy docs_borrar on public.docs for delete to authenticated using (public.es_activo() and (kind = 'res' or public.es_admin()));

drop policy if exists quizzes_publico on public.quizzes;
create policy quizzes_publico on public.quizzes for select to anon using (activo);
drop policy if exists quizzes_leer on public.quizzes;
create policy quizzes_leer on public.quizzes for select to authenticated using (true);
drop policy if exists quizzes_gestion on public.quizzes;
create policy quizzes_gestion on public.quizzes for all to authenticated using (public.es_activo()) with check (public.es_activo());

drop policy if exists intentos_leer on public.intentos;
create policy intentos_leer on public.intentos for select to authenticated using (public.es_activo());
drop policy if exists intentos_borrar on public.intentos;
create policy intentos_borrar on public.intentos for delete to authenticated using (public.es_activo());

-- ---------- Calificación (misma regla que el programa) ----------
create or replace function public.calificar(p_exam jsonb, p_resp jsonb) returns jsonb
language plpgsql immutable set search_path = public as $$
declare
  nq int := coalesce((p_exam->>'nQ')::int, 0);
  i int; k text; a text; sec jsonb; s jsonb; ov text;
  pts numeric; sc numeric := 0; mx numeric := 0;
  c int := 0; w int := 0; b int := 0;
begin
  for i in 1..nq loop
    k := coalesce(p_exam->'key'->>(i - 1), '');
    if k = '' then continue; end if;
    a := coalesce(p_resp->>(i - 1), '');
    sec := null;
    for s in select value from jsonb_array_elements(coalesce(p_exam->'sections', '[]'::jsonb)) loop
      if i >= (s->>'from')::numeric and i <= (s->>'to')::numeric then sec := s; exit; end if;
    end loop;
    ov := p_exam->'ptsOv'->>((i - 1)::text);
    if ov is not null and ov <> '' then pts := ov::numeric;
    elsif sec is not null then pts := coalesce((sec->>'pts')::numeric, 1);
    else pts := 1; end if;
    mx := mx + pts;
    if k = '*' then sc := sc + pts; c := c + 1;
    elsif a = '' then sc := sc + coalesce((sec->>'blank')::numeric, 0); b := b + 1;
    elsif length(a) > 1 or a <> k then sc := sc + coalesce((sec->>'wrong')::numeric, 0); w := w + 1;
    else sc := sc + pts; c := c + 1; end if;
  end loop;
  return jsonb_build_object('puntaje', sc, 'maximo', mx, 'correctas', c, 'incorrectas', w, 'blanco', b,
    'nota', case when mx > 0 then round(greatest(sc, 0) / mx * 20, 2) else 0 end);
end $$;

-- ---------- Examen virtual: funciones que usa el alumno ----------
create or replace function public.iniciar_intento(p_quiz uuid, p_dni text, p_nombre text, p_token uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare q public.quizzes; t public.intentos;
begin
  select * into q from public.quizzes where id = p_quiz;
  if not found or not q.activo then return jsonb_build_object('error', 'no_disponible'); end if;
  p_dni := regexp_replace(coalesce(p_dni, ''), '\s', '', 'g');
  if p_dni !~ '^[0-9]{6,12}$' then return jsonb_build_object('error', 'dni'); end if;
  if length(trim(coalesce(p_nombre, ''))) < 2 then return jsonb_build_object('error', 'nombre'); end if;
  select * into t from public.intentos where quiz_id = p_quiz and dni = p_dni;
  if found then
    if t.enviado then return jsonb_build_object('error', 'ya_enviado'); end if;
    if p_token is null or p_token <> t.token then return jsonb_build_object('error', 'en_curso'); end if;
  else
    insert into public.intentos (quiz_id, dni, nombre, fin_limite)
      values (p_quiz, p_dni, trim(p_nombre), now() + make_interval(mins => q.minutos))
      returning * into t;
  end if;
  return jsonb_build_object('id', t.id, 'token', t.token, 'fin', t.fin_limite, 'ahora', now(),
    'respuestas', t.respuestas, 'titulo', q.titulo, 'n', q.n_preguntas, 'nombre', t.nombre, 'dni', t.dni);
end $$;

create or replace function public._cerrar_intento(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t public.intentos; q public.quizzes; ex jsonb; r jsonb; rid text;
begin
  select * into t from public.intentos where id = p_id for update;
  if not found then return jsonb_build_object('error', 'no_encontrado'); end if;
  select * into q from public.quizzes where id = t.quiz_id;
  if t.enviado then
    return jsonb_build_object('ok', true, 'resultado', case when q.mostrar_nota then t.resultado else null end);
  end if;
  select data into ex from public.docs where id = 'exam_' || q.exam_id;
  r := public.calificar(coalesce(ex, '{}'::jsonb), t.respuestas);
  rid := 'v' || replace(t.id::text, '-', '');
  insert into public.docs (id, kind, data, updated_at) values ('res_' || rid, 'res', jsonb_build_object(
      'id', rid, 'examId', q.exam_id, 'studentId', t.dni, 'name', t.nombre, 'answers', t.respuestas,
      'doubts', '[]'::jsonb, 'img', null, 'created', floor(extract(epoch from now()) * 1000),
      'source', 'virtual', 'quizId', q.id::text, 'quizTitle', q.titulo,
      'minutos', round((extract(epoch from (least(now(), t.fin_limite) - t.inicio)) / 60.0)::numeric, 1)), now())
    on conflict (id) do update set data = excluded.data, updated_at = now();
  update public.intentos set enviado = true, enviado_at = now(), resultado = r where id = p_id;
  return jsonb_build_object('ok', true, 'resultado', case when q.mostrar_nota then r else null end);
end $$;
revoke execute on function public._cerrar_intento(uuid) from public, anon, authenticated;

create or replace function public.guardar_respuestas(p_id uuid, p_token uuid, p_resp jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.intentos;
begin
  select * into t from public.intentos where id = p_id and token = p_token;
  if not found then return jsonb_build_object('error', 'no_encontrado'); end if;
  if t.enviado then return jsonb_build_object('error', 'ya_enviado'); end if;
  if now() > t.fin_limite + interval '30 seconds' then
    return public._cerrar_intento(t.id) || jsonb_build_object('cerrado', true);
  end if;
  update public.intentos set respuestas = coalesce(p_resp, '[]'::jsonb) where id = p_id;
  return jsonb_build_object('ok', true, 'ahora', now(), 'fin', t.fin_limite);
end $$;

create or replace function public.enviar_intento(p_id uuid, p_token uuid, p_resp jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.intentos;
begin
  select * into t from public.intentos where id = p_id and token = p_token;
  if not found then return jsonb_build_object('error', 'no_encontrado'); end if;
  if not t.enviado and p_resp is not null and now() <= t.fin_limite + interval '2 minutes' then
    update public.intentos set respuestas = p_resp where id = p_id;
  end if;
  return public._cerrar_intento(p_id);
end $$;

-- Para tutores: califica los intentos cuyo tiempo ya terminó (alumnos que cerraron la página)
create or replace function public.cerrar_vencidos(p_quiz uuid) returns int
language plpgsql security definer set search_path = public as $$
declare t record; n int := 0;
begin
  if not public.es_activo() then raise exception 'sin permiso'; end if;
  for t in select id from public.intentos where quiz_id = p_quiz and not enviado and now() > fin_limite + interval '30 seconds' loop
    perform public._cerrar_intento(t.id); n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- Usuarios ----------
create or replace function public.hay_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfiles where rol = 'admin');
$$;

create or replace function public.registrar_primer_admin(p_usuario text, p_nombre text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return jsonb_build_object('error', 'sin_sesion'); end if;
  if exists (select 1 from public.perfiles where rol = 'admin') then return jsonb_build_object('error', 'ya_existe'); end if;
  insert into public.perfiles (id, usuario, nombre, rol) values (auth.uid(), lower(trim(p_usuario)), trim(p_nombre), 'admin');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.marcar_clave_cambiada() returns void
language sql security definer set search_path = public as $$
  update public.perfiles set debe_cambiar = false where id = auth.uid();
$$;

create or replace function public.admin_cambiar_clave(p_user uuid, p_clave text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.es_admin() then return jsonb_build_object('error', 'sin_permiso'); end if;
  if length(coalesce(p_clave, '')) < 8 then return jsonb_build_object('error', 'clave_corta'); end if;
  update auth.users set encrypted_password = extensions.crypt(p_clave, extensions.gen_salt('bf')), updated_at = now() where id = p_user;
  update public.perfiles set debe_cambiar = true where id = p_user;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_eliminar_usuario(p_user uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.es_admin() then return jsonb_build_object('error', 'sin_permiso'); end if;
  if p_user = auth.uid() then return jsonb_build_object('error', 'propio'); end if;
  delete from auth.users where id = p_user;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Tiempo real ----------
do $$ begin
  begin alter publication supabase_realtime add table public.docs; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.quizzes; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.intentos; exception when duplicate_object then null; end;
end $$;

-- ---------- Archivos PDF de los exámenes virtuales ----------
insert into storage.buckets (id, name, public) values ('examenes', 'examenes', true) on conflict (id) do nothing;
drop policy if exists "examenes_subir" on storage.objects;
create policy "examenes_subir" on storage.objects for insert to authenticated with check (bucket_id = 'examenes' and public.es_activo());
drop policy if exists "examenes_editar" on storage.objects;
create policy "examenes_editar" on storage.objects for update to authenticated using (bucket_id = 'examenes' and public.es_activo());
drop policy if exists "examenes_borrar" on storage.objects;
create policy "examenes_borrar" on storage.objects for delete to authenticated using (bucket_id = 'examenes' and public.es_activo());

-- Listo. Vuelve al programa y crea la cuenta de administrador.
