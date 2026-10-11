-- Migración: tabla para persistencia del perfil de usuario APK
-- v1.2.2: foto, móvil y carnet sobreviven reinstalaciones

create table if not exists sync_usuarios_perfil (
  username text primary key,
  movil text,
  carnet text,
  foto_storage text,
  updated_at timestamptz not null default now(),
  device_id text
);

alter table sync_usuarios_perfil enable row level security;

-- Cada usuario solo lee/escribe su propia fila
-- NOTA v1.2.2: la app guarda solo el prefijo del email (ej: 'gabriel'),
-- por eso comparamos con split_part del email del JWT.
create policy "usuarios leen su perfil"
  on sync_usuarios_perfil for select
  to authenticated
  using (username = split_part(auth.jwt() ->> 'email', '@', 1));

create policy "usuarios actualizan su perfil"
  on sync_usuarios_perfil for insert
  to authenticated
  with check (username = split_part(auth.jwt() ->> 'email', '@', 1));

create policy "usuarios modifican su perfil"
  on sync_usuarios_perfil for update
  to authenticated
  using (username = split_part(auth.jwt() ->> 'email', '@', 1))
  with check (username = split_part(auth.jwt() ->> 'email', '@', 1));

-- El dueño puede leer todos (para administración)
-- Nota: ajustar según cómo se identifique al dueño en tu sistema
