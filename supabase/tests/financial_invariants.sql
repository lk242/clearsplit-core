-- Read-only production smoke test. Run after all migrations. The transaction
-- is rolled back and the assertions do not create financial or auth records.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(1);

do $$
declare
  current_version integer;
  invalid_count bigint;
  test_user_id uuid;
  test_group_id uuid;
  payer_member_id uuid;
  payer_user_id uuid;
  debtor_member_id uuid;
  debtor_user_id uuid;
  test_expense_id uuid;
  test_advance_id uuid;
  original_advance_member_id uuid;
  replacement_advance_member_id uuid;
  report jsonb;
begin
  select max(version) into current_version from public.app_schema_versions;
  if current_version <> 48 then
    raise exception 'expected schema version 48, found %', current_version;
  end if;

  select count(*) into invalid_count
  from public.expenses expense
  left join lateral (
    select count(*) as share_count, coalesce(sum(share.amount), 0) as share_total
    from public.expense_shares share where share.expense_id = expense.id
  ) shares on true
  where shares.share_count = 0 or shares.share_total <> expense.amount;
  if invalid_count <> 0 then
    raise exception '% private expenses do not conserve their amount', invalid_count;
  end if;

  select count(*) into invalid_count
  from public.group_funds fund
  left join lateral (
    select coalesce(sum(account.balance), 0) as account_total
    from public.fund_member_accounts account where account.group_id = fund.group_id
  ) accounts on true
  where fund.balance <> accounts.account_total;
  if invalid_count <> 0 then
    raise exception '% group funds differ from member-account totals', invalid_count;
  end if;

  select count(*) into invalid_count
  from public.fund_transactions transaction
  left join lateral (
    select coalesce(sum(line.amount_delta), 0) as line_total
    from public.fund_transaction_lines line where line.transaction_id = transaction.id
  ) lines on true
  where transaction.amount_delta <> lines.line_total;
  if invalid_count <> 0 then
    raise exception '% fund transactions have unbalanced journal lines', invalid_count;
  end if;

  select count(*) into invalid_count
  from public.line_expense_drafts where status in ('pending', 'needs_input');
  if invalid_count <> 0 then
    raise exception '% legacy private LINE drafts remain active', invalid_count;
  end if;

  select member.user_id, member.group_id
  into test_user_id, test_group_id
  from public.members member
  join public.ledger_groups ledger
    on ledger.id = member.group_id and ledger.responsible_member_id = member.id
  where member.user_id is not null
  order by ledger.created_at desc
  limit 1;

  if test_user_id is not null then
    perform set_config('request.jwt.claim.sub', test_user_id::text, true);
    report := public.get_ledger_reconciliation(test_group_id);
    if jsonb_typeof(report) <> 'object' or not (report ? 'isHealthy') then
      raise exception 'reconciliation RPC returned an invalid contract';
    end if;

    select public.restore_active_ledger_with_line(
      member.user_id,
      member.line_user_id,
      member.display_name,
      member.avatar_url
    )
    into report
    from public.members member
    where member.group_id = test_group_id
      and member.user_id = test_user_id
      and member.line_user_id is not null;
    if report is not null and coalesce((report->>'found')::boolean, false) is false then
      raise exception 'LINE direct-site restore RPC did not find the verified member';
    end if;
  end if;

  -- An unconfirmed public-fund advance can be corrected by the responsible
  -- member. Reassign it in both directions and verify the locked row each time.
  select advance.group_id, advance.id, advance.member_id, replacement.id,
         responsible.user_id
  into test_group_id, test_advance_id, original_advance_member_id,
       replacement_advance_member_id, test_user_id
  from public.fund_advances advance
  join public.ledger_groups ledger
    on ledger.id = advance.group_id
  join public.members responsible
    on responsible.id = ledger.responsible_member_id
  join lateral (
    select member.id
    from public.members member
    where member.group_id = advance.group_id
      and member.id <> advance.member_id
    order by member.created_at
    limit 1
  ) replacement on true
  where advance.status = 'open'
    and advance.member_confirmed_at is null
    and advance.responsible_confirmed_at is null
    and responsible.user_id is not null
  order by advance.created_at desc
  limit 1;

  if test_advance_id is not null then
    perform set_config('request.jwt.claim.sub', test_user_id::text, true);
    perform public.reassign_group_fund_advance(
      test_group_id, test_advance_id, original_advance_member_id,
      replacement_advance_member_id
    );
    if not exists (
      select 1 from public.fund_advances
      where id = test_advance_id and member_id = replacement_advance_member_id
    ) then
      raise exception 'fund advance reassignment did not persist the new member';
    end if;
    perform public.reassign_group_fund_advance(
      test_group_id, test_advance_id, replacement_advance_member_id,
      original_advance_member_id
    );
  end if;

  -- The second private-expense confirmation must complete atomically in both
  -- possible orders. These synthetic rows are rolled back with the test.
  select payer.group_id, payer.id, payer.user_id, debtor.id, debtor.user_id
  into test_group_id, payer_member_id, payer_user_id, debtor_member_id, debtor_user_id
  from public.members payer
  join public.members debtor
    on debtor.group_id = payer.group_id and debtor.id <> payer.id
  where payer.user_id is not null and debtor.user_id is not null
  order by payer.created_at, debtor.created_at
  limit 1;

  if payer_user_id is not null and debtor_user_id is not null then
    test_expense_id := gen_random_uuid();
    perform set_config('request.jwt.claim.sub', payer_user_id::text, true);
    perform public.save_private_expense(
      test_group_id, test_expense_id, 'atomic debtor-first test', 10, 'other',
      payer_member_id,
      jsonb_build_array(
        jsonb_build_object('participantId', payer_member_id, 'amount', 0),
        jsonb_build_object('participantId', debtor_member_id, 'amount', 10)
      ),
      'custom', current_date, null, null
    );
    perform set_config('request.jwt.claim.sub', debtor_user_id::text, true);
    perform public.record_private_expense_confirmation(
      test_group_id, test_expense_id, debtor_member_id, 'debtor', true
    );
    perform set_config('request.jwt.claim.sub', payer_user_id::text, true);
    report := public.record_private_expense_confirmation(
      test_group_id, test_expense_id, debtor_member_id, 'payer', true
    );
    if report->>'status' <> 'resolved' or not exists (
      select 1 from public.expense_receipts receipt
      where receipt.expense_id = test_expense_id
        and receipt.paid_at is not null
        and receipt.received_at is not null
        and receipt.completed_at is not null
    ) then
      raise exception 'debtor-first private confirmation did not complete atomically';
    end if;

    test_expense_id := gen_random_uuid();
    perform public.save_private_expense(
      test_group_id, test_expense_id, 'atomic payer-first test', 10, 'other',
      payer_member_id,
      jsonb_build_array(
        jsonb_build_object('participantId', payer_member_id, 'amount', 0),
        jsonb_build_object('participantId', debtor_member_id, 'amount', 10)
      ),
      'custom', current_date, null, null
    );
    perform public.record_private_expense_confirmation(
      test_group_id, test_expense_id, debtor_member_id, 'payer', true
    );
    perform set_config('request.jwt.claim.sub', debtor_user_id::text, true);
    report := public.record_private_expense_confirmation(
      test_group_id, test_expense_id, debtor_member_id, 'debtor', true
    );
    if report->>'status' <> 'resolved' or not exists (
      select 1 from public.expense_receipts receipt
      where receipt.expense_id = test_expense_id
        and receipt.paid_at is not null
        and receipt.received_at is not null
        and receipt.completed_at is not null
    ) then
      raise exception 'payer-first private confirmation did not complete atomically';
    end if;
  end if;

  -- Exercise the complete opening-fund write path when an unconfigured ledger
  -- is available. The outer transaction rolls every inserted journal/audit row
  -- back, so this tests runtime trigger behavior without changing production.
  select member.user_id, member.group_id
  into test_user_id, test_group_id
  from public.members member
  join public.ledger_groups ledger
    on ledger.id = member.group_id and ledger.responsible_member_id = member.id
  where member.user_id is not null
    and not exists (
      select 1 from public.group_funds fund where fund.group_id = member.group_id
    )
  order by ledger.created_at desc
  limit 1;

  if test_user_id is not null then
    perform set_config('request.jwt.claim.sub', test_user_id::text, true);
    report := public.initialize_group_fund(test_group_id, 100, current_date);
    if coalesce((report->>'configured')::boolean, false) is false
      or (report->>'balance')::bigint <> 100 then
      raise exception 'opening fund RPC returned an invalid contract';
    end if;
  end if;
end;
$$;

select pass('financial invariants and atomic workflows hold');
select * from finish();
rollback;
