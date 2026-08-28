-- Multi-ledger ownership, membership quota, transfer, archive, and read-only
-- integration test. Every fixture is rolled back.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(1);

do $$
declare
  owner_user_id uuid := '00000000-0000-4000-8000-000000000101';
  member_user_id uuid := '00000000-0000-4000-8000-000000000102';
  joiner_user_id uuid := '00000000-0000-4000-8000-000000000103';
  fixture_owner_user_id uuid := '00000000-0000-4000-8000-000000000104';
  owner_line_id text := 'U00000000000000000000000000000101';
  member_line_id text := 'U00000000000000000000000000000102';
  joiner_line_id text := 'U00000000000000000000000000000103';
  result jsonb;
  directory jsonb;
  group_id uuid;
  member_id uuid;
  owner_member_id uuid;
  join_limit_group_id uuid;
  invite_token text := repeat('a', 64);
  index integer;
  rejected boolean;
  line_profile jsonb;
begin
  insert into public.line_identities (user_id, line_user_id, display_name)
  values
    (owner_user_id, owner_line_id, 'quota owner'),
    (member_user_id, member_line_id, 'quota member')
  on conflict (user_id) do update set line_user_id = excluded.line_user_id, display_name = excluded.display_name;

  perform set_config('request.jwt.claim.sub', owner_user_id::text, true);

  line_profile := public.get_my_line_profile();
  if line_profile <> jsonb_build_object('displayName', 'quota owner', 'avatarUrl', null)
    or line_profile ? 'lineUserId' then
    raise exception 'verified LINE profile exposed an invalid or excessive contract';
  end if;
  perform set_config('request.jwt.claim.sub', fixture_owner_user_id::text, true);
  if public.get_my_line_profile() is not null then
    raise exception 'LINE profile leaked across authenticated accounts';
  end if;
  perform set_config('request.jwt.claim.sub', owner_user_id::text, true);

  -- Five active owned ledgers are allowed and a joined ledger never consumes
  -- this quota.
  for index in 1..5 loop
    result := public.bootstrap_ledger_group('owned active ' || index, '[]'::jsonb);
  end loop;
  if public.active_owned_ledger_count(owner_user_id) <> 5
    or public.total_owned_ledger_count(owner_user_id) <> 5 then
    raise exception 'owned ledger counters are incorrect at the active limit';
  end if;

  rejected := false;
  begin
    perform public.bootstrap_ledger_group('sixth active must fail', '[]'::jsonb);
  exception when sqlstate 'P0001' then
    rejected := true;
  end;
  if not rejected then raise exception 'sixth active owned ledger was accepted'; end if;

  select id into group_id from public.ledger_groups
  where name = 'owned active 1' and created_by = owner_user_id;
  result := public.archive_ledger_group(group_id);
  if result->>'status' <> 'archived' then raise exception 'archive did not change status'; end if;
  result := public.bootstrap_ledger_group('replacement active', '[]'::jsonb);
  if public.active_owned_ledger_count(owner_user_id) <> 5
    or public.total_owned_ledger_count(owner_user_id) <> 6 then
    raise exception 'archived ledger consumed active quota or total quota is wrong';
  end if;

  -- Archived children are immutable even to a direct write path.
  rejected := false;
  begin
    insert into public.members (group_id, role, display_name, color)
    values (group_id, 'member', 'must not write', '#112233');
  exception when sqlstate '25006' then
    rejected := true;
  end;
  if not rejected then raise exception 'archived ledger accepted a child mutation'; end if;

  -- Restore is denied while the active-owned quota is full.
  rejected := false;
  begin
    perform public.restore_archived_ledger(group_id);
  exception when sqlstate 'P0001' then
    rejected := true;
  end;
  if not rejected then raise exception 'archived ledger bypassed active-owned quota on restore'; end if;

  directory := public.list_my_ledgers();
  if (directory#>>'{usage,activeOwned}')::integer <> 5
    or (directory#>>'{usage,totalOwned}')::integer <> 6
    or jsonb_array_length(directory->'ledgers') <> 6 then
    raise exception 'ledger directory contract or quota usage is incorrect';
  end if;
  if not exists (
    select 1 from jsonb_array_elements(directory->'ledgers') item
    where item->>'groupId' = group_id::text
      and (item->>'isCreator')::boolean
      and (item->>'isOwner')::boolean
      and item->>'status' = 'archived'
  ) then
    raise exception 'creator, owner, and archive boundaries are missing from directory';
  end if;

  -- Keep five active while rotating older ledgers into archive. Archived rows
  -- still consume the immutable total-owned quota of ten.
  for index in 7..10 loop
    select g.id into group_id
    from public.ledger_groups g
    where g.status = 'active' and public.ledger_owner_user_id(g.id) = owner_user_id
    order by g.created_at, g.id
    limit 1;
    perform public.archive_ledger_group(group_id);
    perform public.bootstrap_ledger_group('total owned ' || index, '[]'::jsonb);
  end loop;
  if public.active_owned_ledger_count(owner_user_id) <> 5
    or public.total_owned_ledger_count(owner_user_id) <> 10 then
    raise exception 'total-owned quota rotation is incorrect';
  end if;
  rejected := false;
  begin
    select g.id into group_id
    from public.ledger_groups g
    where g.status = 'active' and public.ledger_owner_user_id(g.id) = owner_user_id
    order by g.created_at, g.id
    limit 1;
    perform public.archive_ledger_group(group_id);
    perform public.bootstrap_ledger_group('eleventh total must fail', '[]'::jsonb);
  exception when sqlstate 'P0001' then
    rejected := true;
  end;
  if not rejected then raise exception 'eleventh total owned ledger was accepted'; end if;

  -- A joined membership is counted separately and does not change owned use.
  insert into public.ledger_groups (name, created_by)
  values ('member-owned fixture', member_user_id)
  returning id into group_id;
  insert into public.members (group_id, user_id, role, display_name, color, line_user_id)
  values (group_id, member_user_id, 'owner', 'quota member', '#445566', member_line_id)
  returning id into member_id;
  update public.ledger_groups set responsible_member_id = member_id where id = group_id;
  insert into public.members (group_id, user_id, role, display_name, color, line_user_id)
  values (group_id, owner_user_id, 'member', 'quota owner', '#665544', owner_line_id);
  if public.active_joined_ledger_count(owner_user_id) <> 1
    or public.active_owned_ledger_count(owner_user_id) <> 5 then
    raise exception 'joined ledger incorrectly consumed owned quota';
  end if;

  -- Fill the recipient's ownership quota. A transfer to that member must fail
  -- and leave the current responsible member unchanged.
  perform set_config('request.jwt.claim.sub', member_user_id::text, true);
  for index in 1..4 loop
    perform public.bootstrap_ledger_group('recipient owned ' || index, '[]'::jsonb);
  end loop;
  if public.active_owned_ledger_count(member_user_id) <> 5 then
    raise exception 'transfer recipient fixture did not reach its active quota';
  end if;

  perform set_config('request.jwt.claim.sub', owner_user_id::text, true);
  select g.id into group_id from public.ledger_groups g
  where g.name = 'total owned 10' and g.created_by = owner_user_id;
  insert into public.members (group_id, user_id, role, display_name, color, line_user_id)
  values (group_id, member_user_id, 'member', 'quota member', '#445566', member_line_id)
  returning id into member_id;
  rejected := false;
  begin
    perform public.assign_group_responsible_member(group_id, member_id, null);
  exception when sqlstate 'P0001' then
    rejected := true;
  end;
  if not rejected or public.ledger_owner_user_id(group_id) <> owner_user_id then
    raise exception 'ownership transfer ignored recipient quota or changed authority after rejection';
  end if;

  -- Joined ledgers have their own hard limit. Build 30 valid memberships,
  -- then prove the 31st invite neither inserts a member nor consumes a use.
  insert into public.line_identities (user_id, line_user_id, display_name)
  values (joiner_user_id, joiner_line_id, 'join limit member')
  on conflict (user_id) do update set line_user_id = excluded.line_user_id, display_name = excluded.display_name;
  for index in 1..30 loop
    insert into public.ledger_groups (name, created_by)
    values ('join limit fixture ' || index, fixture_owner_user_id)
    returning id into group_id;
    insert into public.members (group_id, user_id, role, display_name, color)
    values (group_id, fixture_owner_user_id, 'owner', 'fixture owner', '#334455')
    returning id into owner_member_id;
    update public.ledger_groups set responsible_member_id = owner_member_id where id = group_id;
    insert into public.members (group_id, user_id, role, display_name, color, line_user_id)
    values (group_id, joiner_user_id, 'member', 'join limit member', '#556677', joiner_line_id);
  end loop;
  if public.active_joined_ledger_count(joiner_user_id) <> 30 then
    raise exception 'joined ledger counter did not reach thirty';
  end if;

  insert into public.ledger_groups (name, created_by)
  values ('join limit rejected fixture', fixture_owner_user_id)
  returning id into join_limit_group_id;
  insert into public.members (group_id, user_id, role, display_name, color)
  values (join_limit_group_id, fixture_owner_user_id, 'owner', 'fixture owner', '#334455')
  returning id into owner_member_id;
  update public.ledger_groups set responsible_member_id = owner_member_id where id = join_limit_group_id;
  insert into public.group_invites (group_id, token_hash, expires_at, max_uses, created_by)
  values (join_limit_group_id, extensions.digest(invite_token, 'sha256'), now() + interval '1 day', 1, fixture_owner_user_id);
  perform set_config('request.jwt.claim.sub', joiner_user_id::text, true);
  rejected := false;
  begin
    perform public.join_group_invite_with_line(
      invite_token, joiner_user_id, joiner_line_id,
      'join limit member', null, '#556677'
    );
  exception when sqlstate 'P0001' then
    rejected := true;
  end;
  if not rejected
    or exists (select 1 from public.members m where m.group_id = join_limit_group_id and m.user_id = joiner_user_id)
    or exists (select 1 from public.group_invites i where i.group_id = join_limit_group_id and i.use_count <> 0) then
    raise exception 'thirty-first joined ledger mutated membership or invite state';
  end if;
end;
$$;

select pass('multi-ledger quotas, roles, transfers, archive, and read-only boundaries hold');
select * from finish();
rollback;
