-- A LINE member may open the same singleton ledger from the LIFF WebView or
-- from a normal browser. The Edge Function verifies LINE and calls this
-- service-role-only RPC to attach the verified stable Auth user to the member.

create function public.restore_active_ledger_with_line(
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
  group_record public.ledger_groups;
  member_record public.members;
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

  select * into member_record
  from public.members
  where line_user_id = p_line_user_id
  for update;

  if not found then
    return jsonb_build_object('found', false);
  end if;

  select * into strict group_record
  from public.ledger_groups
  where id = member_record.group_id;

  if exists (
    select 1 from public.members
    where user_id = p_auth_user_id and id <> member_record.id
  ) then
    raise exception 'authenticated user is linked to another member' using errcode = '23505';
  end if;

  -- Attribute the profile/session rebind audit event to the verified member.
  perform set_config('request.jwt.claim.sub', p_auth_user_id::text, true);
  update public.members set
    user_id = p_auth_user_id,
    display_name = trim(p_display_name),
    avatar_url = p_avatar_url
  where id = member_record.id
  returning * into member_record;

  return jsonb_build_object(
    'found', true,
    'groupId', group_record.id,
    'groupName', group_record.name,
    'memberId', member_record.id,
    'isResponsible', member_record.id = group_record.responsible_member_id
  );
end;
$$;

revoke all on function public.restore_active_ledger_with_line(uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function public.restore_active_ledger_with_line(uuid, text, text, text)
  to service_role;

insert into public.app_schema_versions (version, name)
values (32, 'stable LINE web session and direct-site ledger restore');
