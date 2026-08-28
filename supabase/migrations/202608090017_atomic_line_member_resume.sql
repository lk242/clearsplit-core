-- Restore a verified existing LINE member in one atomic operation.
-- This never creates a new member, so first-time invitees still need to
-- explicitly confirm joining from the LIFF page.

create function public.resume_group_invite_with_line(
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
  if not exists (select 1 from auth.users where id = p_auth_user_id) then
    raise exception 'authenticated user is unavailable' using errcode = '42501';
  end if;
  if p_token !~ '^[0-9a-f]{64}$' or p_line_user_id !~ '^U[0-9a-f]{32}$' then
    raise exception 'invalid invite or LINE identity' using errcode = '22023';
  end if;
  if char_length(trim(p_display_name)) not between 1 and 80 then
    raise exception 'invalid LINE display name' using errcode = '22023';
  end if;
  if p_avatar_url is not null and (char_length(p_avatar_url) > 2048 or p_avatar_url !~ '^https://') then
    raise exception 'invalid LINE avatar URL' using errcode = '22023';
  end if;

  select * into invite_record
  from public.group_invites
  where token_hash = extensions.digest(p_token, 'sha256');

  if not found then
    raise exception 'invite does not exist' using errcode = '22023';
  end if;

  select * into group_record
  from public.ledger_groups
  where id = invite_record.group_id;

  invite_available := invite_record.revoked_at is null
    and invite_record.expires_at > now()
    and invite_record.use_count < invite_record.max_uses;

  select * into line_member
  from public.members
  where group_id = invite_record.group_id
    and line_user_id = p_line_user_id;

  select * into auth_member
  from public.members
  where group_id = invite_record.group_id
    and user_id = p_auth_user_id;

  if line_member.id is null and auth_member.id is null then
    return jsonb_build_object(
      'groupId', group_record.id,
      'groupName', group_record.name,
      'isMember', false,
      'isResponsible', false,
      'inviteAvailable', invite_available
    );
  end if;

  if line_member.id is not null and auth_member.id is not null and line_member.id <> auth_member.id then
    raise exception 'LINE identity conflicts with an existing member' using errcode = '23505';
  end if;

  if line_member.id is not null then
    update public.members set
      user_id = p_auth_user_id,
      display_name = trim(p_display_name),
      avatar_url = p_avatar_url
    where id = line_member.id
    returning * into member_record;
  else
    if auth_member.line_user_id is not null and auth_member.line_user_id <> p_line_user_id then
      raise exception 'app session is linked to another LINE identity' using errcode = '23505';
    end if;

    update public.members set
      line_user_id = p_line_user_id,
      display_name = trim(p_display_name),
      avatar_url = p_avatar_url
    where id = auth_member.id
    returning * into member_record;
  end if;

  return jsonb_build_object(
    'groupId', group_record.id,
    'groupName', group_record.name,
    'isMember', true,
    'isResponsible', member_record.id = group_record.responsible_member_id,
    'inviteAvailable', invite_available
  );
end;
$$;

revoke all on function public.resume_group_invite_with_line(text, uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function public.resume_group_invite_with_line(text, uuid, text, text, text)
  to service_role;
