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
create policy "usuarios leen su perfil"
  on sync_usuarios_perfil for select
  to authenticated
  using (username = (auth.jwt() ->> 'email'));

create policy "usuarios actualizan su perfil"
  on sync_usuarios_perfil for insert
  to authenticated
  with check (username = (auth.jwt() ->> 'email'));

create policy "usuarios modifican su perfil"
  on sync_usuarios_perfil for update
  to authenticated
  using (username = (auth.jwt() ->> 'email'))
  with check (username = (auth.jwt() ->> 'email'));

-- El dueño puede leer todos (para administración)
-- Nota: ajustar según cómo se identifique al dueño en tu sistema
