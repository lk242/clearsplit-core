-- LINE-friendly invite flow. Raw invite tokens are returned once and only
-- SHA-256 hashes are persisted. All RPCs require a Supabase Auth session.

create extension if not exists pgcrypto with schema extensions;

create function public.bootstrap_ledger_group(
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
    or jsonb_array_length(p_participants) not between 1 and 50 then
    raise exception 'participants must contain 1 to 50 entries' using errcode = '22023';
  end if;
  if exists (select 1 from public.members where user_id = current_user_id) then
    raise exception 'current user already belongs to a ledger group' using errcode = '23505';
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

    insert into public.members (group_id, user_id, role, display_name, color)
    values (
      new_group.id,
      case when participant_index = 0 then current_user_id else null end,
      case when participant_index = 0 then 'owner'::public.group_role else 'member'::public.group_role end,
      participant_name,
      participant_color
    )
    returning * into new_member;

    member_rows := member_rows || jsonb_build_array(jsonb_build_object(
      'clientId', participant->>'clientId',
      'id', new_member.id,
      'name', new_member.display_name,
      'color', new_member.color,
      'createdAt', new_member.created_at,
      'linked', new_member.user_id is not null
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

create function public.create_group_invite(
  p_group_id uuid,
  p_valid_hours integer default 168,
  p_max_uses integer default 50
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
  if current_user_id is null or not public.is_group_owner(p_group_id) then
    raise exception 'group owner permission required' using errcode = '42501';
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

create function public.preview_group_invite(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  invite_record record;
begin
  if (select auth.uid()) is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_token !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid invite token' using errcode = '22023';
  end if;

  select i.*, g.name as group_name
  into invite_record
  from public.group_invites i
  join public.ledger_groups g on g.id = i.group_id
  where i.token_hash = extensions.digest(p_token, 'sha256');

  if not found
    or invite_record.revoked_at is not null
    or invite_record.expires_at <= now()
    or invite_record.use_count >= invite_record.max_uses then
    raise exception 'invite is unavailable' using errcode = '22023';
  end if;

  return jsonb_build_object(
    'groupId', invite_record.group_id,
    'groupName', invite_record.group_name,
    'expiresAt', invite_record.expires_at,
    'remainingUses', invite_record.max_uses - invite_record.use_count
  );
end;
$$;

create function public.join_group_invite(
  p_token text,
  p_display_name text,
  p_color text default '#64748b'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  current_user_id uuid := (select auth.uid());
  invite_record public.group_invites;
  group_record public.ledger_groups;
  member_record public.members;
begin
  if current_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_token !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid invite token' using errcode = '22023';
  end if;
  if char_length(trim(p_display_name)) not between 1 and 80 then
    raise exception 'invalid display name' using errcode = '22023';
  end if;
  if p_color !~ '^#[0-9A-Fa-f]{6}$' then
    raise exception 'invalid color' using errcode = '22023';
  end if;

  select * into invite_record
  from public.group_invites
  where token_hash = extensions.digest(p_token, 'sha256')
  for update;

  if not found
    or invite_record.revoked_at is not null
    or invite_record.expires_at <= now()
    or invite_record.use_count >= invite_record.max_uses then
    raise exception 'invite is unavailable' using errcode = '22023';
  end if;

  select * into member_record
  from public.members
  where group_id = invite_record.group_id and user_id = current_user_id;

  if not found then
    insert into public.members (group_id, user_id, role, display_name, color)
    values (invite_record.group_id, current_user_id, 'member', trim(p_display_name), p_color)
    returning * into member_record;

    update public.group_invites
    set use_count = use_count + 1
    where id = invite_record.id;
  end if;

  select * into group_record from public.ledger_groups where id = invite_record.group_id;

  return jsonb_build_object(
    'groupId', group_record.id,
    'groupName', group_record.name,
    'member', jsonb_build_object(
      'id', member_record.id,
      'name', member_record.display_name,
      'color', member_record.color,
      'createdAt', member_record.created_at,
      'linked', true
    )
  );
end;
$$;

revoke all on function public.bootstrap_ledger_group(text, jsonb) from public, anon;
revoke all on function public.create_group_invite(uuid, integer, integer) from public, anon;
revoke all on function public.preview_group_invite(text) from public, anon;
revoke all on function public.join_group_invite(text, text, text) from public, anon;

grant execute on function public.bootstrap_ledger_group(text, jsonb) to authenticated;
grant execute on function public.create_group_invite(uuid, integer, integer) to authenticated;
grant execute on function public.preview_group_invite(text) to authenticated;
grant execute on function public.join_group_invite(text, text, text) to authenticated;
