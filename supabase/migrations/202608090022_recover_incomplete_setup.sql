-- Let the anonymous session that created an unfinished singleton ledger rotate
-- its lost setup key. This authority ends permanently once a responsible
-- member is assigned; it never grants access to another creator's ledger.

alter table public.ledger_setup_tokens
  add column if not exists recovery_count integer not null default 0
    check (recovery_count >= 0),
  add column if not exists last_recovered_at timestamptz;

create function public.recover_incomplete_ledger_setup()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  current_user_id uuid := (select auth.uid());
  group_record public.ledger_groups;
  setup_record public.ledger_setup_tokens;
  raw_setup_token text := encode(extensions.gen_random_bytes(16), 'hex');
  setup_expires_at timestamptz := now() + interval '30 days';
begin
  if current_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select * into group_record
  from public.ledger_groups
  where created_by = current_user_id
    and responsible_member_id is null
  for update;

  if not found then
    raise exception 'recoverable ledger is unavailable' using errcode = '42501';
  end if;

  select * into setup_record
  from public.ledger_setup_tokens
  where group_id = group_record.id
  for update;

  if not found or setup_record.used_at is not null then
    raise exception 'recoverable ledger is unavailable' using errcode = '42501';
  end if;

  update public.ledger_setup_tokens
  set token_hash = extensions.digest(raw_setup_token, 'sha256'),
      expires_at = setup_expires_at,
      used_at = null,
      recovery_count = recovery_count + 1,
      last_recovered_at = now()
  where group_id = group_record.id;

  return jsonb_build_object(
    'groupId', group_record.id,
    'groupName', group_record.name,
    'setupToken', raw_setup_token,
    'setupExpiresAt', setup_expires_at
  );
end;
$$;

revoke all on function public.recover_incomplete_ledger_setup() from public, anon;
grant execute on function public.recover_incomplete_ledger_setup() to authenticated;
