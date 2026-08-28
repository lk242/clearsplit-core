-- Release compatibility and a single immutable audit stream for every table
-- that changes a financial position. The UI checks this version before using
-- cloud RPCs so an updated frontend cannot silently talk to an old schema.

create table public.app_schema_versions (
  version integer primary key check (version > 0),
  name text not null check (char_length(trim(name)) between 1 and 120),
  applied_at timestamptz not null default now()
);

insert into public.app_schema_versions (version, name)
values (26, 'schema guard and financial audit');

alter table public.app_schema_versions enable row level security;
revoke all on public.app_schema_versions from public, anon, authenticated;

create function public.get_app_schema_version()
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(max(version), 0) from public.app_schema_versions;
$$;

revoke all on function public.get_app_schema_version() from public, anon;
grant execute on function public.get_app_schema_version() to authenticated;

alter table public.audit_events
  drop constraint audit_events_entity_type_check,
  drop constraint audit_events_action_check;

alter table public.audit_events
  add constraint audit_events_entity_type_check check (entity_type in (
    'member', 'expense', 'expense_share', 'expense_receipt',
    'settlement_confirmation', 'group_fund', 'fund_member_account',
    'fund_transaction', 'fund_advance', 'fund_collection_round',
    'fund_collection_entry', 'fund_settlement_confirmation'
  )),
  add constraint audit_events_action_check check (action in (
    'insert', 'update', 'delete', 'confirm', 'revoke', 'complete',
    'supersede', 'cancel', 'create'
  ));

create function public.write_financial_audit_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  old_json jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  new_json jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  row_json jsonb := coalesce(new_json, old_json);
  row_group_id uuid := (row_json->>'group_id')::uuid;
  row_entity_id text;
begin
  row_entity_id := coalesce(
    row_json->>'id',
    row_json->>'expense_id' || ':' || row_json->>'debtor_member_id',
    row_json->>'transaction_id' || ':' || row_json->>'member_id',
    row_json->>'round_id' || ':' || row_json->>'member_id',
    row_json->>'group_id' || ':' || row_json->>'member_id',
    row_json->>'group_id'
  );

  if row_group_id is null or row_entity_id is null then
    raise exception 'financial audit identity is unavailable' using errcode = '23514';
  end if;

  insert into public.audit_events (
    group_id, actor_user_id, entity_type, entity_id, action, old_data, new_data
  ) values (
    row_group_id, (select auth.uid()), tg_argv[0], row_entity_id,
    lower(tg_op), old_json, new_json
  );

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

revoke all on function public.write_financial_audit_event()
  from public, anon, authenticated;

create trigger expense_receipts_audit
after insert or update or delete on public.expense_receipts
for each row execute function public.write_financial_audit_event('expense_receipt');

create trigger group_funds_audit
after insert or update or delete on public.group_funds
for each row execute function public.write_financial_audit_event('group_fund');

create trigger fund_member_accounts_audit
after insert or update or delete on public.fund_member_accounts
for each row execute function public.write_financial_audit_event('fund_member_account');

create trigger fund_transactions_audit
after insert or update or delete on public.fund_transactions
for each row execute function public.write_financial_audit_event('fund_transaction');

create trigger fund_advances_audit
after insert or update or delete on public.fund_advances
for each row execute function public.write_financial_audit_event('fund_advance');

create trigger fund_collection_rounds_audit
after insert or update or delete on public.fund_collection_rounds
for each row execute function public.write_financial_audit_event('fund_collection_round');

create trigger fund_collection_entries_audit
after insert or update or delete on public.fund_collection_entries
for each row execute function public.write_financial_audit_event('fund_collection_entry');

create trigger fund_settlement_confirmations_audit
after insert or update or delete on public.fund_settlement_confirmations
for each row execute function public.write_financial_audit_event('fund_settlement_confirmation');
