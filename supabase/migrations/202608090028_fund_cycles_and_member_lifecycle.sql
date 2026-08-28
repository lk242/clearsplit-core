-- Public funds may be reused across trips. Each cycle and each transaction
-- keeps its original cycle number, while collection entries and transaction
-- lines continue to freeze the exact member set used at that moment.

insert into public.app_schema_versions (version, name)
values (28, 'repeatable fund cycles and controlled member lifecycle');

alter table public.group_funds
  add column cycle_number integer not null default 1 check (cycle_number > 0);

alter table public.fund_transactions
  add column cycle_number integer not null default 1 check (cycle_number > 0);

alter table public.fund_collection_rounds
  add column cycle_number integer not null default 1 check (cycle_number > 0);

create function public.set_current_fund_cycle_number()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  select fund.cycle_number into new.cycle_number
  from public.group_funds fund where fund.group_id = new.group_id;
  if new.cycle_number is null then
    raise exception 'group fund cycle is unavailable' using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function public.set_current_fund_cycle_number()
  from public, anon, authenticated;

create trigger fund_transactions_set_cycle
before insert on public.fund_transactions
for each row execute function public.set_current_fund_cycle_number();

create trigger fund_collection_rounds_set_cycle
before insert on public.fund_collection_rounds
for each row execute function public.set_current_fund_cycle_number();

create table public.fund_cycle_events (
  id bigint generated always as identity primary key,
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  cycle_number integer not null check (cycle_number > 0),
  action text not null check (action in ('start', 'closing', 'closed')),
  actor_user_id uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create index fund_cycle_events_group_cycle_idx
  on public.fund_cycle_events(group_id, cycle_number, created_at);

insert into public.fund_cycle_events (
  group_id, cycle_number, action, actor_user_id, created_at
)
select group_id, 1, 'start', configured_by, configured_at
from public.group_funds;

alter table public.fund_cycle_events enable row level security;
revoke all on public.fund_cycle_events from public, anon, authenticated;

create function public.write_fund_cycle_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  event_action text;
begin
  if tg_op = 'INSERT' then
    event_action := 'start';
  elsif new.cycle_number is distinct from old.cycle_number then
    event_action := 'start';
  elsif new.status is distinct from old.status then
    event_action := case new.status when 'closing' then 'closing' when 'closed' then 'closed' end;
  end if;
  if event_action is not null then
    insert into public.fund_cycle_events (
      group_id, cycle_number, action, actor_user_id
    ) values (
      new.group_id, new.cycle_number, event_action, (select auth.uid())
    );
  end if;
  return new;
end;
$$;

revoke all on function public.write_fund_cycle_event()
  from public, anon, authenticated;

create trigger group_funds_cycle_events
after insert or update on public.group_funds
for each row execute function public.write_fund_cycle_event();

alter function public.get_group_fund(uuid) rename to get_group_fund_v25;
revoke all on function public.get_group_fund_v25(uuid)
  from public, anon, authenticated;

create function public.get_group_fund(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
  cycle_value integer;
  transaction_items jsonb;
begin
  result := public.get_group_fund_v25(p_group_id);
  if coalesce((result->>'configured')::boolean, false) is false then return result; end if;
  select cycle_number into cycle_value from public.group_funds where group_id = p_group_id;
  select coalesce(jsonb_agg(item.value || jsonb_build_object('cycleNumber', transaction.cycle_number) order by item.ordinality), '[]'::jsonb)
  into transaction_items
  from jsonb_array_elements(coalesce(result->'transactions', '[]'::jsonb)) with ordinality item(value, ordinality)
  join public.fund_transactions transaction on transaction.id = (item.value->>'id')::uuid;
  return jsonb_set(result || jsonb_build_object('cycleNumber', cycle_value), '{transactions}', transaction_items);
end;
$$;

revoke all on function public.get_group_fund(uuid) from public, anon;
grant execute on function public.get_group_fund(uuid) to authenticated;

alter function public.get_group_fund_collections(uuid) rename to get_group_fund_collections_v16;
revoke all on function public.get_group_fund_collections_v16(uuid)
  from public, anon, authenticated;

create function public.get_group_fund_collections(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
  round_items jsonb;
begin
  result := public.get_group_fund_collections_v16(p_group_id);
  select coalesce(jsonb_agg(item.value || jsonb_build_object('cycleNumber', round.cycle_number) order by item.ordinality), '[]'::jsonb)
  into round_items
  from jsonb_array_elements(coalesce(result->'rounds', '[]'::jsonb)) with ordinality item(value, ordinality)
  join public.fund_collection_rounds round on round.id = (item.value->>'id')::uuid;
  return jsonb_set(result, '{rounds}', round_items);
end;
$$;

revoke all on function public.get_group_fund_collections(uuid) from public, anon;
grant execute on function public.get_group_fund_collections(uuid) to authenticated;

create function public.start_next_group_fund_cycle(p_group_id uuid)
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
  select * into fund_record from public.group_funds
  where group_id = p_group_id for update;
  if not found or fund_record.status <> 'closed' then
    raise exception 'the previous fund cycle is not closed' using errcode = '23514';
  end if;
  if fund_record.balance <> 0
    or exists (select 1 from public.fund_member_accounts where group_id = p_group_id and balance <> 0)
    or exists (select 1 from public.fund_advances where group_id = p_group_id and status = 'open')
    or exists (select 1 from public.fund_collection_rounds where group_id = p_group_id and status = 'open') then
    raise exception 'the previous fund cycle still has balances' using errcode = '23514';
  end if;

  update public.group_funds
  set cycle_number = cycle_number + 1,
      status = 'active',
      closing_started_at = null,
      closed_at = null,
      version = version + 1
  where group_id = p_group_id;
  return public.get_group_fund(p_group_id);
end;
$$;

revoke all on function public.start_next_group_fund_cycle(uuid) from public, anon;
grant execute on function public.start_next_group_fund_cycle(uuid) to authenticated;

create function public.create_group_member(
  p_group_id uuid,
  p_member_id uuid,
  p_name text,
  p_color text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  fund_record public.group_funds;
  fund_exists boolean := false;
begin
  if (select auth.uid()) is null or not public.is_group_owner(p_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;
  if p_member_id is null or char_length(trim(coalesce(p_name, ''))) not between 1 and 80
    or char_length(trim(coalesce(p_color, ''))) not between 1 and 32 then
    raise exception 'invalid member input' using errcode = '22023';
  end if;
  select * into fund_record from public.group_funds where group_id = p_group_id for update;
  fund_exists := found;
  if found and (
    fund_record.status <> 'active'
    or exists (select 1 from public.fund_collection_rounds where group_id = p_group_id and status = 'open')
  ) then
    raise exception 'members are frozen during collection or closeout' using errcode = '23514';
  end if;
  insert into public.members (id, group_id, role, display_name, color)
  values (p_member_id, p_group_id, 'member', trim(p_name), trim(p_color));
  if fund_exists then
    insert into public.fund_member_accounts (group_id, member_id, balance)
    values (p_group_id, p_member_id, 0)
    on conflict (group_id, member_id) do nothing;
  end if;
end;
$$;

create function public.update_group_member(
  p_group_id uuid,
  p_member_id uuid,
  p_name text,
  p_color text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select auth.uid()) is null or not public.is_group_owner(p_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;
  if char_length(trim(coalesce(p_name, ''))) not between 1 and 80
    or char_length(trim(coalesce(p_color, ''))) not between 1 and 32 then
    raise exception 'invalid member input' using errcode = '22023';
  end if;
  update public.members set display_name = trim(p_name), color = trim(p_color)
  where group_id = p_group_id and id = p_member_id;
  if not found then raise exception 'member is unavailable' using errcode = '22023'; end if;
end;
$$;

create function public.remove_group_member(p_group_id uuid, p_member_id uuid)
returns void
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
  if exists (select 1 from public.ledger_groups where id = p_group_id and responsible_member_id = p_member_id) then
    raise exception 'the responsible member cannot be removed' using errcode = '23514';
  end if;
  select * into fund_record from public.group_funds where group_id = p_group_id for update;
  if found and (
    fund_record.status <> 'active'
    or exists (select 1 from public.fund_collection_rounds where group_id = p_group_id and status = 'open')
  ) then
    raise exception 'members are frozen during collection or closeout' using errcode = '23514';
  end if;
  if exists (select 1 from public.expenses where group_id = p_group_id and payer_member_id = p_member_id)
    or exists (select 1 from public.expense_shares where group_id = p_group_id and member_id = p_member_id)
    or exists (select 1 from public.fund_transaction_lines where group_id = p_group_id and member_id = p_member_id)
    or exists (select 1 from public.fund_collection_entries where group_id = p_group_id and member_id = p_member_id)
    or exists (select 1 from public.fund_advances where group_id = p_group_id and member_id = p_member_id)
    or exists (select 1 from public.fund_member_accounts where group_id = p_group_id and member_id = p_member_id and balance <> 0) then
    raise exception 'member has financial history and cannot be removed' using errcode = '23514';
  end if;
  delete from public.members where group_id = p_group_id and id = p_member_id;
  if not found then raise exception 'member is unavailable' using errcode = '22023'; end if;
end;
$$;

revoke all on function public.create_group_member(uuid, uuid, text, text) from public, anon;
revoke all on function public.update_group_member(uuid, uuid, text, text) from public, anon;
revoke all on function public.remove_group_member(uuid, uuid) from public, anon;
grant execute on function public.create_group_member(uuid, uuid, text, text) to authenticated;
grant execute on function public.update_group_member(uuid, uuid, text, text) to authenticated;
grant execute on function public.remove_group_member(uuid, uuid) to authenticated;

revoke insert, update, delete on public.members from authenticated;
