-- A LINE user identity is accepted only after an Edge Function verifies the
-- LIFF access token with LINE. Browser clients cannot call this RPC directly.

alter table public.members
  add column line_user_id text
  check (line_user_id is null or line_user_id ~ '^U[0-9a-f]{32}$');

alter table public.members
  add constraint members_avatar_https
  check (avatar_url is null or (char_length(avatar_url) <= 2048 and avatar_url ~ '^https://'));

create unique index members_group_line_user_unique
  on public.members(group_id, line_user_id)
  where line_user_id is not null;

create function public.join_group_invite_with_line(
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

  select * into line_member from public.members
  where group_id = invite_record.group_id and line_user_id = p_line_user_id;
  select * into auth_member from public.members
  where group_id = invite_record.group_id and user_id = p_auth_user_id;

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
  elsif auth_member.id is not null then
    update public.members set
      line_user_id = p_line_user_id,
      display_name = trim(p_display_name),
      avatar_url = p_avatar_url
    where id = auth_member.id
    returning * into member_record;
  else
    insert into public.members (
      group_id, user_id, role, display_name, avatar_url, color, line_user_id
    ) values (
      invite_record.group_id, p_auth_user_id, 'member', trim(p_display_name),
      p_avatar_url, p_color, p_line_user_id
    ) returning * into member_record;
    was_created := true;
  end if;

  if was_created then
    update public.group_invites set use_count = use_count + 1 where id = invite_record.id;
  end if;

  select * into group_record from public.ledger_groups where id = invite_record.group_id;
  return jsonb_build_object(
    'groupId', group_record.id,
    'groupName', group_record.name,
    'memberId', member_record.id,
    'displayName', member_record.display_name,
    'avatarUrl', member_record.avatar_url
  );
end;
$$;

revoke all on function public.join_group_invite_with_line(text, uuid, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.join_group_invite_with_line(text, uuid, text, text, text, text)
  to service_role;
