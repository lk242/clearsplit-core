-- Fund close-out uses two independent confirmations. The member account is
-- locked and revalidated before the second confirmation creates an immutable
-- contribution/refund transaction.

create table public.fund_settlement_confirmations (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  member_id uuid not null,
  direction text not null check (direction in ('top_up', 'refund')),
  amount bigint not null check (amount > 0),
  status text not null default 'pending' check (status in ('pending', 'completed', 'superseded')),
  member_confirmed_at timestamptz,
  member_confirmed_by uuid references auth.users(id),
  responsible_confirmed_at timestamptz,
  responsible_confirmed_by uuid references auth.users(id),
  completed_at timestamptz,
  transaction_id uuid references public.fund_transactions(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fund_settlement_member_same_group_fk
    foreign key (member_id, group_id)
    references public.members(id, group_id) on delete cascade,
  constraint fund_settlement_member_confirmation_pair check (
    (member_confirmed_at is null) = (member_confirmed_by is null)
  ),
  constraint fund_settlement_responsible_confirmation_pair check (
    (responsible_confirmed_at is null) = (responsible_confirmed_by is null)
  ),
  constraint fund_settlement_completion_pair check (
    (completed_at is null) = (transaction_id is null)
  )
);

create unique index fund_settlement_one_pending_idx
  on public.fund_settlement_confirmations(group_id, member_id)
  where status = 'pending';

create index fund_settlement_group_status_idx
  on public.fund_settlement_confirmations(group_id, status, created_at desc);

create trigger fund_settlement_confirmations_set_updated_at
before update on public.fund_settlement_confirmations
for each row execute function public.set_updated_at();

create table public.fund_settlement_confirmation_events (
  id bigint generated always as identity primary key,
  confirmation_id uuid not null references public.fund_settlement_confirmations(id) on delete cascade,
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  member_id uuid not null,
  actor_user_id uuid not null references auth.users(id),
  actor_role text not null check (actor_role in ('member', 'responsible')),
  action text not null check (action in ('confirm', 'revoke', 'supersede', 'complete')),
  created_at timestamptz not null default now(),
  constraint fund_settlement_event_member_same_group_fk
    foreign key (member_id, group_id)
    references public.members(id, group_id) on delete cascade
);

create index fund_settlement_events_confirmation_idx
  on public.fund_settlement_confirmation_events(confirmation_id, created_at);

alter table public.fund_settlement_confirmations enable row level security;
alter table public.fund_settlement_confirmation_events enable row level security;
revoke all on public.fund_settlement_confirmations from public, anon, authenticated;
revoke all on public.fund_settlement_confirmation_events from public, anon, authenticated;

create or replace function public.get_group_fund(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  current_member_id uuid;
  fund_record public.group_funds;
begin
  if current_user_id is null or not public.is_group_member(p_group_id) then
    raise exception 'fund access denied' using errcode = '42501';
  end if;

  select id into current_member_id
  from public.members
  where group_id = p_group_id and user_id = current_user_id;

  select * into fund_record from public.group_funds where group_id = p_group_id;
  if not found then return jsonb_build_object('configured', false); end if;

  return jsonb_build_object(
    'configured', true,
    'balance', fund_record.balance,
    'version', fund_record.version,
    'configuredAt', fund_record.configured_at,
    'currentMemberId', current_member_id,
    'accounts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'memberId', a.member_id,
        'name', m.display_name,
        'color', m.color,
        'avatarUrl', m.avatar_url,
        'balance', a.balance,
        'contributedTotal', a.contributed_total,
        'consumedTotal', a.consumed_total,
        'refundedTotal', a.refunded_total
      ) order by m.created_at, m.id)
      from public.fund_member_accounts a
      join public.members m on m.id = a.member_id and m.group_id = a.group_id
      where a.group_id = p_group_id
    ), '[]'::jsonb),
    'settlements', coalesce((
      select jsonb_agg(jsonb_build_object(
        'memberId', a.member_id,
        'direction', case when a.balance < 0 then 'top_up' else 'refund' end,
        'amount', abs(a.balance),
        'memberConfirmedAt', current_confirmation.member_confirmed_at,
        'responsibleConfirmedAt', current_confirmation.responsible_confirmed_at,
        'hasStaleConfirmation', exists (
          select 1
          from public.fund_settlement_confirmations stale
          where stale.group_id = a.group_id
            and stale.member_id = a.member_id
            and stale.status = 'pending'
            and (stale.direction <> case when a.balance < 0 then 'top_up' else 'refund' end
              or stale.amount <> abs(a.balance))
            and (stale.member_confirmed_at is not null or stale.responsible_confirmed_at is not null)
        )
      ) order by m.created_at, m.id)
      from public.fund_member_accounts a
      join public.members m on m.id = a.member_id and m.group_id = a.group_id
      left join lateral (
        select confirmation.member_confirmed_at, confirmation.responsible_confirmed_at
        from public.fund_settlement_confirmations confirmation
        where confirmation.group_id = a.group_id
          and confirmation.member_id = a.member_id
          and confirmation.status = 'pending'
          and confirmation.direction = case when a.balance < 0 then 'top_up' else 'refund' end
          and confirmation.amount = abs(a.balance)
        limit 1
      ) current_confirmation on true
      where a.group_id = p_group_id and a.balance <> 0
    ), '[]'::jsonb),
    'transactions', coalesce((
      select jsonb_agg(transaction_json order by effective_date desc, created_at desc)
      from (
        select t.effective_date, t.created_at, jsonb_build_object(
          'id', t.id,
          'type', t.transaction_type,
          'title', t.title,
          'amountDelta', t.amount_delta,
          'balanceAfter', t.balance_after,
          'effectiveDate', t.effective_date,
          'note', t.note,
          'createdAt', t.created_at,
          'lines', coalesce((
            select jsonb_agg(jsonb_build_object('memberId', l.member_id, 'amountDelta', l.amount_delta) order by m.created_at, m.id)
            from public.fund_transaction_lines l
            join public.members m on m.id = l.member_id and m.group_id = l.group_id
            where l.transaction_id = t.id
          ), '[]'::jsonb)
        ) as transaction_json
        from public.fund_transactions t where t.group_id = p_group_id
        order by t.effective_date desc, t.created_at desc limit 50
      ) recent
    ), '[]'::jsonb)
  );
end;
$$;

create function public.record_group_fund_settlement_confirmation(
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
  member_name text;
  settlement_direction text;
  settlement_amount bigint;
  confirmation_record public.fund_settlement_confirmations;
  created_transaction_id uuid;
  state_changed boolean := false;
begin
  if current_user_id is null or p_actor_role not in ('member', 'responsible') then
    raise exception 'invalid fund settlement confirmation' using errcode = '22023';
  end if;

  select id into current_member_id
  from public.members
  where group_id = p_group_id and user_id = current_user_id;

  if p_actor_role = 'member' and current_member_id is distinct from p_member_id then
    raise exception 'member confirmation permission required' using errcode = '42501';
  end if;
  if p_actor_role = 'responsible' and not public.is_group_owner(p_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;

  select * into fund_record
  from public.group_funds
  where group_id = p_group_id
  for update;
  if not found then raise exception 'group fund is not configured' using errcode = '23514'; end if;

  select * into account_record
  from public.fund_member_accounts
  where group_id = p_group_id and member_id = p_member_id
  for update;
  if not found or account_record.balance = 0 then
    raise exception 'member has no fund settlement amount' using errcode = '23514';
  end if;

  select display_name into member_name
  from public.members
  where group_id = p_group_id and id = p_member_id;

  settlement_direction := case when account_record.balance < 0 then 'top_up' else 'refund' end;
  settlement_amount := abs(account_record.balance);

  for confirmation_record in
    select * from public.fund_settlement_confirmations
    where group_id = p_group_id and member_id = p_member_id and status = 'pending'
      and (direction <> settlement_direction or amount <> settlement_amount)
    for update
  loop
    update public.fund_settlement_confirmations
    set status = 'superseded'
    where id = confirmation_record.id;
    insert into public.fund_settlement_confirmation_events (
      confirmation_id, group_id, member_id, actor_user_id, actor_role, action
    ) values (
      confirmation_record.id, p_group_id, p_member_id, current_user_id, p_actor_role, 'supersede'
    );
  end loop;

  select * into confirmation_record
  from public.fund_settlement_confirmations
  where group_id = p_group_id and member_id = p_member_id and status = 'pending'
    and direction = settlement_direction and amount = settlement_amount
  for update;

  if not found then
    insert into public.fund_settlement_confirmations (
      group_id, member_id, direction, amount
    ) values (
      p_group_id, p_member_id, settlement_direction, settlement_amount
    ) returning * into confirmation_record;
  end if;

  if p_actor_role = 'member' then
    if p_confirm and confirmation_record.member_confirmed_at is null then
      update public.fund_settlement_confirmations
      set member_confirmed_at = now(), member_confirmed_by = current_user_id
      where id = confirmation_record.id
      returning * into confirmation_record;
      state_changed := true;
    elsif not p_confirm and confirmation_record.member_confirmed_at is not null then
      update public.fund_settlement_confirmations
      set member_confirmed_at = null, member_confirmed_by = null
      where id = confirmation_record.id
      returning * into confirmation_record;
      state_changed := true;
    end if;
  else
    if p_confirm and confirmation_record.responsible_confirmed_at is null then
      update public.fund_settlement_confirmations
      set responsible_confirmed_at = now(), responsible_confirmed_by = current_user_id
      where id = confirmation_record.id
      returning * into confirmation_record;
      state_changed := true;
    elsif not p_confirm and confirmation_record.responsible_confirmed_at is not null then
      update public.fund_settlement_confirmations
      set responsible_confirmed_at = null, responsible_confirmed_by = null
      where id = confirmation_record.id
      returning * into confirmation_record;
      state_changed := true;
    end if;
  end if;

  if state_changed then
    insert into public.fund_settlement_confirmation_events (
      confirmation_id, group_id, member_id, actor_user_id, actor_role, action
    ) values (
      confirmation_record.id, p_group_id, p_member_id, current_user_id, p_actor_role,
      case when p_confirm then 'confirm' else 'revoke' end
    );
  end if;

  if confirmation_record.member_confirmed_at is not null
    and confirmation_record.responsible_confirmed_at is not null then
    if settlement_direction = 'refund' and fund_record.balance < settlement_amount then
      raise exception 'fund cash is insufficient; complete required top-ups first' using errcode = '23514';
    end if;

    if settlement_direction = 'top_up' then
      update public.group_funds
      set balance = balance + settlement_amount, version = version + 1
      where group_id = p_group_id;
      update public.fund_member_accounts
      set balance = balance + settlement_amount,
          contributed_total = contributed_total + settlement_amount
      where group_id = p_group_id and member_id = p_member_id;
      insert into public.fund_transactions (
        group_id, transaction_type, title, amount_delta, balance_after,
        effective_date, note, created_by
      ) values (
        p_group_id, 'contribution', member_name || ' 公費補繳', settlement_amount,
        fund_record.balance + settlement_amount, current_date, '成員與帳務負責人雙向確認', current_user_id
      ) returning id into created_transaction_id;
      insert into public.fund_transaction_lines (transaction_id, group_id, member_id, amount_delta)
      values (created_transaction_id, p_group_id, p_member_id, settlement_amount);
    else
      update public.group_funds
      set balance = balance - settlement_amount, version = version + 1
      where group_id = p_group_id;
      update public.fund_member_accounts
      set balance = balance - settlement_amount,
          refunded_total = refunded_total + settlement_amount
      where group_id = p_group_id and member_id = p_member_id;
      insert into public.fund_transactions (
        group_id, transaction_type, title, amount_delta, balance_after,
        effective_date, note, created_by
      ) values (
        p_group_id, 'refund', member_name || ' 公費退款', -settlement_amount,
        fund_record.balance - settlement_amount, current_date, '成員與帳務負責人雙向確認', current_user_id
      ) returning id into created_transaction_id;
      insert into public.fund_transaction_lines (transaction_id, group_id, member_id, amount_delta)
      values (created_transaction_id, p_group_id, p_member_id, -settlement_amount);
    end if;

    update public.fund_settlement_confirmations
    set status = 'completed', completed_at = now(), transaction_id = created_transaction_id
    where id = confirmation_record.id;
    insert into public.fund_settlement_confirmation_events (
      confirmation_id, group_id, member_id, actor_user_id, actor_role, action
    ) values (
      confirmation_record.id, p_group_id, p_member_id, current_user_id, p_actor_role, 'complete'
    );
  end if;

  return public.get_group_fund(p_group_id);
end;
$$;

revoke all on function public.record_group_fund_settlement_confirmation(uuid, uuid, text, boolean)
  from public, anon;
grant execute on function public.record_group_fund_settlement_confirmation(uuid, uuid, text, boolean)
  to authenticated;
