-- The financial responsible member is the only permanent authority.
-- Before one is selected, a high-entropy one-time setup key authorizes only
-- setup operations. ledger_groups.created_by remains audit metadata.

create table public.ledger_setup_tokens (
  group_id uuid primary key references public.ledger_groups(id) on delete cascade,
  token_hash bytea not null,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now(),
  check (expires_at > created_at)
);

alter table public.ledger_setup_tokens enable row level security;
revoke all on public.ledger_setup_tokens from public, anon, authenticated;

create function public.has_valid_ledger_setup_token(
  p_group_id uuid,
  p_setup_token text
)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce(
    p_setup_token ~ '^[0-9a-f]{32}$'
    and exists (
      select 1
      from public.ledger_setup_tokens s
      join public.ledger_groups g on g.id = s.group_id
      where s.group_id = p_group_id
        and g.responsible_member_id is null
        and s.token_hash = extensions.digest(p_setup_token, 'sha256')
        and s.used_at is null
        and s.expires_at > now()
    ),
    false
  );
$$;

create or replace function public.is_group_member(target_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.members
    where group_id = target_group_id and user_id = (select auth.uid())
  );
$$;

create or replace function public.is_group_owner(target_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.ledger_groups g
    join public.members m
      on m.group_id = g.id and m.id = g.responsible_member_id
    where g.id = target_group_id
      and m.user_id = (select auth.uid())
      and m.role = 'owner'
  );
$$;

create or replace function public.bootstrap_ledger_group(
  p_group_name text,
  p_participants jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  current_user_id uuid := (select auth.uid());
  new_group public.ledger_groups;
  raw_setup_token text := encode(extensions.gen_random_bytes(16), 'hex');
  setup_expires_at timestamptz := now() + interval '30 days';
  participant jsonb;
  new_member public.members;
  member_rows jsonb := '[]'::jsonb;
  participant_index integer := 0;
  participant_name text;
  participant_color text;
begin
  if current_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if char_length(trim(p_group_name)) not between 1 and 80 then
    raise exception 'invalid group name' using errcode = '22023';
  end if;
  if jsonb_typeof(p_participants) <> 'array'
    or jsonb_array_length(p_participants) not between 0 and 50 then
    raise exception 'participants must contain 0 to 50 entries' using errcode = '22023';
  end if;

  insert into public.ledger_groups (name, created_by)
  values (trim(p_group_name), current_user_id)
  returning * into new_group;

  insert into public.ledger_setup_tokens (group_id, token_hash, expires_at)
  values (new_group.id, extensions.digest(raw_setup_token, 'sha256'), setup_expires_at);

  for participant in select value from jsonb_array_elements(p_participants)
  loop
    participant_name := trim(participant->>'name');
    participant_color := coalesce(nullif(participant->>'color', ''), '#64748b');

    if char_length(participant_name) not between 1 and 80 then
      raise exception 'invalid participant name at index %', participant_index using errcode = '22023';
    end if;
    if participant_color !~ '^#[0-9A-Fa-f]{6}$' then
      raise exception 'invalid participant color at index %', participant_index using errcode = '22023';
    end if;

    insert into public.members (group_id, role, display_name, color)
    values (new_group.id, 'member', participant_name, participant_color)
    returning * into new_member;

    member_rows := member_rows || jsonb_build_array(jsonb_build_object(
      'clientId', participant->>'clientId',
      'id', new_member.id,
      'name', new_member.display_name,
      'color', new_member.color,
      'createdAt', new_member.created_at,
      'linked', false
    ));
    participant_index := participant_index + 1;
  end loop;

  return jsonb_build_object(
    'groupId', new_group.id,
    'groupName', new_group.name,
    'members', member_rows,
    'setupToken', raw_setup_token,
    'setupExpiresAt', setup_expires_at
  );
end;
$$;

drop function public.create_group_invite(uuid, integer, integer);

create function public.create_group_invite(
  p_group_id uuid,
  p_valid_hours integer default 168,
  p_max_uses integer default 50,
  p_setup_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  current_user_id uuid := (select auth.uid());
  raw_token text := encode(extensions.gen_random_bytes(32), 'hex');
  invite public.group_invites;
begin
  if current_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not public.is_group_owner(p_group_id)
    and not public.has_valid_ledger_setup_token(p_group_id, p_setup_token) then
    raise exception 'responsible member or valid setup key required' using errcode = '42501';
  end if;
  if p_valid_hours not between 1 and 720 or p_max_uses not between 1 and 500 then
    raise exception 'invalid invite limits' using errcode = '22023';
  end if;

  insert into public.group_invites (
    group_id, token_hash, expires_at, max_uses, created_by
  ) values (
    p_group_id,
    extensions.digest(raw_token, 'sha256'),
    now() + make_interval(hours => p_valid_hours),
    p_max_uses,
    current_user_id
  ) returning * into invite;

  return jsonb_build_object(
    'token', raw_token,
    'expiresAt', invite.expires_at,
    'maxUses', invite.max_uses
  );
end;
$$;

create function public.get_group_members(
  p_group_id uuid,
  p_setup_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not public.is_group_member(p_group_id)
    and not public.has_valid_ledger_setup_token(p_group_id, p_setup_token) then
    raise exception 'ledger access denied' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id,
      'name', m.display_name,
      'color', m.color,
      'avatarUrl', m.avatar_url,
      'createdAt', m.created_at,
      'isResponsible', m.id = g.responsible_member_id
    ) order by m.created_at, m.id)
    from public.members m
    join public.ledger_groups g on g.id = m.group_id
    where m.group_id = p_group_id
  ), '[]'::jsonb);
end;
$$;

drop function public.get_ledger_access(uuid);

create function public.get_ledger_access(
  p_group_id uuid,
  p_setup_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  group_record public.ledger_groups;
  can_setup boolean;
begin
  if current_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select * into group_record from public.ledger_groups where id = p_group_id;
  if not found then
    raise exception 'ledger access denied' using errcode = '42501';
  end if;
  can_setup := public.has_valid_ledger_setup_token(p_group_id, p_setup_token);
  if not (public.is_group_member(p_group_id) or can_setup) then
    raise exception 'ledger access denied' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'groupId', group_record.id,
    'groupName', group_record.name,
    'isOwner', public.is_group_owner(p_group_id),
    'canSetup', can_setup,
    'hasResponsibleMember', group_record.responsible_member_id is not null,
    'responsibleMemberId', group_record.responsible_member_id,
    'setupExpiresAt', case when can_setup then (
      select expires_at from public.ledger_setup_tokens where group_id = p_group_id
    ) end,
    'memberCount', (select count(*) from public.members where group_id = p_group_id),
    'expenseCount', (select count(*) from public.expenses where group_id = p_group_id)
  );
end;
$$;

drop function public.assign_group_responsible_member(uuid, uuid);

create function public.assign_group_responsible_member(
  p_group_id uuid,
  p_member_id uuid,
  p_setup_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  group_record public.ledger_groups;
  setup_record public.ledger_setup_tokens;
  target_member public.members;
  initial_assignment boolean;
begin
  if (select auth.uid()) is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select * into group_record
  from public.ledger_groups
  where id = p_group_id
  for update;
  if not found then
    raise exception 'ledger is unavailable' using errcode = '22023';
  end if;

  initial_assignment := group_record.responsible_member_id is null;
  if initial_assignment then
    select * into setup_record
    from public.ledger_setup_tokens
    where group_id = p_group_id
    for update;
    if not found
      or p_setup_token is null
      or p_setup_token !~ '^[0-9a-f]{32}$'
      or setup_record.token_hash is distinct from extensions.digest(p_setup_token, 'sha256')
      or setup_record.used_at is not null
      or setup_record.expires_at <= now() then
      raise exception 'valid setup key required' using errcode = '42501';
    end if;
  elsif not public.is_group_owner(p_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;

  select * into target_member
  from public.members
  where group_id = p_group_id and id = p_member_id
  for update;
  if not found or target_member.user_id is null or target_member.line_user_id is null then
    raise exception 'responsible member must have a verified LINE identity' using errcode = '22023';
  end if;

  update public.members set role = 'member' where group_id = p_group_id and role = 'owner';
  update public.members set role = 'owner' where group_id = p_group_id and id = p_member_id;
  update public.ledger_groups set responsible_member_id = p_member_id where id = p_group_id;
  if initial_assignment then
    update public.ledger_setup_tokens set used_at = now() where group_id = p_group_id;
  end if;

  return jsonb_build_object(
    'memberId', target_member.id,
    'name', target_member.display_name,
    'setupKeyConsumed', initial_assignment
  );
end;
$$;

drop function public.delete_ledger_group(uuid, text);

create function public.delete_ledger_group(
  p_group_id uuid,
  p_confirmation text,
  p_setup_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  current_user_id uuid := (select auth.uid());
  group_record public.ledger_groups;
  deleted_member_count integer;
  deleted_expense_count integer;
  receipt_id uuid;
begin
  select * into group_record from public.ledger_groups where id = p_group_id for update;
  if not found or current_user_id is null then
    raise exception 'ledger is unavailable' using errcode = '42501';
  end if;
  if group_record.responsible_member_id is null then
    if not public.has_valid_ledger_setup_token(p_group_id, p_setup_token) then
      raise exception 'valid setup key required' using errcode = '42501';
    end if;
  elsif not public.is_group_owner(p_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;
  if p_confirmation is distinct from group_record.name then
    raise exception 'ledger name confirmation does not match' using errcode = '22023';
  end if;

  select count(*) into deleted_member_count from public.members where group_id = p_group_id;
  select count(*) into deleted_expense_count from public.expenses where group_id = p_group_id;

  insert into public.ledger_deletion_receipts (
    deleted_group_id, group_name_hash, deleted_by, member_count, expense_count
  ) values (
    p_group_id,
    extensions.digest(group_record.name, 'sha256'),
    current_user_id,
    deleted_member_count,
    deleted_expense_count
  ) returning id into receipt_id;

  delete from public.line_expense_drafts where group_id = p_group_id;
  delete from public.line_group_bindings where group_id = p_group_id;
  delete from public.line_bind_codes where group_id = p_group_id;
  delete from public.settlement_confirmation_events where group_id = p_group_id;
  delete from public.expense_shares where group_id = p_group_id;
  delete from public.expenses where group_id = p_group_id;
  delete from public.group_invites where group_id = p_group_id;
  delete from public.members where group_id = p_group_id;
  delete from public.audit_events where group_id = p_group_id;
  delete from public.ledger_groups where id = p_group_id;

  return jsonb_build_object(
    'receiptId', receipt_id,
    'deletedGroupId', p_group_id,
    'memberCount', deleted_member_count,
    'expenseCount', deleted_expense_count,
    'deletedAt', now()
  );
end;
$$;

drop policy groups_select_members on public.ledger_groups;
create policy groups_select_members on public.ledger_groups for select to authenticated
using (public.is_group_member(id));

revoke all on function public.has_valid_ledger_setup_token(uuid, text) from public, anon, authenticated;
revoke all on function public.create_group_invite(uuid, integer, integer, text) from public, anon;
revoke all on function public.get_group_members(uuid, text) from public, anon;
revoke all on function public.get_ledger_access(uuid, text) from public, anon;
revoke all on function public.assign_group_responsible_member(uuid, uuid, text) from public, anon;
revoke all on function public.delete_ledger_group(uuid, text, text) from public, anon;

grant execute on function public.bootstrap_ledger_group(text, jsonb) to authenticated;
grant execute on function public.create_group_invite(uuid, integer, integer, text) to authenticated;
grant execute on function public.get_group_members(uuid, text) to authenticated;
grant execute on function public.get_ledger_access(uuid, text) to authenticated;
grant execute on function public.assign_group_responsible_member(uuid, uuid, text) to authenticated;
grant execute on function public.delete_ledger_group(uuid, text, text) to authenticated;
