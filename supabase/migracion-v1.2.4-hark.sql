-- v1.2.4 (Hark) — cambios APLICADOS en Supabase el 2026-10-11.
-- Todos compatibles con la APK 1.2.2/1.2.3 (no cambian esquema de sync).

-- A1: borrar contraseñas en claro de ops ya aplicadas
update public.sync_ops set payload = payload - 'password',
  resultado = case when jsonb_typeof(resultado)='object' and resultado ? 'resultado'
                    and jsonb_typeof(resultado->'resultado')='object'
                   then jsonb_set(resultado - 'password', '{resultado}', (resultado->'resultado') - 'password')
                   when jsonb_typeof(resultado)='object' then resultado - 'password' else resultado end
where tipo='admin_usuario' and aplicada and (payload ? 'password' or resultado::text ilike '%password%');

-- A2: tabla de respaldo cerrada (se conserva)
alter table public._rollback_bloque_c_20261011 enable row level security;
revoke all on public._rollback_bloque_c_20261011 from anon, authenticated;

-- A3: secuencia alineada y que siga a server_seq
select setval('public.sync_seq_global', greatest((select server_seq from public.sync_estado where id=1),
                                                  (select last_value from public.sync_seq_global)));
create or replace function public.sync_seq_seguir_server() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.server_seq is not null and new.server_seq > (select last_value from public.sync_seq_global) then
    perform setval('public.sync_seq_global', new.server_seq);
  end if;
  return new;
end $$;
revoke execute on function public.sync_seq_seguir_server() from public, anon, authenticated;
create trigger trg_sync_seq_seguir after update of server_seq on public.sync_estado
  for each row execute function public.sync_seq_seguir_server();

-- A4: el secreto del cron vive en Vault ('tg_cron_secret'); el job lo lee de vault.decrypted_secrets.

-- A6: solo el admin puede encolar ops de administración
drop policy "insertar ops" on public.sync_ops;
create policy "insertar ops" on public.sync_ops for insert to authenticated
  with check (user_id = (select auth.uid())
              and (tipo not in ('admin_usuario','ajuste','gasto') or (select public.es_admin())));

-- A10: UPDATE de fotos solo por quien la subió (o el admin)
-- (se añadió  owner_id = auth.uid()::text or es_admin()  a la política "update fotos")
