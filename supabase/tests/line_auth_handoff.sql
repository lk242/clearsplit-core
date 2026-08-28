-- One-time LINE login handoff security, expiry, and replay test. All fixtures
-- are rolled back.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(1);

do $$
declare
  stable_user_id uuid := '00000000-0000-4000-8000-000000000101';
  other_user_id uuid := '00000000-0000-4000-8000-000000000102';
  expired_hash text := repeat('b', 64);
begin
  update auth.users
  set email = 'line-' || repeat('1', 64) || '@users.clearsplit.app',
      raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb)
        || '{"clearsplit_line_identity":true}'::jsonb
  where id = stable_user_id;

  update auth.users
  set email = 'line-' || repeat('2', 64) || '@users.clearsplit.app',
      raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb)
        || '{"clearsplit_line_identity":true}'::jsonb
  where id = other_user_id;

  if has_table_privilege('anon', 'public.line_auth_handoffs', 'select')
    or has_table_privilege('authenticated', 'public.line_auth_handoffs', 'select')
    or has_function_privilege('anon', 'public.store_line_auth_handoff(text,uuid)', 'execute')
    or has_function_privilege('authenticated', 'public.consume_line_auth_handoff(text)', 'execute') then
    raise exception 'handoff table or functions are exposed to browser roles';
  end if;

  insert into public.line_auth_handoffs (token_hash, auth_user_id, expires_at)
  values (expired_hash, stable_user_id, now() - interval '1 second');
end;
$$;

set local role service_role;

do $$
declare
  stable_user_id uuid := '00000000-0000-4000-8000-000000000101';
  other_user_id uuid := '00000000-0000-4000-8000-000000000102';
  first_hash text := repeat('a', 64);
  expired_hash text := repeat('b', 64);
  collision_hash text := repeat('c', 64);
  consumed_user_id uuid;
  rejected boolean;
begin
  perform public.store_line_auth_handoff(first_hash, stable_user_id);
  consumed_user_id := public.consume_line_auth_handoff(first_hash);
  if consumed_user_id is distinct from stable_user_id then
    raise exception 'valid handoff did not return the bound LINE account';
  end if;
  if public.consume_line_auth_handoff(first_hash) is not null then
    raise exception 'handoff token could be replayed';
  end if;

  if public.consume_line_auth_handoff(expired_hash) is not null then
    raise exception 'expired handoff token was accepted';
  end if;

  perform public.store_line_auth_handoff(collision_hash, stable_user_id);
  rejected := false;
  begin
    perform public.store_line_auth_handoff(collision_hash, other_user_id);
  exception when unique_violation then
    rejected := true;
  end;
  if not rejected then
    raise exception 'another LINE account replaced an existing handoff binding';
  end if;
end;
$$;

reset role;

select pass('LINE auth handoff is private, short-lived, single-use, and collision safe');
select * from finish();
rollback;
