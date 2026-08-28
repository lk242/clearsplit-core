-- Each trip can collect a fixed amount from a frozen member list. Money enters
-- the fund only after the member and responsible member confirm separately.

create table public.fund_collection_rounds (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  title text not null check (char_length(trim(title)) between 1 and 120),
  amount_per_member bigint not null check (amount_per_member > 0 and amount_per_member <= 999999999),
  effective_date date not null,
  status text not null default 'open' check (status in ('open', 'completed', 'cancelled')),
  created_by uuid not null references auth.users(id),
  completed_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fund_collection_terminal_state check (
    (status = 'open' and completed_at is null and cancelled_at is null)
    or (status = 'completed' and completed_at is not null and cancelled_at is null)
    or (status = 'cancelled' and completed_at is null and cancelled_at is not null)
  )
);

create unique index fund_collection_one_open_round_idx
  on public.fund_collection_rounds(group_id)
  where status = 'open';

create index fund_collection_rounds_group_date_idx
  on public.fund_collection_rounds(group_id, effective_date desc, created_at desc);

create trigger fund_collection_rounds_set_updated_at
before update on public.fund_collection_rounds
for each row execute function public.set_updated_at();

create table public.fund_collection_entries (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null references public.fund_collection_rounds(id) on delete cascade,
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  member_id uuid not null,
  amount bigint not null check (amount > 0),
  status text not null default 'pending' check (status in ('pending', 'completed')),
  member_confirmed_at timestamptz,
  member_confirmed_by uuid references auth.users(id),
  responsible_confirmed_at timestamptz,
  responsible_confirmed_by uuid references auth.users(id),
  completed_at timestamptz,
  transaction_id uuid references public.fund_transactions(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (round_id, member_id),
  constraint fund_collection_entry_member_same_group_fk
    foreign key (member_id, group_id)
    references public.members(id, group_id) on delete cascade,
  constraint fund_collection_entry_member_confirmation_pair check (
    (member_confirmed_at is null) = (member_confirmed_by is null)
  ),
  constraint fund_collection_entry_responsible_confirmation_pair check (
    (responsible_confirmed_at is null) = (responsible_confirmed_by is null)
  ),
  constraint fund_collection_entry_completion_pair check (
    (completed_at is null) = (transaction_id is null)
  )
);

create index fund_collection_entries_round_status_idx
  on public.fund_collection_entries(round_id, status, created_at);

create trigger fund_collection_entries_set_updated_at
before update on public.fund_collection_entries
for each row execute function public.set_updated_at();

create table public.fund_collection_round_events (
  id bigint generated always as identity primary key,
  round_id uuid not null references public.fund_collection_rounds(id) on delete cascade,
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  actor_user_id uuid not null references auth.users(id),
  action text not null check (action in ('create', 'complete', 'cancel')),
  created_at timestamptz not null default now()
);

create table public.fund_collection_confirmation_events (
  id bigint generated always as identity primary key,
  entry_id uuid not null references public.fund_collection_entries(id) on delete cascade,
  round_id uuid not null references public.fund_collection_rounds(id) on delete cascade,
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  member_id uuid not null,
  actor_user_id uuid not null references auth.users(id),
  actor_role text not null check (actor_role in ('member', 'responsible')),
  action text not null check (action in ('confirm', 'revoke', 'complete')),
  created_at timestamptz not null default now(),
  constraint fund_collection_event_member_same_group_fk
    foreign key (member_id, group_id)
    references public.members(id, group_id) on delete cascade
);

alter table public.fund_collection_rounds enable row level security;
alter table public.fund_collection_entries enable row level security;
alter table public.fund_collection_round_events enable row level security;
alter table public.fund_collection_confirmation_events enable row level security;
revoke all on public.fund_collection_rounds from public, anon, authenticated;
revoke all on public.fund_collection_entries from public, anon, authenticated;
revoke all on public.fund_collection_round_events from public, anon, authenticated;
revoke all on public.fund_collection_confirmation_events from public, anon, authenticated;

create or replace function public.initialize_group_fund(
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
  if p_opening_balance < 0 or p_opening_balance > 999999999 then
    raise exception 'invalid opening balance' using errcode = '22023';
  end if;
  if exists (select 1 from public.group_funds where group_id = p_group_id) then
    raise exception 'group fund is already configured' using errcode = '23505';
  end if;
  select count(*) into member_count from public.members where group_id = p_group_id;
  if member_count < 1 then raise exception 'fund requires at least one member' using errcode = '23514'; end if;

  insert into public.group_funds (group_id, balance, configured_by)
  values (p_group_id, p_opening_balance, current_user_id);

  if p_opening_balance > 0 then
    insert into public.fund_transactions (
      group_id, transaction_type, title, amount_delta, balance_after, effective_date, note, created_by
    ) values (
      p_group_id, 'opening', '期初公費餘額', p_opening_balance, p_opening_balance,
      p_effective_date, '依現有成員平均分配', current_user_id
    ) returning id into transaction_id;
  end if;

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

create function public.get_group_fund_collections(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  current_member_id uuid;
begin
  if current_user_id is null or not public.is_group_member(p_group_id) then
    raise exception 'fund collection access denied' using errcode = '42501';
  end if;
  select id into current_member_id
  from public.members
  where group_id = p_group_id and user_id = current_user_id;

  return jsonb_build_object(
    'currentMemberId', current_member_id,
    'rounds', coalesce((
      select jsonb_agg(round_json order by is_open desc, effective_date desc, created_at desc)
      from (
        select round.effective_date, round.created_at, round.status = 'open' as is_open,
          jsonb_build_object(
            'id', round.id,
            'title', round.title,
            'amountPerMember', round.amount_per_member,
            'effectiveDate', round.effective_date,
            'status', round.status,
            'createdAt', round.created_at,
            'completedAt', round.completed_at,
            'entries', coalesce((
              select jsonb_agg(jsonb_build_object(
                'memberId', entry.member_id,
                'name', member.display_name,
                'color', member.color,
                'avatarUrl', member.avatar_url,
                'amount', entry.amount,
                'status', entry.status,
                'memberConfirmedAt', entry.member_confirmed_at,
                'responsibleConfirmedAt', entry.responsible_confirmed_at,
                'completedAt', entry.completed_at
              ) order by member.created_at, member.id)
              from public.fund_collection_entries entry
              join public.members member on member.id = entry.member_id and member.group_id = entry.group_id
              where entry.round_id = round.id
            ), '[]'::jsonb)
          ) as round_json
        from public.fund_collection_rounds round
        where round.group_id = p_group_id and round.status <> 'cancelled'
        order by round.effective_date desc, round.created_at desc
        limit 20
      ) recent_rounds
    ), '[]'::jsonb)
  );
end;
$$;

create function public.create_group_fund_collection_round(
  p_group_id uuid,
  p_title text,
  p_amount_per_member bigint,
  p_member_ids uuid[],
  p_effective_date date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  round_record public.fund_collection_rounds;
  target_member_id uuid;
  member_count integer;
begin
  if current_user_id is null or not public.is_group_owner(p_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;
  if not exists (select 1 from public.group_funds where group_id = p_group_id) then
    raise exception 'group fund is not configured' using errcode = '23514';
  end if;
  if char_length(trim(p_title)) not between 1 and 120
    or p_amount_per_member <= 0 or p_amount_per_member > 999999999 then
    raise exception 'invalid fund collection round' using errcode = '22023';
  end if;
  member_count := cardinality(p_member_ids);
  if member_count < 1 or member_count > 50
    or (select count(distinct id) from public.members where group_id = p_group_id and id = any(p_member_ids)) <> member_count then
    raise exception 'invalid fund collection members' using errcode = '23514';
  end if;

  insert into public.fund_collection_rounds (
    group_id, title, amount_per_member, effective_date, created_by
  ) values (
    p_group_id, trim(p_title), p_amount_per_member, p_effective_date, current_user_id
  ) returning * into round_record;

  foreach target_member_id in array p_member_ids loop
    insert into public.fund_collection_entries (round_id, group_id, member_id, amount)
    values (round_record.id, p_group_id, target_member_id, p_amount_per_member);
  end loop;
  insert into public.fund_collection_round_events (round_id, group_id, actor_user_id, action)
  values (round_record.id, p_group_id, current_user_id, 'create');
  return public.get_group_fund_collections(p_group_id);
end;
$$;

create function public.record_group_fund_collection_confirmation(
  p_group_id uuid,
  p_round_id uuid,
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
  round_record public.fund_collection_rounds;
  entry_record public.fund_collection_entries;
  fund_record public.group_funds;
  member_name text;
  created_transaction_id uuid;
  state_changed boolean := false;
begin
  if current_user_id is null or p_actor_role not in ('member', 'responsible') then
    raise exception 'invalid fund collection confirmation' using errcode = '22023';
  end if;
  select id into current_member_id
  from public.members where group_id = p_group_id and user_id = current_user_id;
  if p_actor_role = 'member' and current_member_id is distinct from p_member_id then
    raise exception 'member confirmation permission required' using errcode = '42501';
  end if;
  if p_actor_role = 'responsible' and not public.is_group_owner(p_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;

  select * into round_record
  from public.fund_collection_rounds
  where id = p_round_id and group_id = p_group_id
  for update;
  if not found or round_record.status <> 'open' then
    raise exception 'fund collection round is not open' using errcode = '23514';
  end if;

  select * into entry_record
  from public.fund_collection_entries
  where round_id = p_round_id and group_id = p_group_id and member_id = p_member_id
  for update;
  if not found or entry_record.status <> 'pending' then
    raise exception 'fund collection entry is not pending' using errcode = '23514';
  end if;

  if p_actor_role = 'member' then
    if p_confirm and entry_record.member_confirmed_at is null then
      update public.fund_collection_entries
      set member_confirmed_at = now(), member_confirmed_by = current_user_id
      where id = entry_record.id returning * into entry_record;
      state_changed := true;
    elsif not p_confirm and entry_record.member_confirmed_at is not null then
      update public.fund_collection_entries
      set member_confirmed_at = null, member_confirmed_by = null
      where id = entry_record.id returning * into entry_record;
      state_changed := true;
    end if;
  else
    if p_confirm and entry_record.responsible_confirmed_at is null then
      update public.fund_collection_entries
      set responsible_confirmed_at = now(), responsible_confirmed_by = current_user_id
      where id = entry_record.id returning * into entry_record;
      state_changed := true;
    elsif not p_confirm and entry_record.responsible_confirmed_at is not null then
      update public.fund_collection_entries
      set responsible_confirmed_at = null, responsible_confirmed_by = null
      where id = entry_record.id returning * into entry_record;
      state_changed := true;
    end if;
  end if;

  if state_changed then
    insert into public.fund_collection_confirmation_events (
      entry_id, round_id, group_id, member_id, actor_user_id, actor_role, action
    ) values (
      entry_record.id, p_round_id, p_group_id, p_member_id, current_user_id, p_actor_role,
      case when p_confirm then 'confirm' else 'revoke' end
    );
  end if;

  if entry_record.member_confirmed_at is not null and entry_record.responsible_confirmed_at is not null then
    select * into fund_record from public.group_funds where group_id = p_group_id for update;
    if not found then raise exception 'group fund is not configured' using errcode = '23514'; end if;
    select display_name into member_name from public.members where group_id = p_group_id and id = p_member_id;

    update public.group_funds
    set balance = balance + entry_record.amount, version = version + 1
    where group_id = p_group_id;
    update public.fund_member_accounts
    set balance = balance + entry_record.amount,
        contributed_total = contributed_total + entry_record.amount
    where group_id = p_group_id and member_id = p_member_id;
    insert into public.fund_transactions (
      group_id, transaction_type, title, amount_delta, balance_after,
      effective_date, note, created_by
    ) values (
      p_group_id, 'contribution', round_record.title || '－' || member_name || ' 繳交公費',
      entry_record.amount, fund_record.balance + entry_record.amount,
      round_record.effective_date, '公費收款批次雙向確認', current_user_id
    ) returning id into created_transaction_id;
    insert into public.fund_transaction_lines (transaction_id, group_id, member_id, amount_delta)
    values (created_transaction_id, p_group_id, p_member_id, entry_record.amount);
    update public.fund_collection_entries
    set status = 'completed', completed_at = now(), transaction_id = created_transaction_id
    where id = entry_record.id;
    insert into public.fund_collection_confirmation_events (
      entry_id, round_id, group_id, member_id, actor_user_id, actor_role, action
    ) values (
      entry_record.id, p_round_id, p_group_id, p_member_id, current_user_id, p_actor_role, 'complete'
    );

    if not exists (
      select 1 from public.fund_collection_entries where round_id = p_round_id and status = 'pending'
    ) then
      update public.fund_collection_rounds
      set status = 'completed', completed_at = now()
      where id = p_round_id;
      insert into public.fund_collection_round_events (round_id, group_id, actor_user_id, action)
      values (p_round_id, p_group_id, current_user_id, 'complete');
    end if;
  end if;

  return public.get_group_fund_collections(p_group_id);
end;
$$;

create function public.cancel_group_fund_collection_round(p_group_id uuid, p_round_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
begin
  if current_user_id is null or not public.is_group_owner(p_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;
  if exists (
    select 1 from public.fund_collection_entries
    where round_id = p_round_id and group_id = p_group_id and status = 'completed'
  ) then
    raise exception 'a collection with completed payments cannot be cancelled' using errcode = '23514';
  end if;
  update public.fund_collection_rounds
  set status = 'cancelled', cancelled_at = now()
  where id = p_round_id and group_id = p_group_id and status = 'open';
  if not found then raise exception 'fund collection round is not open' using errcode = '23514'; end if;
  insert into public.fund_collection_round_events (round_id, group_id, actor_user_id, action)
  values (p_round_id, p_group_id, current_user_id, 'cancel');
  return public.get_group_fund_collections(p_group_id);
end;
$$;

revoke all on function public.get_group_fund_collections(uuid) from public, anon;
revoke all on function public.create_group_fund_collection_round(uuid, text, bigint, uuid[], date) from public, anon;
revoke all on function public.record_group_fund_collection_confirmation(uuid, uuid, uuid, text, boolean) from public, anon;
revoke all on function public.cancel_group_fund_collection_round(uuid, uuid) from public, anon;
grant execute on function public.get_group_fund_collections(uuid) to authenticated;
grant execute on function public.create_group_fund_collection_round(uuid, text, bigint, uuid[], date) to authenticated;
grant execute on function public.record_group_fund_collection_confirmation(uuid, uuid, uuid, text, boolean) to authenticated;
grant execute on function public.cancel_group_fund_collection_round(uuid, uuid) to authenticated;
