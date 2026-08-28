-- Remove an obsolete receipt-only RPC whose table columns were superseded by
-- dual confirmation, and preserve the group-fund lock without an unused row
-- variable so database lint can validate every callable function cleanly.

drop function if exists public.record_private_expense_receipt(
  uuid, uuid, uuid, boolean
);

create or replace function public.record_group_fund_advance_confirmation_v37(
  p_group_id uuid,
  p_advance_id uuid,
  p_actor_role text,
  p_confirm boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  current_member_id uuid;
  advance_record public.fund_advances;
  remaining_amount bigint;
  state_changed boolean := false;
begin
  if current_user_id is null or p_actor_role not in ('member', 'responsible')
    or p_confirm is null then
    raise exception 'invalid fund advance confirmation' using errcode = '22023';
  end if;
  select id into current_member_id
  from public.members where group_id = p_group_id and user_id = current_user_id;

  -- Lock the fund row before an advance is confirmed. The row itself is not
  -- consumed; FOUND is the availability check.
  perform 1
  from public.group_funds where group_id = p_group_id for update;
  if not found then
    raise exception 'group fund is unavailable' using errcode = '23514';
  end if;

  select * into advance_record
  from public.fund_advances
  where id = p_advance_id and group_id = p_group_id
  for update;
  if not found or advance_record.status <> 'open' then
    raise exception 'fund advance is not open' using errcode = '23514';
  end if;
  if exists (
    select 1 from public.fund_collection_advance_offsets
    where advance_id = p_advance_id and status = 'pending'
  ) then
    raise exception 'fund advance is reserved for an open collection' using errcode = '23514';
  end if;
  if p_actor_role = 'member' and current_member_id is distinct from advance_record.member_id then
    raise exception 'advance member confirmation required' using errcode = '42501';
  end if;
  if p_actor_role = 'responsible' and not public.is_group_owner(p_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;

  if p_actor_role = 'member' then
    if p_confirm and advance_record.member_confirmed_at is null then
      update public.fund_advances
      set member_confirmed_at = now(), member_confirmed_by = current_user_id
      where id = p_advance_id returning * into advance_record;
      state_changed := true;
    elsif not p_confirm and advance_record.member_confirmed_at is not null then
      update public.fund_advances
      set member_confirmed_at = null, member_confirmed_by = null
      where id = p_advance_id returning * into advance_record;
      state_changed := true;
    end if;
  else
    if p_confirm and advance_record.responsible_confirmed_at is null then
      update public.fund_advances
      set responsible_confirmed_at = now(), responsible_confirmed_by = current_user_id
      where id = p_advance_id returning * into advance_record;
      state_changed := true;
    elsif not p_confirm and advance_record.responsible_confirmed_at is not null then
      update public.fund_advances
      set responsible_confirmed_at = null, responsible_confirmed_by = null
      where id = p_advance_id returning * into advance_record;
      state_changed := true;
    end if;
  end if;
  if state_changed then
    insert into public.fund_advance_confirmation_events (
      advance_id, group_id, actor_user_id, actor_role, action
    ) values (
      p_advance_id, p_group_id, current_user_id, p_actor_role,
      case when p_confirm then 'confirm' else 'revoke' end
    );
  end if;

  if advance_record.member_confirmed_at is not null
    and advance_record.responsible_confirmed_at is not null then
    remaining_amount := advance_record.amount - advance_record.settled_amount;
    if public.fund_available_cash(p_group_id) < remaining_amount then
      raise exception 'fund cash is insufficient for advance repayment' using errcode = '23514';
    end if;
    update public.fund_advances
    set settled_amount = amount, status = 'completed', completed_at = now()
    where id = p_advance_id;
    insert into public.fund_advance_confirmation_events (
      advance_id, group_id, actor_user_id, actor_role, action
    ) values (
      p_advance_id, p_group_id, current_user_id, p_actor_role, 'complete'
    );
  end if;
  return public.get_group_fund(p_group_id);
end;
$$;

revoke all on function public.record_group_fund_advance_confirmation_v37(
  uuid, uuid, text, boolean
) from public, anon;

insert into public.app_schema_versions (version, name)
values (45, 'remove obsolete receipt RPC and clean database lint');
