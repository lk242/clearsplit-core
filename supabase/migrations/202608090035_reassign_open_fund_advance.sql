-- An unconfirmed public-fund advance can be assigned to the wrong member when
-- the recorder and the bookkeeping responsible member differ. Allow the
-- responsible member to correct that attribution before either side confirms.
-- The existing fund_advances audit trigger records the before/after member IDs.

create function public.reassign_group_fund_advance(
  p_group_id uuid,
  p_advance_id uuid,
  p_expected_member_id uuid,
  p_new_member_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  advance_record public.fund_advances;
begin
  if (select auth.uid()) is null or not public.is_group_owner(p_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;
  if p_advance_id is null or p_expected_member_id is null or p_new_member_id is null then
    raise exception 'invalid fund advance reassignment' using errcode = '22023';
  end if;

  select * into advance_record
  from public.fund_advances
  where id = p_advance_id and group_id = p_group_id
  for update;

  if not found or advance_record.status <> 'open' then
    raise exception 'fund advance is not open' using errcode = '23514';
  end if;
  if advance_record.member_confirmed_at is not null
    or advance_record.responsible_confirmed_at is not null
    or advance_record.completed_at is not null then
    raise exception 'confirmed fund advance cannot be reassigned' using errcode = '23514';
  end if;
  if advance_record.member_id is distinct from p_expected_member_id then
    raise exception 'fund advance changed; refresh and try again' using errcode = '40001';
  end if;
  if not exists (
    select 1 from public.members
    where id = p_new_member_id and group_id = p_group_id
  ) then
    raise exception 'new advance member is unavailable' using errcode = '22023';
  end if;

  if advance_record.member_id is distinct from p_new_member_id then
    update public.fund_advances
    set member_id = p_new_member_id
    where id = p_advance_id;
  end if;

  return public.get_group_fund(p_group_id);
end;
$$;

revoke all on function public.reassign_group_fund_advance(uuid, uuid, uuid, uuid)
  from public, anon;
grant execute on function public.reassign_group_fund_advance(uuid, uuid, uuid, uuid)
  to authenticated;

insert into public.app_schema_versions (version, name)
values (35, 'auditable public-fund advance reassignment');
