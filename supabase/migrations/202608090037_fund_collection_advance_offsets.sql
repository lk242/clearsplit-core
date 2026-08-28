-- A collection can settle an existing member advance without forcing money to
-- travel in both directions. Gross contribution, non-cash offset and actual
-- cash remain separate and are posted only after both sides confirm.

alter table public.fund_advances
  add column settled_amount bigint not null default 0;

update public.fund_advances
set settled_amount = amount
where status = 'completed';

alter table public.fund_advances
  add constraint fund_advances_settled_amount_check
    check (settled_amount >= 0 and settled_amount <= amount),
  drop constraint fund_advance_completion_state,
  add constraint fund_advance_completion_state check (
    (status = 'open' and completed_at is null and settled_amount < amount)
    or (status = 'completed' and completed_at is not null and settled_amount = amount)
  );

alter table public.fund_advance_confirmation_events
  drop constraint fund_advance_confirmation_events_action_check,
  add constraint fund_advance_confirmation_events_action_check
    check (action in ('confirm', 'revoke', 'complete', 'offset'));

create table public.fund_collection_advance_offsets (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null references public.fund_collection_entries(id) on delete cascade,
  round_id uuid not null references public.fund_collection_rounds(id) on delete cascade,
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  member_id uuid not null,
  advance_id uuid not null references public.fund_advances(id) on delete cascade,
  amount bigint not null check (amount > 0),
  status text not null default 'pending' check (status in ('pending', 'completed')),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (entry_id, advance_id),
  constraint fund_collection_offset_member_same_group_fk
    foreign key (member_id, group_id) references public.members(id, group_id),
  constraint fund_collection_offset_completion_check check (
    (status = 'pending' and completed_at is null)
    or (status = 'completed' and completed_at is not null)
  )
);

create index fund_collection_offsets_advance_status_idx
  on public.fund_collection_advance_offsets(advance_id, status);
create index fund_collection_offsets_entry_idx
  on public.fund_collection_advance_offsets(entry_id, created_at);

alter table public.fund_collection_advance_offsets enable row level security;
revoke all on public.fund_collection_advance_offsets from public, anon, authenticated;

alter table public.audit_events
  drop constraint audit_events_entity_type_check,
  add constraint audit_events_entity_type_check check (entity_type in (
    'member', 'expense', 'expense_share', 'expense_receipt',
    'settlement_confirmation', 'group_fund', 'fund_member_account',
    'fund_transaction', 'fund_advance', 'fund_collection_round',
    'fund_collection_entry', 'fund_collection_advance_offset',
    'fund_settlement_confirmation'
  ));

create trigger fund_collection_advance_offsets_audit
after insert or update or delete on public.fund_collection_advance_offsets
for each row execute function public.write_financial_audit_event('fund_collection_advance_offset');

create or replace function public.fund_available_cash(p_group_id uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select fund.balance + coalesce((
    select sum(advance.amount - advance.settled_amount)
    from public.fund_advances advance
    where advance.group_id = fund.group_id and advance.status = 'open'
  ), 0)
  from public.group_funds fund
  where fund.group_id = p_group_id;
$$;

alter function public.get_group_fund(uuid) rename to get_group_fund_v36;
revoke all on function public.get_group_fund_v36(uuid)
  from public, anon, authenticated;

create function public.get_group_fund(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
  advance_items jsonb;
begin
  result := public.get_group_fund_v36(p_group_id);
  if coalesce((result->>'configured')::boolean, false) is false then
    return result;
  end if;
  select coalesce(jsonb_agg(
    item.value || jsonb_build_object(
      'settledAmount', advance.settled_amount,
      'remainingAmount', advance.amount - advance.settled_amount
    ) order by item.ordinality
  ), '[]'::jsonb)
  into advance_items
  from jsonb_array_elements(coalesce(result->'advances', '[]'::jsonb))
    with ordinality item(value, ordinality)
  join public.fund_advances advance
    on advance.id = (item.value->>'id')::uuid;
  return jsonb_set(result, '{advances}', advance_items);
end;
$$;

revoke all on function public.get_group_fund(uuid) from public, anon;
grant execute on function public.get_group_fund(uuid) to authenticated;

create or replace function public.get_group_fund_collections(p_group_id uuid)
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
            'cycleNumber', round.cycle_number,
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
                'offsetAmount', coalesce(offsets.offset_amount, 0),
                'cashAmount', entry.amount - coalesce(offsets.offset_amount, 0),
                'offsets', coalesce(offsets.items, '[]'::jsonb),
                'status', entry.status,
                'memberConfirmedAt', entry.member_confirmed_at,
                'responsibleConfirmedAt', entry.responsible_confirmed_at,
                'completedAt', entry.completed_at
              ) order by member.created_at, member.id)
              from public.fund_collection_entries entry
              join public.members member
                on member.id = entry.member_id and member.group_id = entry.group_id
              left join lateral (
                select sum(advance_offset.amount) as offset_amount,
                  jsonb_agg(jsonb_build_object(
                    'id', advance_offset.id,
                    'advanceId', advance_offset.advance_id,
                    'amount', advance_offset.amount,
                    'status', advance_offset.status,
                    'completedAt', advance_offset.completed_at
                  ) order by advance_offset.created_at, advance_offset.id) as items
                from public.fund_collection_advance_offsets advance_offset
                where advance_offset.entry_id = entry.id
              ) offsets on true
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

create function public.create_group_fund_collection_round_v3(
  p_group_id uuid,
  p_title text,
  p_amount_per_member bigint,
  p_effective_date date,
  p_apply_advance_offsets boolean default true
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
  entry_record public.fund_collection_entries;
  member_record record;
  advance_record public.fund_advances;
  member_count integer;
  remaining_contribution bigint;
  offset_value bigint;
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
    or p_amount_per_member > 999999999 or p_effective_date is null
    or p_apply_advance_offsets is null then
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
    ) returning * into entry_record;

    if p_apply_advance_offsets then
      remaining_contribution := p_amount_per_member;
      for advance_record in
        select * from public.fund_advances advance
        where advance.group_id = p_group_id
          and advance.member_id = member_record.id
          and advance.status = 'open'
          and advance.member_confirmed_at is null
          and advance.responsible_confirmed_at is null
          and advance.settled_amount < advance.amount
        order by advance.created_at, advance.id
        for update
      loop
        exit when remaining_contribution = 0;
        offset_value := least(
          remaining_contribution,
          advance_record.amount - advance_record.settled_amount
        );
        insert into public.fund_collection_advance_offsets (
          entry_id, round_id, group_id, member_id, advance_id, amount
        ) values (
          entry_record.id, round_record.id, p_group_id, member_record.id,
          advance_record.id, offset_value
        );
        remaining_contribution := remaining_contribution - offset_value;
      end loop;
    end if;
  end loop;

  insert into public.fund_collection_round_events (
    round_id, group_id, actor_user_id, action
  ) values (
    round_record.id, p_group_id, current_user_id, 'create'
  );
  return public.get_group_fund_collections(p_group_id);
end;
$$;

create or replace function public.record_group_fund_collection_confirmation(
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
  advance_record public.fund_advances;
  offset_record public.fund_collection_advance_offsets;
  member_name text;
  created_transaction_id uuid;
  offset_total bigint := 0;
  cash_total bigint;
  state_changed boolean := false;
begin
  if current_user_id is null or p_actor_role not in ('member', 'responsible')
    or p_confirm is null then
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

  if entry_record.member_confirmed_at is not null
    and entry_record.responsible_confirmed_at is not null then
    select * into fund_record
    from public.group_funds where group_id = p_group_id for update;
    if not found or fund_record.status <> 'active' then
      raise exception 'group fund is not accepting collections' using errcode = '23514';
    end if;
    select display_name into member_name
    from public.members where group_id = p_group_id and id = p_member_id;

    perform 1 from public.fund_collection_advance_offsets
    where entry_id = entry_record.id and status = 'pending'
    order by created_at, id for update;
    select coalesce(sum(amount), 0) into offset_total
    from public.fund_collection_advance_offsets
    where entry_id = entry_record.id and status = 'pending';
    if offset_total < 0 or offset_total > entry_record.amount then
      raise exception 'collection advance offset is invalid' using errcode = '23514';
    end if;
    cash_total := entry_record.amount - offset_total;

    for offset_record in
      select * from public.fund_collection_advance_offsets
      where entry_id = entry_record.id and status = 'pending'
      order by created_at, id
    loop
      select * into advance_record
      from public.fund_advances
      where id = offset_record.advance_id and group_id = p_group_id
      for update;
      if not found or advance_record.status <> 'open'
        or advance_record.member_id <> p_member_id
        or advance_record.member_confirmed_at is not null
        or advance_record.responsible_confirmed_at is not null
        or advance_record.amount - advance_record.settled_amount < offset_record.amount then
        raise exception 'reserved fund advance changed; recreate the collection' using errcode = '40001';
      end if;
      update public.fund_advances
      set settled_amount = settled_amount + offset_record.amount,
          status = case when settled_amount + offset_record.amount = amount then 'completed' else 'open' end,
          completed_at = case when settled_amount + offset_record.amount = amount then now() else null end
      where id = advance_record.id;
      update public.fund_collection_advance_offsets
      set status = 'completed', completed_at = now()
      where id = offset_record.id;
      insert into public.fund_advance_confirmation_events (
        advance_id, group_id, actor_user_id, actor_role, action
      ) values (
        advance_record.id, p_group_id, current_user_id, p_actor_role, 'offset'
      );
    end loop;

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
      round_record.effective_date,
      '應繳 ' || entry_record.amount || '；代墊折抵 ' || offset_total || '；現金 ' || cash_total,
      current_user_id
    ) returning id into created_transaction_id;
    insert into public.fund_transaction_lines (
      transaction_id, group_id, member_id, amount_delta
    ) values (
      created_transaction_id, p_group_id, p_member_id, entry_record.amount
    );
    update public.fund_collection_entries
    set status = 'completed', completed_at = now(), transaction_id = created_transaction_id
    where id = entry_record.id;
    insert into public.fund_collection_confirmation_events (
      entry_id, round_id, group_id, member_id, actor_user_id, actor_role, action
    ) values (
      entry_record.id, p_round_id, p_group_id, p_member_id,
      current_user_id, p_actor_role, 'complete'
    );

    if not exists (
      select 1 from public.fund_collection_entries
      where round_id = p_round_id and status = 'pending'
    ) then
      update public.fund_collection_rounds
      set status = 'completed', completed_at = now()
      where id = p_round_id;
      insert into public.fund_collection_round_events (
        round_id, group_id, actor_user_id, action
      ) values (p_round_id, p_group_id, current_user_id, 'complete');
    end if;
  end if;

  return public.get_group_fund_collections(p_group_id);
end;
$$;

create or replace function public.cancel_group_fund_collection_round(
  p_group_id uuid,
  p_round_id uuid
)
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
  delete from public.fund_collection_advance_offsets
  where round_id = p_round_id and group_id = p_group_id and status = 'pending';
  update public.fund_collection_rounds
  set status = 'cancelled', cancelled_at = now()
  where id = p_round_id and group_id = p_group_id and status = 'open';
  if not found then
    raise exception 'fund collection round is not open' using errcode = '23514';
  end if;
  insert into public.fund_collection_round_events (
    round_id, group_id, actor_user_id, action
  ) values (p_round_id, p_group_id, current_user_id, 'cancel');
  return public.get_group_fund_collections(p_group_id);
end;
$$;

create or replace function public.record_group_fund_advance_confirmation(
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
  remaining_amount bigint;
  state_changed boolean := false;
begin
  if current_user_id is null or p_actor_role not in ('member', 'responsible')
    or p_confirm is null then
    raise exception 'invalid fund advance confirmation' using errcode = '22023';
  end if;
  select id into current_member_id
  from public.members where group_id = p_group_id and user_id = current_user_id;
  select * into fund_record
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

create or replace function public.reassign_group_fund_advance(
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
    or advance_record.completed_at is not null
    or advance_record.settled_amount <> 0
    or exists (
      select 1 from public.fund_collection_advance_offsets
      where advance_id = p_advance_id
    ) then
    raise exception 'confirmed or offset fund advance cannot be reassigned' using errcode = '23514';
  end if;
  if advance_record.member_id is distinct from p_expected_member_id then
    raise exception 'fund advance changed; refresh and try again' using errcode = '40001';
  end if;
  if not exists (
    select 1 from public.members where id = p_new_member_id and group_id = p_group_id
  ) then
    raise exception 'new advance member is unavailable' using errcode = '22023';
  end if;
  if advance_record.member_id is distinct from p_new_member_id then
    update public.fund_advances set member_id = p_new_member_id where id = p_advance_id;
  end if;
  return public.get_group_fund(p_group_id);
end;
$$;

revoke all on function public.create_group_fund_collection_round_v3(uuid, text, bigint, date, boolean)
  from public, anon;
grant execute on function public.create_group_fund_collection_round_v3(uuid, text, bigint, date, boolean)
  to authenticated;

insert into public.app_schema_versions (version, name)
values (37, 'public-fund collection advance offsets');
