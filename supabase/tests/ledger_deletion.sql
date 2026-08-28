-- Destructive-path integration test. All fixture creation and deletion are
-- rolled back, so production data is unchanged.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(1);

drop index if exists public.ledger_groups_single_active_idx;

do $$
declare
  actor_user_id uuid;
  other_user_id uuid;
  test_group_id uuid := gen_random_uuid();
  owner_member_id uuid := gen_random_uuid();
  other_member_id uuid := gen_random_uuid();
  private_expense_id uuid := gen_random_uuid();
  fund_transaction_id uuid := gen_random_uuid();
  advance_id uuid := gen_random_uuid();
  collection_round_id uuid := gen_random_uuid();
  collection_entry_id uuid;
  webhook_id text := 'delete-test-' || replace(gen_random_uuid()::text, '-', '');
  source_message_id text := 'delete-message-' || replace(gen_random_uuid()::text, '-', '');
  legacy_webhook_id text := 'legacy-delete-' || replace(gen_random_uuid()::text, '-', '');
  legacy_message_id text := 'legacy-message-' || replace(gen_random_uuid()::text, '-', '');
  result jsonb;
begin
  select users.id into actor_user_id
  from auth.users users order by users.created_at, users.id limit 1;
  select users.id into other_user_id
  from auth.users users
  where users.id <> actor_user_id
  order by users.created_at, users.id limit 1;
  if actor_user_id is null or other_user_id is null then
    raise exception 'ledger deletion test requires two auth users';
  end if;
  perform set_config('request.jwt.claim.sub', actor_user_id::text, true);

  insert into public.ledger_groups (id, name, created_by)
  values (test_group_id, 'delete boundary fixture', actor_user_id);
  insert into public.members (id, group_id, user_id, role, display_name, color)
  values
    (owner_member_id, test_group_id, actor_user_id, 'owner', 'delete owner', '#225577'),
    (other_member_id, test_group_id, other_user_id, 'member', 'delete member', '#772255');
  update public.ledger_groups
  set responsible_member_id = owner_member_id
  where id = test_group_id;

  -- The expense is intentionally created and paid by another user. During a
  -- root cascade the responsible-member lookup can no longer see the ledger,
  -- so this row reproduces the production failure guarded by migration 41.
  insert into public.expenses (
    id, group_id, title, amount, category, payer_member_id, expense_date,
    created_by, updated_by
  ) values (
    private_expense_id, test_group_id, 'delete private expense', 600, 'food',
    other_member_id, current_date, other_user_id, other_user_id
  );
  insert into public.expense_shares (
    expense_id, group_id, member_id, amount, share_order
  ) values
    (private_expense_id, test_group_id, owner_member_id, 300, 0),
    (private_expense_id, test_group_id, other_member_id, 300, 1);
  insert into public.expense_receipts (
    expense_id, group_id, debtor_member_id, amount,
    paid_at, paid_confirmed_by
  ) values (
    private_expense_id, test_group_id, owner_member_id, 300,
    now(), actor_user_id
  );
  insert into public.private_expense_confirmation_events (
    expense_id, group_id, debtor_member_id, amount,
    actor_user_id, actor_role, action
  ) values (
    private_expense_id, test_group_id, owner_member_id, 300,
    actor_user_id, 'debtor', 'confirm'
  );
  insert into public.line_expense_drafts (
    group_id, webhook_event_id, source_message_id, source_line_user_id,
    title, amount, payer_member_id, participant_member_ids,
    status, confirmed_expense_id
  ) values (
    test_group_id, legacy_webhook_id, legacy_message_id,
    'U00000000000000000000000000000000', 'delete legacy draft', 600,
    other_member_id, array[owner_member_id, other_member_id],
    'confirmed', private_expense_id
  );
  insert into public.settlement_confirmation_events (
    group_id, member_id, direction, fingerprint, action, actor_user_id
  ) values (
    test_group_id, other_member_id, 'payment',
    'delete-private-settlement', 'confirm', other_user_id
  );

  insert into public.group_funds (group_id, balance, configured_by)
  values (test_group_id, -700, actor_user_id);
  insert into public.fund_member_accounts (
    group_id, member_id, balance, consumed_total
  ) values
    (test_group_id, owner_member_id, -350, 400),
    (test_group_id, other_member_id, -350, 400);
  insert into public.fund_transactions (
    id, group_id, transaction_type, title, amount_delta, balance_after,
    effective_date, created_by, source_member_id, source_type
  ) values (
    fund_transaction_id, test_group_id, 'expense', 'delete advance',
    -700, -700, current_date, actor_user_id, other_member_id, 'web'
  );
  insert into public.fund_transaction_lines (
    transaction_id, group_id, member_id, amount_delta
  ) values
    (fund_transaction_id, test_group_id, owner_member_id, -350),
    (fund_transaction_id, test_group_id, other_member_id, -350);
  insert into public.fund_advances (
    id, group_id, transaction_id, member_id, amount
  ) values (
    advance_id, test_group_id, fund_transaction_id, other_member_id, 700
  );

  insert into public.fund_collection_rounds (
    id, group_id, title, amount_per_member, effective_date, created_by
  ) values (
    collection_round_id, test_group_id, 'delete open collection', 1500,
    current_date, actor_user_id
  );
  insert into public.fund_collection_entries (
    round_id, group_id, member_id, amount
  ) values
    (collection_round_id, test_group_id, owner_member_id, 1500),
    (collection_round_id, test_group_id, other_member_id, 1500);
  select entry.id into collection_entry_id
  from public.fund_collection_entries entry
  where entry.round_id = collection_round_id
    and entry.member_id = other_member_id;
  insert into public.fund_collection_advance_offsets (
    entry_id, round_id, group_id, member_id, advance_id, amount
  ) values (
    collection_entry_id, collection_round_id, test_group_id,
    other_member_id, advance_id, 700
  );

  insert into public.line_webhook_events (
    webhook_event_id, source_message_id, group_id, status
  ) values (webhook_id, source_message_id, test_group_id, 'processed');
  insert into public.line_fund_expense_drafts (
    group_id, webhook_event_id, source_message_id, source_line_user_id,
    submitted_member_id, submitted_display_name, title, amount,
    effective_date, status, confirmed_transaction_id, confirmed_by, confirmed_at
  ) values (
    test_group_id, webhook_id, source_message_id,
    'U00000000000000000000000000000000', other_member_id, 'delete member',
    'delete LINE draft', 99, current_date, 'confirmed', fund_transaction_id,
    actor_user_id, now()
  );

  result := public.delete_ledger_group(
    test_group_id, 'delete boundary fixture', null
  );
  if result->>'deletedGroupId' <> test_group_id::text
    or (result->>'memberCount')::integer <> 2
    or (result->>'expenseCount')::integer <> 1 then
    raise exception 'ledger deletion returned an invalid receipt contract';
  end if;
  if exists (select 1 from public.ledger_groups where id = test_group_id)
    or exists (select 1 from public.members where group_id = test_group_id)
    or exists (select 1 from public.expenses where group_id = test_group_id)
    or exists (select 1 from public.expense_receipts where group_id = test_group_id)
    or exists (select 1 from public.fund_advances where group_id = test_group_id)
    or exists (select 1 from public.fund_collection_rounds where group_id = test_group_id)
    or exists (select 1 from public.line_fund_expense_drafts where group_id = test_group_id)
    or exists (select 1 from public.audit_events where group_id = test_group_id) then
    raise exception 'ledger deletion left dependent rows behind';
  end if;
  if not exists (
    select 1 from public.ledger_deletion_receipts
    where id = (result->>'receiptId')::uuid
      and deleted_group_id = test_group_id
  ) then
    raise exception 'ledger deletion receipt was not preserved';
  end if;
end;
$$;

select pass('transactional ledger deletion removes every child and preserves its receipt');
select * from finish();
rollback;
