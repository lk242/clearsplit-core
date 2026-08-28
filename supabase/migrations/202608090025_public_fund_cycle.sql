-- Public-fund rules are server owned: every active member participates and the
-- expense is always split equally. Personal advances remain fund liabilities.

alter table public.group_funds
  drop constraint if exists group_funds_balance_check;
alter table public.fund_transactions
  drop constraint if exists fund_transactions_balance_after_check;

alter table public.group_funds
  add column status text not null default 'active'
    check (status in ('active', 'closing', 'closed')),
  add column closing_started_at timestamptz,
  add column closed_at timestamptz,
  add constraint group_funds_cycle_state_check check (
    (status = 'active' and closing_started_at is null and closed_at is null)
    or (status = 'closing' and closing_started_at is not null and closed_at is null)
    or (status = 'closed' and closing_started_at is not null and closed_at is not null)
  );

create table public.fund_advances (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  transaction_id uuid not null unique references public.fund_transactions(id) on delete cascade,
  member_id uuid not null,
  amount bigint not null check (amount > 0),
  status text not null default 'open' check (status in ('open', 'completed')),
  member_confirmed_at timestamptz,
  member_confirmed_by uuid references auth.users(id),
  responsible_confirmed_at timestamptz,
  responsible_confirmed_by uuid references auth.users(id),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fund_advance_member_same_group_fk
    foreign key (member_id, group_id)
    references public.members(id, group_id),
  constraint fund_advance_member_confirmation_pair check (
    (member_confirmed_at is null) = (member_confirmed_by is null)
  ),
  constraint fund_advance_responsible_confirmation_pair check (
    (responsible_confirmed_at is null) = (responsible_confirmed_by is null)
  ),
  constraint fund_advance_completion_state check (
    (status = 'open' and completed_at is null)
    or (status = 'completed' and completed_at is not null)
  )
);

create index fund_advances_group_status_idx
  on public.fund_advances(group_id, status, created_at desc);
create trigger fund_advances_set_updated_at
before update on public.fund_advances
for each row execute function public.set_updated_at();

create table public.fund_advance_confirmation_events (
  id bigint generated always as identity primary key,
  advance_id uuid not null references public.fund_advances(id) on delete cascade,
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  actor_user_id uuid not null references auth.users(id),
  actor_role text not null check (actor_role in ('member', 'responsible')),
  action text not null check (action in ('confirm', 'revoke', 'complete')),
  created_at timestamptz not null default now()
);

alter table public.fund_advances enable row level security;
alter table public.fund_advance_confirmation_events enable row level security;
revoke all on public.fund_advances from public, anon, authenticated;
revoke all on public.fund_advance_confirmation_events from public, anon, authenticated;

create function public.fund_available_cash(p_group_id uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select fund.balance + coalesce((
    select sum(advance.amount)
    from public.fund_advances advance
    where advance.group_id = fund.group_id and advance.status = 'open'
  ), 0)
  from public.group_funds fund
  where fund.group_id = p_group_id;
$$;

revoke all on function public.fund_available_cash(uuid) from public, anon, authenticated;

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
  available_cash bigint;
begin
  if current_user_id is null or not public.is_group_member(p_group_id) then
    raise exception 'fund access denied' using errcode = '42501';
  end if;
  select id into current_member_id
  from public.members
  where group_id = p_group_id and user_id = current_user_id;
  select * into fund_record from public.group_funds where group_id = p_group_id;
  if not found then return jsonb_build_object('configured', false); end if;
  available_cash := public.fund_available_cash(p_group_id);

  return jsonb_build_object(
    'configured', true,
    'balance', available_cash,
    'netBalance', fund_record.balance,
    'version', fund_record.version,
    'status', fund_record.status,
    'configuredAt', fund_record.configured_at,
    'closingStartedAt', fund_record.closing_started_at,
    'closedAt', fund_record.closed_at,
    'currentMemberId', current_member_id,
    'isOwner', public.is_group_owner(p_group_id),
    'accounts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'memberId', account.member_id,
        'name', member.display_name,
        'color', member.color,
        'avatarUrl', member.avatar_url,
        'balance', account.balance,
        'contributedTotal', account.contributed_total,
        'consumedTotal', account.consumed_total,
        'refundedTotal', account.refunded_total
      ) order by member.created_at, member.id)
      from public.fund_member_accounts account
      join public.members member
        on member.id = account.member_id and member.group_id = account.group_id
      where account.group_id = p_group_id
    ), '[]'::jsonb),
    'advances', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', advance.id,
        'transactionId', advance.transaction_id,
        'memberId', advance.member_id,
        'memberName', member.display_name,
        'amount', advance.amount,
        'status', advance.status,
        'memberConfirmedAt', advance.member_confirmed_at,
        'responsibleConfirmedAt', advance.responsible_confirmed_at,
        'completedAt', advance.completed_at,
        'createdAt', advance.created_at
      ) order by (advance.status = 'open') desc, advance.created_at desc)
      from public.fund_advances advance
      join public.members member
        on member.id = advance.member_id and member.group_id = advance.group_id
      where advance.group_id = p_group_id
    ), '[]'::jsonb),
    'settlements', coalesce((
      select jsonb_agg(jsonb_build_object(
        'memberId', account.member_id,
        'direction', case when account.balance < 0 then 'top_up' else 'refund' end,
        'amount', abs(account.balance),
        'memberConfirmedAt', current_confirmation.member_confirmed_at,
        'responsibleConfirmedAt', current_confirmation.responsible_confirmed_at,
        'hasStaleConfirmation', exists (
          select 1
          from public.fund_settlement_confirmations stale
          where stale.group_id = account.group_id
            and stale.member_id = account.member_id
            and stale.status = 'pending'
            and (stale.direction <> case when account.balance < 0 then 'top_up' else 'refund' end
              or stale.amount <> abs(account.balance))
            and (stale.member_confirmed_at is not null or stale.responsible_confirmed_at is not null)
        )
      ) order by member.created_at, member.id)
      from public.fund_member_accounts account
      join public.members member
        on member.id = account.member_id and member.group_id = account.group_id
      left join lateral (
        select confirmation.member_confirmed_at, confirmation.responsible_confirmed_at
        from public.fund_settlement_confirmations confirmation
        where confirmation.group_id = account.group_id
          and confirmation.member_id = account.member_id
          and confirmation.status = 'pending'
          and confirmation.direction = case when account.balance < 0 then 'top_up' else 'refund' end
          and confirmation.amount = abs(account.balance)
        limit 1
      ) current_confirmation on true
      where account.group_id = p_group_id and account.balance <> 0
    ), '[]'::jsonb),
    'transactions', coalesce((
      select jsonb_agg(transaction_json order by effective_date desc, created_at desc)
      from (
        select transaction.effective_date, transaction.created_at, jsonb_build_object(
          'id', transaction.id,
          'type', transaction.transaction_type,
          'title', transaction.title,
          'amountDelta', transaction.amount_delta,
          'balanceAfter', transaction.balance_after,
          'effectiveDate', transaction.effective_date,
          'note', transaction.note,
          'createdAt', transaction.created_at,
          'lines', coalesce((
            select jsonb_agg(jsonb_build_object(
              'memberId', line.member_id,
              'amountDelta', line.amount_delta
            ) order by member.created_at, member.id)
            from public.fund_transaction_lines line
            join public.members member
              on member.id = line.member_id and member.group_id = line.group_id
            where line.transaction_id = transaction.id
          ), '[]'::jsonb)
        ) transaction_json
        from public.fund_transactions transaction
        where transaction.group_id = p_group_id
        order by transaction.effective_date desc, transaction.created_at desc
        limit 50
      ) recent
    ), '[]'::jsonb)
  );
end;
$$;

create function public.record_group_fund_expense_v2(
  p_group_id uuid,
  p_title text,
  p_amount bigint,
  p_effective_date date,
  p_note text default null,
  p_advance_member_id uuid default null,
  p_use_available_fund boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  fund_record public.group_funds;
  available_cash bigint;
  advance_amount bigint;
  member_ids uuid[];
  member_count integer;
  member_index integer := 1;
  expense_count integer;
  remainder_offset integer;
  base_share bigint;
  remainder bigint;
  share_amount bigint;
  created_transaction_id uuid;
begin
  if current_user_id is null or not public.is_group_member(p_group_id) then
    raise exception 'fund access denied' using errcode = '42501';
  end if;
  if p_title is null or char_length(trim(p_title)) not between 1 and 120
    or p_amount is null or p_amount <= 0 or p_amount > 999999999
    or p_effective_date is null or char_length(coalesce(trim(p_note), '')) > 1000 then
    raise exception 'invalid fund expense' using errcode = '22023';
  end if;

  select * into fund_record
  from public.group_funds
  where group_id = p_group_id
  for update;
  if not found or fund_record.status <> 'active' then
    raise exception 'group fund is not accepting expenses' using errcode = '23514';
  end if;

  insert into public.fund_member_accounts (group_id, member_id, balance)
  select p_group_id, member.id, 0
  from public.members member
  where member.group_id = p_group_id
  on conflict (group_id, member_id) do nothing;

  select array_agg(member.id order by member.created_at, member.id)
  into member_ids
  from public.members member
  where member.group_id = p_group_id;
  member_count := cardinality(member_ids);
  if member_count is null or member_count < 1 then
    raise exception 'fund requires members' using errcode = '23514';
  end if;

  available_cash := public.fund_available_cash(p_group_id);
  advance_amount := p_amount - case
    when p_use_available_fund then least(greatest(available_cash, 0), p_amount)
    else 0
  end;
  if advance_amount > 0 and (
    p_advance_member_id is null or not exists (
      select 1 from public.members
      where group_id = p_group_id and id = p_advance_member_id
    )
  ) then
    raise exception 'fund advance member is required' using errcode = '23514';
  end if;

  update public.group_funds
  set balance = balance - p_amount, version = version + 1
  where group_id = p_group_id;
  insert into public.fund_transactions (
    group_id, transaction_type, title, amount_delta, balance_after,
    effective_date, note, created_by
  ) values (
    p_group_id, 'expense', trim(p_title), -p_amount,
    fund_record.balance - p_amount, p_effective_date,
    nullif(trim(coalesce(p_note, '')), ''), current_user_id
  ) returning id into created_transaction_id;

  select count(*) into expense_count
  from public.fund_transactions
  where group_id = p_group_id and transaction_type = 'expense'
    and id <> created_transaction_id;
  remainder_offset := expense_count % member_count;
  base_share := p_amount / member_count;
  remainder := p_amount % member_count;

  while member_index <= member_count loop
    share_amount := base_share + case
      when mod(member_index - 1 - remainder_offset + member_count, member_count) < remainder then 1
      else 0
    end;
    update public.fund_member_accounts
    set balance = balance - share_amount,
        consumed_total = consumed_total + share_amount
    where group_id = p_group_id and member_id = member_ids[member_index];
    if share_amount <> 0 then
      insert into public.fund_transaction_lines (
        transaction_id, group_id, member_id, amount_delta
      ) values (
        created_transaction_id, p_group_id, member_ids[member_index], -share_amount
      );
    end if;
    member_index := member_index + 1;
  end loop;

  if advance_amount > 0 then
    insert into public.fund_advances (
      group_id, transaction_id, member_id, amount
    ) values (
      p_group_id, created_transaction_id, p_advance_member_id, advance_amount
    );
  end if;
  return public.get_group_fund(p_group_id);
end;
$$;

create function public.create_group_fund_collection_round_v2(
  p_group_id uuid,
  p_title text,
  p_amount_per_member bigint,
  p_effective_date date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  fund_record public.group_funds;
  round_record public.fund_collection_rounds;
  member_record record;
  member_count integer;
begin
  if current_user_id is null or not public.is_group_owner(p_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;
  select * into fund_record
  from public.group_funds
  where group_id = p_group_id
  for update;
  if not found or fund_record.status <> 'active' then
    raise exception 'group fund is not accepting collections' using errcode = '23514';
  end if;
  if p_title is null or char_length(trim(p_title)) not between 1 and 120
    or p_amount_per_member is null or p_amount_per_member <= 0
    or p_amount_per_member > 999999999 or p_effective_date is null then
    raise exception 'invalid fund collection round' using errcode = '22023';
  end if;
  select count(*) into member_count from public.members where group_id = p_group_id;
  if member_count < 1 or member_count > 50 then
    raise exception 'invalid fund collection members' using errcode = '23514';
  end if;

  insert into public.fund_member_accounts (group_id, member_id, balance)
  select p_group_id, member.id, 0
  from public.members member
  where member.group_id = p_group_id
  on conflict (group_id, member_id) do nothing;

  insert into public.fund_collection_rounds (
    group_id, title, amount_per_member, effective_date, created_by
  ) values (
    p_group_id, trim(p_title), p_amount_per_member, p_effective_date, current_user_id
  ) returning * into round_record;

  for member_record in
    select id from public.members
    where group_id = p_group_id
    order by created_at, id
  loop
    insert into public.fund_collection_entries (
      round_id, group_id, member_id, amount
    ) values (
      round_record.id, p_group_id, member_record.id, p_amount_per_member
    );
  end loop;
  insert into public.fund_collection_round_events (
    round_id, group_id, actor_user_id, action
  ) values (
    round_record.id, p_group_id, current_user_id, 'create'
  );
  return public.get_group_fund_collections(p_group_id);
end;
$$;

create function public.start_group_fund_closeout(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  fund_record public.group_funds;
begin
  if (select auth.uid()) is null or not public.is_group_owner(p_group_id) then
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
  update public.group_funds
  set status = 'closing', closing_started_at = now(), version = version + 1
  where group_id = p_group_id and status = 'active';
  return public.get_group_fund(p_group_id);
end;
$$;

create function public.complete_group_fund_closeout(p_group_id uuid)
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
      select 1 from public.fund_advances
      where group_id = p_group_id and status = 'open'
    ) or exists (
      select 1 from public.fund_member_accounts
      where group_id = p_group_id and balance <> 0
    ) then
    raise exception 'fund closeout still has pending balances' using errcode = '23514';
  end if;
  update public.group_funds
  set status = 'closed', closed_at = now(), version = version + 1
  where group_id = p_group_id and status = 'closing';
  if not found then raise exception 'group fund is not closing' using errcode = '23514'; end if;
  return public.get_group_fund(p_group_id);
end;
$$;

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
declare
  current_user_id uuid := (select auth.uid());
  current_member_id uuid;
  fund_record public.group_funds;
  advance_record public.fund_advances;
  state_changed boolean := false;
begin
  if current_user_id is null or p_actor_role not in ('member', 'responsible') then
    raise exception 'invalid fund advance confirmation' using errcode = '22023';
  end if;
  select id into current_member_id
  from public.members
  where group_id = p_group_id and user_id = current_user_id;
  select * into fund_record
  from public.group_funds
  where group_id = p_group_id
  for update;
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
    if public.fund_available_cash(p_group_id) < advance_record.amount then
      raise exception 'fund cash is insufficient for advance repayment' using errcode = '23514';
    end if;
    update public.fund_advances
    set status = 'completed', completed_at = now()
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

-- Close-out confirmations are only valid after the responsible member freezes
-- normal spending and collection activity.
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
  select * into account_record from public.fund_member_accounts
  where group_id = p_group_id and member_id = p_member_id for update;
  if not found or account_record.balance = 0 then
    raise exception 'member has no fund settlement amount' using errcode = '23514';
  end if;
  select display_name into member_name from public.members
  where group_id = p_group_id and id = p_member_id;
  settlement_direction := case when account_record.balance < 0 then 'top_up' else 'refund' end;
  settlement_amount := abs(account_record.balance);

  for confirmation_record in
    select * from public.fund_settlement_confirmations
    where group_id = p_group_id and member_id = p_member_id and status = 'pending'
      and (direction <> settlement_direction or amount <> settlement_amount)
    for update
  loop
    update public.fund_settlement_confirmations set status = 'superseded'
    where id = confirmation_record.id;
    insert into public.fund_settlement_confirmation_events (
      confirmation_id, group_id, member_id, actor_user_id, actor_role, action
    ) values (
      confirmation_record.id, p_group_id, p_member_id, current_user_id,
      p_actor_role, 'supersede'
    );
  end loop;

  select * into confirmation_record from public.fund_settlement_confirmations
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
    if settlement_direction = 'refund' and exists (
      select 1 from public.fund_advances
      where group_id = p_group_id and status = 'open'
    ) then
      raise exception 'complete fund advances before refunds' using errcode = '23514';
    end if;
    if settlement_direction = 'refund'
      and public.fund_available_cash(p_group_id) < settlement_amount then
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
        fund_record.balance + settlement_amount, current_date,
        '成員與帳務負責人雙向確認', current_user_id
      ) returning id into created_transaction_id;
      insert into public.fund_transaction_lines (
        transaction_id, group_id, member_id, amount_delta
      ) values (
        created_transaction_id, p_group_id, p_member_id, settlement_amount
      );
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
        fund_record.balance - settlement_amount, current_date,
        '成員與帳務負責人雙向確認', current_user_id
      ) returning id into created_transaction_id;
      insert into public.fund_transaction_lines (
        transaction_id, group_id, member_id, amount_delta
      ) values (
        created_transaction_id, p_group_id, p_member_id, -settlement_amount
      );
    end if;

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

-- Retire entry points that allowed a caller-supplied subset of fund members.
revoke execute on function public.record_group_fund_expense(
  uuid, text, bigint, uuid[], date, text
) from authenticated;
revoke execute on function public.create_group_fund_collection_round(
  uuid, text, bigint, uuid[], date
) from authenticated;
revoke execute on function public.record_group_fund_contribution(
  uuid, uuid, bigint, date, text
) from authenticated;

revoke all on function public.record_group_fund_expense_v2(
  uuid, text, bigint, date, text, uuid, boolean
) from public, anon;
revoke all on function public.create_group_fund_collection_round_v2(
  uuid, text, bigint, date
) from public, anon;
revoke all on function public.start_group_fund_closeout(uuid) from public, anon;
revoke all on function public.complete_group_fund_closeout(uuid) from public, anon;
revoke all on function public.record_group_fund_advance_confirmation(
  uuid, uuid, text, boolean
) from public, anon;

grant execute on function public.record_group_fund_expense_v2(
  uuid, text, bigint, date, text, uuid, boolean
) to authenticated;
grant execute on function public.create_group_fund_collection_round_v2(
  uuid, text, bigint, date
) to authenticated;
grant execute on function public.start_group_fund_closeout(uuid) to authenticated;
grant execute on function public.complete_group_fund_closeout(uuid) to authenticated;
grant execute on function public.record_group_fund_advance_confirmation(
  uuid, uuid, text, boolean
) to authenticated;
