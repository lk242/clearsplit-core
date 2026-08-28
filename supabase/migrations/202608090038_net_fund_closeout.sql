-- Final close-out nets each member's fund-account balance against any unpaid
-- advance. The snapshot is frozen when close-out starts, then posted only
-- after the member and responsible person have independently confirmed it.

alter table public.fund_settlement_confirmations
  add column cycle_number integer,
  add column account_balance bigint,
  add column advance_amount bigint,
  add column advance_offset_amount bigint;

update public.fund_settlement_confirmations confirmation
set cycle_number = coalesce(transaction.cycle_number, 1),
    account_balance = case confirmation.direction
      when 'top_up' then -confirmation.amount else confirmation.amount end,
    advance_amount = 0,
    advance_offset_amount = 0
from public.fund_transactions transaction
where transaction.id = confirmation.transaction_id;

update public.fund_settlement_confirmations confirmation
set cycle_number = 1,
    account_balance = case confirmation.direction
      when 'top_up' then -confirmation.amount else confirmation.amount end,
    advance_amount = 0,
    advance_offset_amount = 0
where confirmation.cycle_number is null;

alter table public.fund_settlement_confirmations
  alter column cycle_number set not null,
  alter column account_balance set not null,
  alter column advance_amount set not null,
  alter column advance_offset_amount set not null,
  add constraint fund_settlement_cycle_number_check check (cycle_number > 0),
  add constraint fund_settlement_advance_amount_check check (advance_amount >= 0),
  add constraint fund_settlement_advance_offset_check check (
    advance_offset_amount >= 0
    and advance_offset_amount <= advance_amount
    and advance_offset_amount <= greatest(-account_balance, 0)
  ),
  drop constraint fund_settlement_confirmations_direction_check,
  add constraint fund_settlement_confirmations_direction_check
    check (direction in ('top_up', 'refund', 'offset')),
  drop constraint fund_settlement_confirmations_amount_check,
  add constraint fund_settlement_confirmations_amount_check check (amount >= 0),
  add constraint fund_settlement_net_amount_check check (
    (account_balance + advance_amount > 0
      and direction = 'refund' and amount = account_balance + advance_amount)
    or (account_balance + advance_amount < 0
      and direction = 'top_up' and amount = -(account_balance + advance_amount))
    or (account_balance + advance_amount = 0
      and direction = 'offset' and amount = 0)
  ),
  drop constraint fund_settlement_completion_pair,
  add constraint fund_settlement_completion_pair check (
    (status = 'completed' and completed_at is not null
      and ((account_balance = 0 and transaction_id is null)
        or (account_balance <> 0 and transaction_id is not null)))
    or (status in ('pending', 'superseded')
      and completed_at is null and transaction_id is null)
  );

alter table public.fund_advance_confirmation_events
  drop constraint fund_advance_confirmation_events_action_check,
  add constraint fund_advance_confirmation_events_action_check
    check (action in ('confirm', 'revoke', 'complete', 'offset', 'closeout'));

alter function public.get_group_fund(uuid) rename to get_group_fund_v37;
revoke all on function public.get_group_fund_v37(uuid)
  from public, anon, authenticated;

create function public.get_group_fund(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
  settlement_items jsonb;
begin
  result := public.get_group_fund_v37(p_group_id);
  if coalesce((result->>'configured')::boolean, false) is false then
    return result;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'memberId', confirmation.member_id,
    'direction', confirmation.direction,
    'amount', confirmation.amount,
    'cashAmount', confirmation.amount,
    'accountBalance', confirmation.account_balance,
    'accountTopUp', greatest(-confirmation.account_balance, 0),
    'accountRefund', greatest(confirmation.account_balance, 0),
    'advanceAmount', confirmation.advance_amount,
    'advanceOffsetAmount', confirmation.advance_offset_amount,
    'memberConfirmedAt', confirmation.member_confirmed_at,
    'responsibleConfirmedAt', confirmation.responsible_confirmed_at,
    'hasStaleConfirmation', false
  ) order by member.created_at, member.id), '[]'::jsonb)
  into settlement_items
  from public.fund_settlement_confirmations confirmation
  join public.members member
    on member.id = confirmation.member_id and member.group_id = confirmation.group_id
  join public.group_funds fund on fund.group_id = confirmation.group_id
  where confirmation.group_id = p_group_id
    and confirmation.cycle_number = fund.cycle_number
    and confirmation.status = 'pending';

  return jsonb_set(result, '{settlements}', settlement_items);
end;
$$;

revoke all on function public.get_group_fund(uuid) from public, anon;
grant execute on function public.get_group_fund(uuid) to authenticated;

create or replace function public.start_group_fund_closeout(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  fund_record public.group_funds;
  stale_confirmation public.fund_settlement_confirmations;
begin
  if current_user_id is null or not public.is_group_owner(p_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;
  select * into fund_record
  from public.group_funds
  where group_id = p_group_id
  for update;
  if not found or fund_record.status <> 'active' then
    raise exception 'group fund is not active' using errcode = '23514';
  end if;
  if exists (
    select 1 from public.fund_collection_rounds
    where group_id = p_group_id and status = 'open'
  ) then
    raise exception 'complete or cancel the open collection first' using errcode = '23514';
  end if;

  for stale_confirmation in
    select * from public.fund_settlement_confirmations
    where group_id = p_group_id and status = 'pending'
    for update
  loop
    update public.fund_settlement_confirmations
    set status = 'superseded'
    where id = stale_confirmation.id;
    insert into public.fund_settlement_confirmation_events (
      confirmation_id, group_id, member_id, actor_user_id, actor_role, action
    ) values (
      stale_confirmation.id, p_group_id, stale_confirmation.member_id,
      current_user_id, 'responsible', 'supersede'
    );
  end loop;

  update public.group_funds
  set status = 'closing', closing_started_at = now(), version = version + 1
  where group_id = p_group_id and status = 'active';

  insert into public.fund_settlement_confirmations (
    group_id, member_id, direction, amount, cycle_number,
    account_balance, advance_amount, advance_offset_amount
  )
  select p_group_id, account.member_id,
    case
      when account.balance + advances.amount > 0 then 'refund'
      when account.balance + advances.amount < 0 then 'top_up'
      else 'offset'
    end,
    abs(account.balance + advances.amount),
    fund_record.cycle_number,
    account.balance,
    advances.amount,
    least(greatest(-account.balance, 0), advances.amount)
  from public.fund_member_accounts account
  left join lateral (
    select coalesce(sum(advance.amount - advance.settled_amount), 0)::bigint as amount
    from public.fund_advances advance
    where advance.group_id = account.group_id
      and advance.member_id = account.member_id
      and advance.status = 'open'
  ) advances on true
  where account.group_id = p_group_id
    and (account.balance <> 0 or advances.amount <> 0);

  return public.get_group_fund(p_group_id);
end;
$$;

create or replace function public.record_group_fund_settlement_confirmation(
  p_group_id uuid,
  p_member_id uuid,
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
  fund_record public.group_funds;
  account_record public.fund_member_accounts;
  confirmation_record public.fund_settlement_confirmations;
  advance_record public.fund_advances;
  current_advance_amount bigint;
  member_name text;
  gross_top_up bigint;
  gross_refund bigint;
  created_transaction_id uuid;
  state_changed boolean := false;
begin
  if current_user_id is null or p_actor_role not in ('member', 'responsible')
    or p_confirm is null then
    raise exception 'invalid fund settlement confirmation' using errcode = '22023';
  end if;
  select id into current_member_id from public.members
  where group_id = p_group_id and user_id = current_user_id;
  if p_actor_role = 'member' and current_member_id is distinct from p_member_id then
    raise exception 'member confirmation permission required' using errcode = '42501';
  end if;
  if p_actor_role = 'responsible' and not public.is_group_owner(p_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;

  select * into fund_record from public.group_funds
  where group_id = p_group_id for update;
  if not found or fund_record.status <> 'closing' then
    raise exception 'group fund is not closing' using errcode = '23514';
  end if;
  select * into confirmation_record
  from public.fund_settlement_confirmations
  where group_id = p_group_id and member_id = p_member_id
    and cycle_number = fund_record.cycle_number and status = 'pending'
  for update;
  if not found then
    raise exception 'member has no pending fund settlement' using errcode = '23514';
  end if;
  select * into account_record from public.fund_member_accounts
  where group_id = p_group_id and member_id = p_member_id for update;
  if not found or account_record.balance <> confirmation_record.account_balance then
    raise exception 'fund closeout snapshot changed' using errcode = '40001';
  end if;
  perform 1 from public.fund_advances
  where group_id = p_group_id and member_id = p_member_id and status = 'open'
  order by created_at, id for update;
  select coalesce(sum(amount - settled_amount), 0)::bigint into current_advance_amount
  from public.fund_advances
  where group_id = p_group_id and member_id = p_member_id and status = 'open';
  if current_advance_amount <> confirmation_record.advance_amount then
    raise exception 'fund closeout advance snapshot changed' using errcode = '40001';
  end if;

  if p_actor_role = 'member' then
    if p_confirm and confirmation_record.member_confirmed_at is null then
      update public.fund_settlement_confirmations
      set member_confirmed_at = now(), member_confirmed_by = current_user_id
      where id = confirmation_record.id returning * into confirmation_record;
      state_changed := true;
    elsif not p_confirm and confirmation_record.member_confirmed_at is not null then
      update public.fund_settlement_confirmations
      set member_confirmed_at = null, member_confirmed_by = null
      where id = confirmation_record.id returning * into confirmation_record;
      state_changed := true;
    end if;
  else
    if p_confirm and confirmation_record.responsible_confirmed_at is null then
      update public.fund_settlement_confirmations
      set responsible_confirmed_at = now(), responsible_confirmed_by = current_user_id
      where id = confirmation_record.id returning * into confirmation_record;
      state_changed := true;
    elsif not p_confirm and confirmation_record.responsible_confirmed_at is not null then
      update public.fund_settlement_confirmations
      set responsible_confirmed_at = null, responsible_confirmed_by = null
      where id = confirmation_record.id returning * into confirmation_record;
      state_changed := true;
    end if;
  end if;
  if state_changed then
    insert into public.fund_settlement_confirmation_events (
      confirmation_id, group_id, member_id, actor_user_id, actor_role, action
    ) values (
      confirmation_record.id, p_group_id, p_member_id, current_user_id,
      p_actor_role, case when p_confirm then 'confirm' else 'revoke' end
    );
  end if;

  if confirmation_record.member_confirmed_at is not null
    and confirmation_record.responsible_confirmed_at is not null then
    if confirmation_record.direction = 'refund'
      and public.fund_available_cash(p_group_id) < confirmation_record.amount then
      raise exception 'fund cash is insufficient; complete required top-ups first' using errcode = '23514';
    end if;

    select display_name into member_name from public.members
    where group_id = p_group_id and id = p_member_id;
    gross_top_up := greatest(-confirmation_record.account_balance, 0);
    gross_refund := greatest(confirmation_record.account_balance, 0);

    if confirmation_record.account_balance < 0 then
      update public.group_funds
      set balance = balance + gross_top_up, version = version + 1
      where group_id = p_group_id;
      update public.fund_member_accounts
      set balance = 0, contributed_total = contributed_total + gross_top_up
      where group_id = p_group_id and member_id = p_member_id;
      insert into public.fund_transactions (
        group_id, transaction_type, title, amount_delta, balance_after,
        effective_date, note, created_by
      ) values (
        p_group_id, 'contribution', member_name || ' 公費結清補繳', gross_top_up,
        fund_record.balance + gross_top_up, current_date,
        '帳戶應補 ' || gross_top_up || '；代墊應收 ' || confirmation_record.advance_amount
          || '；互抵 ' || confirmation_record.advance_offset_amount
          || '；實際' || case confirmation_record.direction
            when 'refund' then '退款 ' when 'top_up' then '收款 ' else '無現金 ' end
          || confirmation_record.amount,
        current_user_id
      ) returning id into created_transaction_id;
      insert into public.fund_transaction_lines (
        transaction_id, group_id, member_id, amount_delta
      ) values (created_transaction_id, p_group_id, p_member_id, gross_top_up);
    elsif confirmation_record.account_balance > 0 then
      update public.group_funds
      set balance = balance - gross_refund, version = version + 1
      where group_id = p_group_id;
      update public.fund_member_accounts
      set balance = 0, refunded_total = refunded_total + gross_refund
      where group_id = p_group_id and member_id = p_member_id;
      insert into public.fund_transactions (
        group_id, transaction_type, title, amount_delta, balance_after,
        effective_date, note, created_by
      ) values (
        p_group_id, 'refund', member_name || ' 公費結清退款', -gross_refund,
        fund_record.balance - gross_refund, current_date,
        '帳戶應退 ' || gross_refund || '；代墊應收 ' || confirmation_record.advance_amount
          || '；實際退款 ' || confirmation_record.amount,
        current_user_id
      ) returning id into created_transaction_id;
      insert into public.fund_transaction_lines (
        transaction_id, group_id, member_id, amount_delta
      ) values (created_transaction_id, p_group_id, p_member_id, -gross_refund);
    else
      update public.fund_member_accounts
      set balance = 0
      where group_id = p_group_id and member_id = p_member_id;
    end if;

    for advance_record in
      select * from public.fund_advances
      where group_id = p_group_id and member_id = p_member_id and status = 'open'
      order by created_at, id for update
    loop
      update public.fund_advances
      set settled_amount = amount, status = 'completed', completed_at = now()
      where id = advance_record.id;
      insert into public.fund_advance_confirmation_events (
        advance_id, group_id, actor_user_id, actor_role, action
      ) values (
        advance_record.id, p_group_id, current_user_id, p_actor_role, 'closeout'
      );
    end loop;

    update public.fund_settlement_confirmations
    set status = 'completed', completed_at = now(), transaction_id = created_transaction_id
    where id = confirmation_record.id;
    insert into public.fund_settlement_confirmation_events (
      confirmation_id, group_id, member_id, actor_user_id, actor_role, action
    ) values (
      confirmation_record.id, p_group_id, p_member_id, current_user_id,
      p_actor_role, 'complete'
    );
  end if;
  return public.get_group_fund(p_group_id);
end;
$$;

create or replace function public.complete_group_fund_closeout(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select auth.uid()) is null or not public.is_group_owner(p_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;
  if exists (
      select 1 from public.fund_settlement_confirmations confirmation
      join public.group_funds fund on fund.group_id = confirmation.group_id
      where confirmation.group_id = p_group_id
        and confirmation.cycle_number = fund.cycle_number
        and confirmation.status = 'pending'
    ) or exists (
      select 1 from public.fund_advances
      where group_id = p_group_id and status = 'open'
    ) or exists (
      select 1 from public.fund_member_accounts
      where group_id = p_group_id and balance <> 0
    ) or coalesce((select balance from public.group_funds where group_id = p_group_id), 1) <> 0 then
    raise exception 'fund closeout still has pending balances' using errcode = '23514';
  end if;
  update public.group_funds
  set status = 'closed', closed_at = now(), version = version + 1
  where group_id = p_group_id and status = 'closing';
  if not found then raise exception 'group fund is not closing' using errcode = '23514'; end if;
  return public.get_group_fund(p_group_id);
end;
$$;

alter function public.record_group_fund_advance_confirmation(uuid, uuid, text, boolean)
  rename to record_group_fund_advance_confirmation_v37;
revoke all on function public.record_group_fund_advance_confirmation_v37(uuid, uuid, text, boolean)
  from public, anon, authenticated;

create function public.record_group_fund_advance_confirmation(
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
begin
  if not exists (
    select 1 from public.group_funds
    where group_id = p_group_id and status = 'active'
  ) then
    raise exception 'fund advances are frozen during closeout' using errcode = '23514';
  end if;
  return public.record_group_fund_advance_confirmation_v37(
    p_group_id, p_advance_id, p_actor_role, p_confirm
  );
end;
$$;

alter function public.reassign_group_fund_advance(uuid, uuid, uuid, uuid)
  rename to reassign_group_fund_advance_v37;
revoke all on function public.reassign_group_fund_advance_v37(uuid, uuid, uuid, uuid)
  from public, anon, authenticated;

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
begin
  if not exists (
    select 1 from public.group_funds
    where group_id = p_group_id and status = 'active'
  ) then
    raise exception 'fund advances are frozen during closeout' using errcode = '23514';
  end if;
  return public.reassign_group_fund_advance_v37(
    p_group_id, p_advance_id, p_expected_member_id, p_new_member_id
  );
end;
$$;

revoke all on function public.record_group_fund_advance_confirmation(uuid, uuid, text, boolean)
  from public, anon;
grant execute on function public.record_group_fund_advance_confirmation(uuid, uuid, text, boolean)
  to authenticated;
revoke all on function public.reassign_group_fund_advance(uuid, uuid, uuid, uuid)
  from public, anon;
grant execute on function public.reassign_group_fund_advance(uuid, uuid, uuid, uuid)
  to authenticated;

insert into public.app_schema_versions (version, name)
values (38, 'net public-fund closeout');
