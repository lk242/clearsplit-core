-- Shared group fund with immutable transactions and exact per-member credits.

create type public.fund_transaction_type as enum ('opening', 'contribution', 'expense', 'refund', 'adjustment');

create table public.group_funds (
  group_id uuid primary key references public.ledger_groups(id) on delete cascade,
  balance bigint not null check (balance >= 0),
  version bigint not null default 1 check (version > 0),
  configured_by uuid not null references auth.users(id),
  configured_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.fund_member_accounts (
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  member_id uuid not null,
  balance bigint not null default 0,
  contributed_total bigint not null default 0 check (contributed_total >= 0),
  consumed_total bigint not null default 0 check (consumed_total >= 0),
  refunded_total bigint not null default 0 check (refunded_total >= 0),
  updated_at timestamptz not null default now(),
  primary key (group_id, member_id),
  constraint fund_account_member_fk foreign key (member_id, group_id)
    references public.members(id, group_id) on delete cascade
);

create table public.fund_transactions (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  transaction_type public.fund_transaction_type not null,
  title text not null check (char_length(trim(title)) between 1 and 120),
  amount_delta bigint not null check (amount_delta <> 0),
  balance_after bigint not null check (balance_after >= 0),
  effective_date date not null,
  note text check (note is null or char_length(note) <= 1000),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table public.fund_transaction_lines (
  transaction_id uuid not null references public.fund_transactions(id) on delete cascade,
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  member_id uuid not null,
  amount_delta bigint not null check (amount_delta <> 0),
  primary key (transaction_id, member_id),
  constraint fund_line_member_fk foreign key (member_id, group_id)
    references public.members(id, group_id) on delete cascade
);

create index fund_transactions_group_date_idx on public.fund_transactions(group_id, effective_date desc, created_at desc);
create trigger group_funds_set_updated_at before update on public.group_funds
for each row execute function public.set_updated_at();
create trigger fund_accounts_set_updated_at before update on public.fund_member_accounts
for each row execute function public.set_updated_at();

alter table public.group_funds enable row level security;
alter table public.fund_member_accounts enable row level security;
alter table public.fund_transactions enable row level security;
alter table public.fund_transaction_lines enable row level security;
revoke all on public.group_funds from public, anon, authenticated;
revoke all on public.fund_member_accounts from public, anon, authenticated;
revoke all on public.fund_transactions from public, anon, authenticated;
revoke all on public.fund_transaction_lines from public, anon, authenticated;

create function public.assert_fund_transaction_balanced()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  target_transaction_id uuid := coalesce(new.transaction_id, old.transaction_id);
  expected_delta bigint;
  allocated_delta bigint;
begin
  select amount_delta into expected_delta from public.fund_transactions where id = target_transaction_id;
  if expected_delta is null then return null; end if;
  select coalesce(sum(amount_delta), 0) into allocated_delta
  from public.fund_transaction_lines where transaction_id = target_transaction_id;
  if expected_delta <> allocated_delta then
    raise exception 'fund transaction % is not balanced: lines %, transaction %', target_transaction_id, allocated_delta, expected_delta
      using errcode = '23514';
  end if;
  return null;
end;
$$;

create constraint trigger fund_lines_balance_check
after insert or update or delete on public.fund_transaction_lines
deferrable initially deferred
for each row execute function public.assert_fund_transaction_balanced();

create function public.get_group_fund(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  fund_record public.group_funds;
begin
  if (select auth.uid()) is null or not public.is_group_member(p_group_id) then
    raise exception 'fund access denied' using errcode = '42501';
  end if;
  select * into fund_record from public.group_funds where group_id = p_group_id;
  if not found then return jsonb_build_object('configured', false); end if;

  return jsonb_build_object(
    'configured', true,
    'balance', fund_record.balance,
    'version', fund_record.version,
    'configuredAt', fund_record.configured_at,
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

create function public.initialize_group_fund(
  p_group_id uuid,
  p_opening_balance bigint,
  p_effective_date date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  member_count integer;
  base_credit bigint;
  remainder bigint;
  member_record record;
  member_index integer := 0;
  allocated_credit bigint;
  transaction_id uuid;
begin
  if current_user_id is null or not public.is_group_owner(p_group_id) then
    raise exception 'group owner permission required' using errcode = '42501';
  end if;
  if p_opening_balance <= 0 or p_opening_balance > 999999999 then
    raise exception 'invalid opening balance' using errcode = '22023';
  end if;
  if exists (select 1 from public.group_funds where group_id = p_group_id) then
    raise exception 'group fund is already configured' using errcode = '23505';
  end if;
  select count(*) into member_count from public.members where group_id = p_group_id;
  if member_count < 1 then raise exception 'fund requires at least one member' using errcode = '23514'; end if;

  insert into public.group_funds (group_id, balance, configured_by)
  values (p_group_id, p_opening_balance, current_user_id);
  insert into public.fund_transactions (
    group_id, transaction_type, title, amount_delta, balance_after, effective_date, note, created_by
  ) values (
    p_group_id, 'opening', '期初公費餘額', p_opening_balance, p_opening_balance,
    p_effective_date, '依現有成員平均分配', current_user_id
  ) returning id into transaction_id;

  base_credit := p_opening_balance / member_count;
  remainder := p_opening_balance % member_count;
  for member_record in select id from public.members where group_id = p_group_id order by created_at, id
  loop
    allocated_credit := base_credit + case when member_index < remainder then 1 else 0 end;
    insert into public.fund_member_accounts (group_id, member_id, balance)
    values (p_group_id, member_record.id, allocated_credit);
    if allocated_credit <> 0 then
      insert into public.fund_transaction_lines (transaction_id, group_id, member_id, amount_delta)
      values (transaction_id, p_group_id, member_record.id, allocated_credit);
    end if;
    member_index := member_index + 1;
  end loop;
  return public.get_group_fund(p_group_id);
end;
$$;

create function public.record_group_fund_expense(
  p_group_id uuid,
  p_title text,
  p_amount bigint,
  p_participant_ids uuid[],
  p_effective_date date,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  fund_record public.group_funds;
  participant_count integer;
  base_share bigint;
  remainder bigint;
  target_member_id uuid;
  member_index integer := 0;
  share_amount bigint;
  transaction_id uuid;
begin
  if current_user_id is null or not public.is_group_member(p_group_id) then
    raise exception 'fund access denied' using errcode = '42501';
  end if;
  if char_length(trim(p_title)) not between 1 and 120 or p_amount <= 0 then
    raise exception 'invalid fund expense' using errcode = '22023';
  end if;
  participant_count := cardinality(p_participant_ids);
  if participant_count < 1 or (select count(*) from public.members where group_id = p_group_id and id = any(p_participant_ids)) <> participant_count then
    raise exception 'invalid fund participants' using errcode = '23514';
  end if;
  select * into fund_record from public.group_funds where group_id = p_group_id for update;
  if not found or fund_record.balance < p_amount then
    raise exception 'insufficient group fund balance' using errcode = '23514';
  end if;

  update public.group_funds set balance = balance - p_amount, version = version + 1 where group_id = p_group_id;
  insert into public.fund_transactions (
    group_id, transaction_type, title, amount_delta, balance_after, effective_date, note, created_by
  ) values (
    p_group_id, 'expense', trim(p_title), -p_amount, fund_record.balance - p_amount,
    p_effective_date, nullif(trim(p_note), ''), current_user_id
  ) returning id into transaction_id;

  base_share := p_amount / participant_count;
  remainder := p_amount % participant_count;
  foreach target_member_id in array p_participant_ids loop
    share_amount := base_share + case when member_index < remainder then 1 else 0 end;
    update public.fund_member_accounts
      set balance = balance - share_amount, consumed_total = consumed_total + share_amount
      where group_id = p_group_id and fund_member_accounts.member_id = target_member_id;
    if share_amount <> 0 then
      insert into public.fund_transaction_lines (transaction_id, group_id, member_id, amount_delta)
      values (transaction_id, p_group_id, target_member_id, -share_amount);
    end if;
    member_index := member_index + 1;
  end loop;
  return public.get_group_fund(p_group_id);
end;
$$;

create function public.record_group_fund_contribution(
  p_group_id uuid,
  p_member_id uuid,
  p_amount bigint,
  p_effective_date date,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  fund_record public.group_funds;
  member_name text;
  transaction_id uuid;
begin
  if current_user_id is null or not public.is_group_owner(p_group_id) then
    raise exception 'group owner permission required' using errcode = '42501';
  end if;
  if p_amount <= 0 then raise exception 'invalid contribution amount' using errcode = '22023'; end if;
  select display_name into member_name from public.members where group_id = p_group_id and id = p_member_id;
  if member_name is null then raise exception 'member is unavailable' using errcode = '23514'; end if;
  select * into fund_record from public.group_funds where group_id = p_group_id for update;
  if not found then raise exception 'group fund is not configured' using errcode = '23514'; end if;

  update public.group_funds set balance = balance + p_amount, version = version + 1 where group_id = p_group_id;
  update public.fund_member_accounts
    set balance = balance + p_amount, contributed_total = contributed_total + p_amount
    where group_id = p_group_id and member_id = p_member_id;
  insert into public.fund_transactions (
    group_id, transaction_type, title, amount_delta, balance_after, effective_date, note, created_by
  ) values (
    p_group_id, 'contribution', member_name || ' 繳交公費', p_amount,
    fund_record.balance + p_amount, p_effective_date, nullif(trim(p_note), ''), current_user_id
  ) returning id into transaction_id;
  insert into public.fund_transaction_lines (transaction_id, group_id, member_id, amount_delta)
  values (transaction_id, p_group_id, p_member_id, p_amount);
  return public.get_group_fund(p_group_id);
end;
$$;

revoke all on function public.get_group_fund(uuid) from public, anon;
revoke all on function public.initialize_group_fund(uuid, bigint, date) from public, anon;
revoke all on function public.record_group_fund_expense(uuid, text, bigint, uuid[], date, text) from public, anon;
revoke all on function public.record_group_fund_contribution(uuid, uuid, bigint, date, text) from public, anon;
grant execute on function public.get_group_fund(uuid) to authenticated;
grant execute on function public.initialize_group_fund(uuid, bigint, date) to authenticated;
grant execute on function public.record_group_fund_expense(uuid, text, bigint, uuid[], date, text) to authenticated;
grant execute on function public.record_group_fund_contribution(uuid, uuid, bigint, date, text) to authenticated;
