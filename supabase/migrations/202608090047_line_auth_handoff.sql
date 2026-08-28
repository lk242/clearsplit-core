-- Safari and an iOS Home Screen web app intentionally use isolated website
-- storage. This short-lived, one-time handoff lets the installed app obtain a
-- fresh Supabase session after LINE Login finishes in Safari. Only a SHA-256
-- digest is stored; no LINE or Supabase token is written to this table or URL.

create table public.line_auth_handoffs (
  token_hash text primary key check (token_hash ~ '^[0-9a-f]{64}$'),
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index line_auth_handoffs_expires_at_idx
  on public.line_auth_handoffs (expires_at);

alter table public.line_auth_handoffs enable row level security;
revoke all on table public.line_auth_handoffs from public, anon, authenticated;

create function public.store_line_auth_handoff(
  p_token_hash text,
  p_auth_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$'
    or p_auth_user_id is null then
    raise exception 'invalid LINE auth handoff' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from auth.users auth_user
    where auth_user.id = p_auth_user_id
      and auth_user.raw_user_meta_data->>'clearsplit_line_identity' = 'true'
      and auth_user.email ~ '^line-[0-9a-f]{64}@users\.clearsplit\.app$'
  ) then
    raise exception 'unverified LINE auth handoff user' using errcode = '42501';
  end if;

  delete from public.line_auth_handoffs handoff
  where handoff.expires_at <= now();

  insert into public.line_auth_handoffs (token_hash, auth_user_id, expires_at)
  values (p_token_hash, p_auth_user_id, now() + interval '10 minutes')
  on conflict (token_hash) do update
    set expires_at = excluded.expires_at
    where line_auth_handoffs.auth_user_id = excluded.auth_user_id;

  if not found then
    raise exception 'LINE auth handoff token is already bound' using errcode = '23505';
  end if;
end;
$$;

create function public.consume_line_auth_handoff(p_token_hash text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  consumed_user_id uuid;
begin
  if p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid LINE auth handoff' using errcode = '22023';
  end if;

  delete from public.line_auth_handoffs handoff
  where handoff.token_hash = p_token_hash
    and handoff.expires_at > now()
  returning handoff.auth_user_id into consumed_user_id;

  return consumed_user_id;
end;
$$;

revoke all on function public.store_line_auth_handoff(text, uuid) from public, anon, authenticated;
revoke all on function public.consume_line_auth_handoff(text) from public, anon, authenticated;
grant execute on function public.store_line_auth_handoff(text, uuid) to service_role;
grant execute on function public.consume_line_auth_handoff(text) to service_role;

insert into public.app_schema_versions (version, name)
values (47, 'one-time LINE login handoff for isolated iOS Home Screen storage');
