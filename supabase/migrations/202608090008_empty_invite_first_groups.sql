-- Invite-first group setup: the creator remains the system administrator but
-- is not inserted as a financial member. A responsible member is selected
-- only after real members have joined.

alter table public.ledger_groups
  add column responsible_member_id uuid;

alter table public.ledger_groups
  add constraint ledger_groups_responsible_member_same_group_fk
  foreign key (responsible_member_id)
  references public.members(id)
  on delete set null;

update public.ledger_groups g
set responsible_member_id = (
  select m.id
  from public.members m
  where m.group_id = g.id and m.role = 'owner'
  order by m.created_at, m.id
  limit 1
)
where exists (
  select 1 from public.members m where m.group_id = g.id and m.role = 'owner'
);

create or replace function public.is_group_member(target_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select (
  exists (
    select 1 from public.ledger_groups
    where id = target_group_id and created_by = (select auth.uid())
  ) or exists (
    select 1 from public.members
    where group_id = target_group_id and user_id = (select auth.uid())
  ));
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
    'members', member_rows
  );
end;
$$;

create function public.assign_group_responsible_member(
  p_group_id uuid,
  p_member_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  target_member public.members;
begin
  if (select auth.uid()) is null or not public.is_group_owner(p_group_id) then
    raise exception 'group owner permission required' using errcode = '42501';
  end if;

  select * into target_member
  from public.members
  where group_id = p_group_id and id = p_member_id
  for update;

  if not found then
    raise exception 'member is unavailable' using errcode = '22023';
  end if;

  update public.members set role = 'member' where group_id = p_group_id and role = 'owner';
  update public.members set role = 'owner' where group_id = p_group_id and id = p_member_id;
  update public.ledger_groups set responsible_member_id = p_member_id where id = p_group_id;

  return jsonb_build_object(
    'memberId', target_member.id,
    'name', target_member.display_name
  );
end;
$$;

create function public.ensure_new_fund_member_account()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.group_funds where group_id = new.group_id) then
    insert into public.fund_member_accounts (group_id, member_id, balance)
    values (new.group_id, new.id, 0)
    on conflict (group_id, member_id) do nothing;
  end if;
  return new;
end;
$$;

create trigger members_ensure_fund_account
after insert on public.members
for each row execute function public.ensure_new_fund_member_account();

revoke all on function public.assign_group_responsible_member(uuid, uuid) from public, anon;
grant execute on function public.assign_group_responsible_member(uuid, uuid) to authenticated;
