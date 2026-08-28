-- Multi-ledger account boundaries.
-- A verified LINE identity may own at most 5 active / 10 total ledgers and
-- join at most 30 active ledgers. Creator is immutable audit metadata;
-- financial authority belongs only to the current responsible member.

insert into public.app_schema_versions (version, name)
values (44, 'multi-ledger LINE accounts, quotas, and archived read-only state');

drop index if exists public.ledger_groups_single_active_idx;

alter table public.ledger_groups
  add column status text not null default 'active'
    check (status in ('active', 'archived')),
  add column archived_at timestamptz,
  add constraint ledger_groups_archive_state_check check (
    (status = 'active' and archived_at is null)
    or (status = 'archived' and archived_at is not null)
  );

create index ledger_groups_status_idx
  on public.ledger_groups(status, updated_at desc);

create table public.ledger_lifecycle_events (
  id bigint generated always as identity primary key,
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  actor_user_id uuid not null references auth.users(id),
  action text not null check (action in ('archive', 'restore')),
  created_at timestamptz not null default now()
);

create index ledger_lifecycle_events_group_time_idx
  on public.ledger_lifecycle_events(group_id, created_at desc);
alter table public.ledger_lifecycle_events enable row level security;
revoke all on public.ledger_lifecycle_events from public, anon, authenticated;
grant select on public.ledger_lifecycle_events to authenticated;
create policy ledger_lifecycle_events_select_members
  on public.ledger_lifecycle_events for select to authenticated
  using (public.is_group_member(group_id));

create table public.line_identities (
  user_id uuid primary key references auth.users(id) on delete cascade,
  line_user_id text not null unique check (line_user_id ~ '^U[0-9a-f]{32}$'),
  display_name text not null check (char_length(trim(display_name)) between 1 and 80),
  avatar_url text check (
    avatar_url is null
    or (char_length(avatar_url) <= 2048 and avatar_url ~ '^https://')
  ),
  verified_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.line_identities enable row level security;
revoke all on public.line_identities from public, anon, authenticated;

create trigger line_identities_set_updated_at
before update on public.line_identities
for each row execute function public.set_updated_at();

-- The former singleton can have at most one linked row per LINE identity.
insert into public.line_identities (user_id, line_user_id, display_name, avatar_url)
select m.user_id, m.line_user_id, m.display_name, m.avatar_url
from public.members m
where m.user_id is not null and m.line_user_id is not null
on conflict (line_user_id) do update set
  display_name = excluded.display_name,
  avatar_url = excluded.avatar_url,
  updated_at = now();

create function public.ledger_owner_user_id(p_group_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(owner_member.user_id, g.created_by)
  from public.ledger_groups g
  left join public.members owner_member
    on owner_member.id = g.responsible_member_id
   and owner_member.group_id = g.id
  where g.id = p_group_id;
$$;

revoke all on function public.ledger_owner_user_id(uuid)
  from public, anon, authenticated;

create function public.active_owned_ledger_count(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
  from public.ledger_groups g
  where g.status = 'active'
    and public.ledger_owner_user_id(g.id) = p_user_id;
$$;

create function public.total_owned_ledger_count(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
  from public.ledger_groups g
  where public.ledger_owner_user_id(g.id) = p_user_id;
$$;

create function public.active_joined_ledger_count(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
  from public.members m
  join public.ledger_groups g on g.id = m.group_id
  where m.user_id = p_user_id
    and g.status = 'active'
    and m.id is distinct from g.responsible_member_id;
$$;

revoke all on function public.active_owned_ledger_count(uuid)
  from public, anon, authenticated;
revoke all on function public.total_owned_ledger_count(uuid)
  from public, anon, authenticated;
revoke all on function public.active_joined_ledger_count(uuid)
  from public, anon, authenticated;

-- Only the LINE-verifying Edge Function may establish this mapping. The
-- returned user ID is authoritative when a browser currently has an anonymous
-- session but the LINE identity already belongs to a stable Auth user.
create function public.record_verified_line_identity(
  p_auth_user_id uuid,
  p_line_user_id text,
  p_display_name text,
  p_avatar_url text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  existing_identity public.line_identities;
  requested_identity public.line_identities;
  stable_user_id uuid;
begin
  if not exists (select 1 from auth.users where id = p_auth_user_id) then
    raise exception 'authenticated user is unavailable' using errcode = '42501';
  end if;
  if p_line_user_id !~ '^U[0-9a-f]{32}$'
    or char_length(trim(p_display_name)) not between 1 and 80 then
    raise exception 'invalid LINE identity' using errcode = '22023';
  end if;
  if p_avatar_url is not null
    and (char_length(p_avatar_url) > 2048 or p_avatar_url !~ '^https://') then
    raise exception 'invalid LINE avatar URL' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('clearsplit-line:' || p_line_user_id, 0));

  select * into existing_identity
  from public.line_identities
  where line_user_id = p_line_user_id
  for update;

  select * into requested_identity
  from public.line_identities
  where user_id = p_auth_user_id
  for update;

  if requested_identity.user_id is not null
    and requested_identity.line_user_id <> p_line_user_id then
    raise exception 'app session is linked to another LINE identity' using errcode = '23505';
  end if;

  stable_user_id := coalesce(existing_identity.user_id, p_auth_user_id);

  insert into public.line_identities (
    user_id, line_user_id, display_name, avatar_url, verified_at
  ) values (
    stable_user_id, p_line_user_id, trim(p_display_name), p_avatar_url, now()
  )
  on conflict (line_user_id) do update set
    display_name = excluded.display_name,
    avatar_url = excluded.avatar_url,
    verified_at = now(),
    updated_at = now();

  insert into public.profiles (user_id, display_name, avatar_url)
  values (stable_user_id, trim(p_display_name), p_avatar_url)
  on conflict (user_id) do update set
    display_name = excluded.display_name,
    avatar_url = excluded.avatar_url,
    updated_at = now();

  -- Archived ledgers are already linked by the migration and remain read-only.
  update public.members m set
    user_id = stable_user_id,
    display_name = trim(p_display_name),
    avatar_url = p_avatar_url
  from public.ledger_groups g
  where m.group_id = g.id
    and g.status = 'active'
    and m.line_user_id = p_line_user_id
    and (m.user_id, m.display_name, m.avatar_url) is distinct from
      (stable_user_id, trim(p_display_name), p_avatar_url);

  return jsonb_build_object('userId', stable_user_id);
end;
$$;

revoke all on function public.record_verified_line_identity(uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function public.record_verified_line_identity(uuid, text, text, text)
  to service_role;

create function public.list_my_ledgers()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
begin
  if current_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'limits', jsonb_build_object(
      'activeOwned', 5,
      'totalOwned', 10,
      'activeJoined', 30,
      'membersPerLedger', 50
    ),
    'usage', jsonb_build_object(
      'activeOwned', public.active_owned_ledger_count(current_user_id),
      'totalOwned', public.total_owned_ledger_count(current_user_id),
      'activeJoined', public.active_joined_ledger_count(current_user_id)
    ),
    'ledgers', coalesce((
      select jsonb_agg(jsonb_build_object(
          'groupId', access.id,
          'groupName', access.name,
          'status', access.status,
          'archivedAt', access.archived_at,
          'createdAt', access.created_at,
          'updatedAt', access.updated_at,
          'isCreator', access.created_by = current_user_id,
          'isOwner', access.owner_user_id = current_user_id,
          'memberId', access.member_id,
          'memberCount', access.member_count,
          'expenseCount', access.expense_count
        ) order by
          case when access.status = 'active' then 0 else 1 end,
          access.updated_at desc,
          access.id)
      from (
        select g.*,
          public.ledger_owner_user_id(g.id) as owner_user_id,
          mine.id as member_id,
          (select count(*) from public.members m where m.group_id = g.id) as member_count,
          (select count(*) from public.expenses e where e.group_id = g.id) as expense_count
        from public.ledger_groups g
        left join public.members mine
          on mine.group_id = g.id and mine.user_id = current_user_id
        where mine.id is not null
           or (g.responsible_member_id is null and g.created_by = current_user_id)
      ) access
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.list_my_ledgers() from public, anon;
grant execute on function public.list_my_ledgers() to authenticated;

create or replace function public.bootstrap_ledger_group(
  p_group_name text,
  p_participants jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  identity_record public.line_identities;
  new_group public.ledger_groups;
  owner_member public.members;
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
  select * into identity_record
  from public.line_identities
  where user_id = current_user_id;
  if not found then
    raise exception 'verified LINE account required' using errcode = '42501';
  end if;
  if char_length(trim(p_group_name)) not between 1 and 80 then
    raise exception 'invalid group name' using errcode = '22023';
  end if;
  if jsonb_typeof(p_participants) <> 'array'
    or jsonb_array_length(p_participants) not between 0 and 49 then
    raise exception 'participants must contain 0 to 49 entries' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('clearsplit-owned:' || current_user_id::text, 0));
  if public.active_owned_ledger_count(current_user_id) >= 5 then
    raise exception 'active owned ledger limit reached' using errcode = 'P0001';
  end if;
  if public.total_owned_ledger_count(current_user_id) >= 10 then
    raise exception 'total owned ledger limit reached' using errcode = 'P0001';
  end if;

  insert into public.ledger_groups (name, created_by)
  values (trim(p_group_name), current_user_id)
  returning * into new_group;

  insert into public.members (
    group_id, user_id, role, display_name, avatar_url, color, line_user_id
  ) values (
    new_group.id, current_user_id, 'owner', identity_record.display_name,
    identity_record.avatar_url, '#4f7c68', identity_record.line_user_id
  ) returning * into owner_member;

  update public.ledger_groups
  set responsible_member_id = owner_member.id
  where id = new_group.id;

  member_rows := jsonb_build_array(jsonb_build_object(
    'id', owner_member.id,
    'name', owner_member.display_name,
    'color', owner_member.color,
    'avatarUrl', owner_member.avatar_url,
    'createdAt', owner_member.created_at,
    'linked', true,
    'isResponsible', true
  ));

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
      'avatarUrl', new_member.avatar_url,
      'createdAt', new_member.created_at,
      'linked', false,
      'isResponsible', false
    ));
    participant_index := participant_index + 1;
  end loop;

  return jsonb_build_object(
    'groupId', new_group.id,
    'groupName', new_group.name,
    'members', member_rows
  );
end;
$$;

revoke all on function public.bootstrap_ledger_group(text, jsonb)
  from public, anon;
grant execute on function public.bootstrap_ledger_group(text, jsonb)
  to authenticated;

create function public.archive_ledger_group(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  group_record public.ledger_groups;
  reconciliation jsonb;
begin
  select * into group_record
  from public.ledger_groups
  where id = p_group_id
  for update;

  if not found or not public.is_group_owner(p_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;
  if group_record.status = 'archived' then
    return jsonb_build_object('groupId', group_record.id, 'status', 'archived', 'archivedAt', group_record.archived_at);
  end if;
  reconciliation := public.get_ledger_reconciliation(p_group_id);
  if coalesce((reconciliation->>'isHealthy')::boolean, false) is not true then
    raise exception 'ledger reconciliation must be healthy before archiving' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.expenses where group_id = p_group_id and status <> 'resolved') then
    raise exception 'private expenses must be fully resolved before archiving' using errcode = 'P0001';
  end if;
  if exists (
    select 1 from public.group_funds
    where group_id = p_group_id and (status <> 'closed' or balance <> 0)
  ) then
    raise exception 'public fund must be closed with zero balance before archiving' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.fund_advances where group_id = p_group_id and status = 'open')
    or exists (select 1 from public.fund_collection_rounds where group_id = p_group_id and status = 'open') then
    raise exception 'public fund obligations must be completed before archiving' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.line_expense_drafts where group_id = p_group_id and status = 'pending')
    or exists (select 1 from public.line_fund_expense_drafts where group_id = p_group_id and status = 'pending') then
    raise exception 'pending LINE drafts must be completed before archiving' using errcode = 'P0001';
  end if;

  update public.group_invites
  set revoked_at = coalesce(revoked_at, now())
  where group_id = p_group_id and revoked_at is null;
  update public.line_group_bindings
  set active = false
  where group_id = p_group_id and active;
  insert into public.ledger_lifecycle_events (group_id, actor_user_id, action)
  values (p_group_id, (select auth.uid()), 'archive');
  update public.ledger_groups
  set status = 'archived', archived_at = now()
  where id = p_group_id
  returning * into group_record;

  return jsonb_build_object(
    'groupId', group_record.id,
    'status', group_record.status,
    'archivedAt', group_record.archived_at
  );
end;
$$;

create function public.restore_archived_ledger(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  group_record public.ledger_groups;
begin
  if current_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('clearsplit-owned:' || current_user_id::text, 0));

  select * into group_record
  from public.ledger_groups
  where id = p_group_id
  for update;
  if not found or not public.is_group_owner(p_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;
  if group_record.status = 'active' then
    return jsonb_build_object('groupId', group_record.id, 'status', 'active', 'archivedAt', null);
  end if;
  if public.active_owned_ledger_count(current_user_id) >= 5 then
    raise exception 'active owned ledger limit reached' using errcode = 'P0001';
  end if;

  update public.ledger_groups
  set status = 'active', archived_at = null
  where id = p_group_id
  returning * into group_record;
  insert into public.ledger_lifecycle_events (group_id, actor_user_id, action)
  values (p_group_id, current_user_id, 'restore');
  return jsonb_build_object('groupId', group_record.id, 'status', group_record.status, 'archivedAt', null);
end;
$$;

revoke all on function public.archive_ledger_group(uuid) from public, anon;
revoke all on function public.restore_archived_ledger(uuid) from public, anon;
grant execute on function public.archive_ledger_group(uuid) to authenticated;
grant execute on function public.restore_archived_ledger(uuid) to authenticated;

-- Every child-table mutation is rejected after archive, including service-role
-- webhook writes. Root ledger deletion remains possible through the existing
-- exact transaction-local cascade marker.
create function public.prevent_archived_ledger_mutation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  row_group_id uuid := nullif(coalesce(to_jsonb(new)->>'group_id', to_jsonb(old)->>'group_id'), '')::uuid;
begin
  if row_group_id is null then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if tg_op = 'DELETE' and public.is_marked_ledger_cascade_delete(row_group_id) then
    return old;
  end if;
  if exists (
    select 1 from public.ledger_groups
    where id = row_group_id and status = 'archived'
  ) then
    raise exception 'archived ledger is read-only' using errcode = '25006';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function public.prevent_archived_ledger_mutation()
  from public, anon, authenticated;

do $$
declare
  table_record record;
  trigger_name text;
begin
  for table_record in
    select c.table_name
    from information_schema.columns c
    join information_schema.tables t
      on t.table_schema = c.table_schema and t.table_name = c.table_name
    where c.table_schema = 'public'
      and c.column_name = 'group_id'
      and t.table_type = 'BASE TABLE'
  loop
    trigger_name := left(table_record.table_name, 45) || '_archive_read_only';
    execute format(
      'create trigger %I before insert or update or delete on public.%I for each row execute function public.prevent_archived_ledger_mutation()',
      trigger_name,
      table_record.table_name
    );
  end loop;
end;
$$;

create or replace function public.assign_group_responsible_member(
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
  current_user_id uuid := (select auth.uid());
  group_record public.ledger_groups;
  setup_record public.ledger_setup_tokens;
  target_member public.members;
  initial_assignment boolean;
begin
  if current_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select * into group_record from public.ledger_groups where id = p_group_id for update;
  if not found or group_record.status <> 'active' then
    raise exception 'ledger is unavailable' using errcode = '22023';
  end if;

  initial_assignment := group_record.responsible_member_id is null;
  if initial_assignment then
    select * into setup_record from public.ledger_setup_tokens where group_id = p_group_id for update;
    if not found or p_setup_token is null or p_setup_token !~ '^[0-9a-f]{32}$'
      or setup_record.token_hash is distinct from extensions.digest(p_setup_token, 'sha256')
      or setup_record.used_at is not null or setup_record.expires_at <= now() then
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
  if target_member.id = group_record.responsible_member_id then
    return jsonb_build_object('memberId', target_member.id, 'name', target_member.display_name, 'setupKeyConsumed', false);
  end if;

  perform pg_advisory_xact_lock(hashtextextended('clearsplit-owned:' || target_member.user_id::text, 0));
  if public.active_owned_ledger_count(target_member.user_id) >= 5 then
    raise exception 'recipient active owned ledger limit reached' using errcode = 'P0001';
  end if;
  if public.total_owned_ledger_count(target_member.user_id) >= 10 then
    raise exception 'recipient total owned ledger limit reached' using errcode = 'P0001';
  end if;
  if not initial_assignment and public.active_joined_ledger_count(current_user_id) >= 30 then
    raise exception 'current owner joined ledger limit reached' using errcode = 'P0001';
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

create or replace function public.get_line_invite_membership_status(
  p_token text,
  p_line_user_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  invite_record public.group_invites;
  group_record public.ledger_groups;
  member_record public.members;
begin
  if p_token !~ '^[0-9a-f]{64}$' or p_line_user_id !~ '^U[0-9a-f]{32}$' then
    raise exception 'invalid invite or LINE identity' using errcode = '22023';
  end if;
  select * into invite_record from public.group_invites
  where token_hash = extensions.digest(p_token, 'sha256');
  if not found then
    raise exception 'invite does not exist' using errcode = '22023';
  end if;
  select * into group_record from public.ledger_groups where id = invite_record.group_id;
  select * into member_record from public.members
  where group_id = invite_record.group_id and line_user_id = p_line_user_id;
  return jsonb_build_object(
    'groupId', group_record.id,
    'groupName', group_record.name,
    'isMember', member_record.id is not null,
    'isResponsible', coalesce(member_record.id = group_record.responsible_member_id, false),
    'inviteAvailable', group_record.status = 'active'
      and invite_record.revoked_at is null
      and invite_record.expires_at > now()
      and invite_record.use_count < invite_record.max_uses
  );
end;
$$;

create or replace function public.join_group_invite_with_line(
  p_token text,
  p_auth_user_id uuid,
  p_line_user_id text,
  p_display_name text,
  p_avatar_url text,
  p_color text default '#64748b'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  invite_record public.group_invites;
  group_record public.ledger_groups;
  line_member public.members;
  auth_member public.members;
  member_record public.members;
  was_created boolean := false;
begin
  if not exists (select 1 from public.line_identities where user_id = p_auth_user_id and line_user_id = p_line_user_id) then
    raise exception 'verified LINE identity required' using errcode = '42501';
  end if;
  if p_token !~ '^[0-9a-f]{64}$' or p_color !~ '^#[0-9A-Fa-f]{6}$' then
    raise exception 'invalid invite or color' using errcode = '22023';
  end if;
  select * into invite_record from public.group_invites
  where token_hash = extensions.digest(p_token, 'sha256') for update;
  if not found then raise exception 'invite does not exist' using errcode = '22023'; end if;
  select * into group_record from public.ledger_groups where id = invite_record.group_id;
  if group_record.status <> 'active' then
    raise exception 'invite is unavailable' using errcode = '22023';
  end if;
  select * into line_member from public.members
  where group_id = invite_record.group_id and line_user_id = p_line_user_id;
  select * into auth_member from public.members
  where group_id = invite_record.group_id and user_id = p_auth_user_id;
  if line_member.id is null and (
    invite_record.revoked_at is not null or invite_record.expires_at <= now()
    or invite_record.use_count >= invite_record.max_uses
  ) then raise exception 'invite is unavailable' using errcode = '22023'; end if;
  if line_member.id is not null and auth_member.id is not null and line_member.id <> auth_member.id then
    raise exception 'LINE identity conflicts with an existing member' using errcode = '23505';
  end if;

  if line_member.id is not null then
    update public.members set user_id = p_auth_user_id, display_name = trim(p_display_name), avatar_url = p_avatar_url
    where id = line_member.id returning * into member_record;
  elsif auth_member.id is not null then
    if auth_member.line_user_id is not null and auth_member.line_user_id <> p_line_user_id then
      raise exception 'app session is linked to another LINE identity' using errcode = '23505';
    end if;
    update public.members set line_user_id = p_line_user_id, display_name = trim(p_display_name), avatar_url = p_avatar_url
    where id = auth_member.id returning * into member_record;
  else
    perform pg_advisory_xact_lock(hashtextextended('clearsplit-joined:' || p_auth_user_id::text, 0));
    if public.active_joined_ledger_count(p_auth_user_id) >= 30 then
      raise exception 'active joined ledger limit reached' using errcode = 'P0001';
    end if;
    if (select count(*) from public.members where group_id = invite_record.group_id) >= 50 then
      raise exception 'member limit reached' using errcode = 'P0001';
    end if;
    insert into public.members (group_id, user_id, role, display_name, avatar_url, color, line_user_id)
    values (invite_record.group_id, p_auth_user_id, 'member', trim(p_display_name), p_avatar_url, p_color, p_line_user_id)
    returning * into member_record;
    was_created := true;
  end if;
  if was_created then
    update public.group_invites set use_count = use_count + 1 where id = invite_record.id;
  end if;
  return jsonb_build_object(
    'groupId', group_record.id,
    'groupName', group_record.name,
    'memberId', member_record.id,
    'displayName', member_record.display_name,
    'avatarUrl', member_record.avatar_url
  );
end;
$$;

create or replace function public.resume_group_invite_with_line(
  p_token text,
  p_auth_user_id uuid,
  p_line_user_id text,
  p_display_name text,
  p_avatar_url text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  invite_record public.group_invites;
  group_record public.ledger_groups;
  line_member public.members;
  auth_member public.members;
  member_record public.members;
  invite_available boolean;
begin
  if not exists (select 1 from public.line_identities where user_id = p_auth_user_id and line_user_id = p_line_user_id) then
    raise exception 'verified LINE identity required' using errcode = '42501';
  end if;
  if p_token !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid invite' using errcode = '22023';
  end if;
  select * into invite_record from public.group_invites
  where token_hash = extensions.digest(p_token, 'sha256');
  if not found then raise exception 'invite does not exist' using errcode = '22023'; end if;
  select * into group_record from public.ledger_groups where id = invite_record.group_id;
  invite_available := group_record.status = 'active'
    and invite_record.revoked_at is null
    and invite_record.expires_at > now()
    and invite_record.use_count < invite_record.max_uses;
  if group_record.status <> 'active' then
    return jsonb_build_object(
      'groupId', group_record.id, 'groupName', group_record.name,
      'isMember', false, 'isResponsible', false, 'inviteAvailable', false
    );
  end if;
  select * into line_member from public.members
  where group_id = invite_record.group_id and line_user_id = p_line_user_id;
  select * into auth_member from public.members
  where group_id = invite_record.group_id and user_id = p_auth_user_id;
  if line_member.id is null and auth_member.id is null then
    return jsonb_build_object(
      'groupId', group_record.id, 'groupName', group_record.name,
      'isMember', false, 'isResponsible', false, 'inviteAvailable', invite_available
    );
  end if;
  if line_member.id is not null and auth_member.id is not null and line_member.id <> auth_member.id then
    raise exception 'LINE identity conflicts with an existing member' using errcode = '23505';
  end if;
  if line_member.id is not null then
    update public.members set user_id = p_auth_user_id, display_name = trim(p_display_name), avatar_url = p_avatar_url
    where id = line_member.id returning * into member_record;
  else
    if auth_member.line_user_id is not null and auth_member.line_user_id <> p_line_user_id then
      raise exception 'app session is linked to another LINE identity' using errcode = '23505';
    end if;
    update public.members set line_user_id = p_line_user_id, display_name = trim(p_display_name), avatar_url = p_avatar_url
    where id = auth_member.id returning * into member_record;
  end if;
  return jsonb_build_object(
    'groupId', group_record.id, 'groupName', group_record.name,
    'isMember', true,
    'isResponsible', coalesce(member_record.id = group_record.responsible_member_id, false),
    'inviteAvailable', invite_available
  );
end;
$$;

create or replace function public.restore_active_ledger_with_line(
  p_auth_user_id uuid,
  p_line_user_id text,
  p_display_name text,
  p_avatar_url text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  ledger_rows jsonb;
begin
  if not exists (select 1 from public.line_identities where user_id = p_auth_user_id and line_user_id = p_line_user_id) then
    raise exception 'verified LINE identity required' using errcode = '42501';
  end if;
  update public.members m set
    user_id = p_auth_user_id,
    display_name = trim(p_display_name),
    avatar_url = p_avatar_url
  from public.ledger_groups g
  where m.group_id = g.id and g.status = 'active'
    and m.line_user_id = p_line_user_id
    and (m.user_id, m.display_name, m.avatar_url) is distinct from
      (p_auth_user_id, trim(p_display_name), p_avatar_url);

  select coalesce(jsonb_agg(jsonb_build_object(
    'groupId', g.id,
    'groupName', g.name,
    'status', g.status,
    'archivedAt', g.archived_at,
    'createdAt', g.created_at,
    'updatedAt', g.updated_at,
    'isCreator', g.created_by = p_auth_user_id,
    'isOwner', g.responsible_member_id = m.id,
    'memberId', m.id,
    'memberCount', (select count(*) from public.members all_members where all_members.group_id = g.id),
    'expenseCount', (select count(*) from public.expenses e where e.group_id = g.id)
  ) order by case when g.status = 'active' then 0 else 1 end, g.updated_at desc), '[]'::jsonb)
  into ledger_rows
  from public.members m
  join public.ledger_groups g on g.id = m.group_id
  where m.user_id = p_auth_user_id;

  return jsonb_build_object(
    'found', jsonb_array_length(ledger_rows) > 0,
    'ledgers', ledger_rows
  );
end;
$$;

revoke all on function public.get_line_invite_membership_status(text, text)
  from public, anon, authenticated;
revoke all on function public.join_group_invite_with_line(text, uuid, text, text, text, text)
  from public, anon, authenticated;
revoke all on function public.resume_group_invite_with_line(text, uuid, text, text, text)
  from public, anon, authenticated;
revoke all on function public.restore_active_ledger_with_line(uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function public.get_line_invite_membership_status(text, text) to service_role;
grant execute on function public.join_group_invite_with_line(text, uuid, text, text, text, text) to service_role;
grant execute on function public.resume_group_invite_with_line(text, uuid, text, text, text) to service_role;
grant execute on function public.restore_active_ledger_with_line(uuid, text, text, text) to service_role;
