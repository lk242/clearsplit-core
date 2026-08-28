-- Web input defaults to the current member. Recording an advance for another
-- member remains possible, but the source and actual payer must stay distinct
-- in the immutable transaction/advance records. The fixture rolls back.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(1);

drop index if exists public.ledger_groups_single_active_idx;

do $$
declare
  test_user_ids uuid[];
  owner_user_id uuid;
  payer_user_id uuid;
  test_group_id uuid := gen_random_uuid();
  owner_member_id uuid := gen_random_uuid();
  payer_member_id uuid := gen_random_uuid();
  result jsonb;
  test_transaction_id uuid;
  caught_expected_error boolean := false;
begin
  select array_agg(id order by created_at, id) into test_user_ids
  from (select id, created_at from auth.users order by created_at, id limit 2) users;
  if coalesce(cardinality(test_user_ids), 0) <> 2 then
    raise exception 'fund input attribution test requires two auth users';
  end if;
  owner_user_id := test_user_ids[1];
  payer_user_id := test_user_ids[2];

  insert into public.ledger_groups (id, name, created_by)
  values (test_group_id, 'fund input attribution fixture', owner_user_id);
  insert into public.members (id, group_id, user_id, role, display_name, color)
  values
    (owner_member_id, test_group_id, owner_user_id, 'owner', 'input owner', '#225577'),
    (payer_member_id, test_group_id, payer_user_id, 'member', 'input payer', '#772255');
  update public.ledger_groups
  set responsible_member_id = owner_member_id
  where id = test_group_id;

  perform set_config('request.jwt.claim.sub', owner_user_id::text, true);
  perform public.initialize_group_fund(test_group_id, 100, current_date);

  perform set_config('request.jwt.claim.sub', payer_user_id::text, true);
  result := public.record_group_fund_expense_v3(
    test_group_id, 'self-recorded advance', 200, current_date, null,
    payer_member_id, true, null, 'web'
  );
  select id into test_transaction_id from public.fund_transactions
  where group_id = test_group_id and title = 'self-recorded advance';
  if not exists (
    select 1 from public.fund_transactions
    where id = test_transaction_id and source_member_id = payer_member_id and source_type = 'web'
  ) or not exists (
    select 1 from public.fund_advances
    where fund_advances.transaction_id = test_transaction_id
      and member_id = payer_member_id and amount = 100
  ) then
    raise exception 'web self-record did not attribute source and actual payer';
  end if;
  if (select value->>'isOnBehalf'
      from jsonb_array_elements(result->'advances') value
      where value->>'transactionId' = test_transaction_id::text) <> 'false' then
    raise exception 'web self-record was incorrectly marked on behalf';
  end if;

  perform set_config('request.jwt.claim.sub', owner_user_id::text, true);
  result := public.record_group_fund_expense_v3(
    test_group_id, 'on-behalf advance', 300, current_date, null,
    payer_member_id, false, null, 'web'
  );
  select id into test_transaction_id from public.fund_transactions
  where group_id = test_group_id and title = 'on-behalf advance';
  if not exists (
    select 1 from public.fund_transactions
    where id = test_transaction_id and source_member_id = owner_member_id and source_type = 'web'
  ) or not exists (
    select 1 from public.fund_advances
    where fund_advances.transaction_id = test_transaction_id
      and member_id = payer_member_id and amount = 300
  ) then
    raise exception 'on-behalf record lost source or actual payer';
  end if;
  if (select value->>'isOnBehalf'
      from jsonb_array_elements(result->'advances') value
      where value->>'transactionId' = test_transaction_id::text) <> 'true' then
    raise exception 'different inputter and payer were not marked on behalf';
  end if;

  caught_expected_error := false;
  begin
    perform public.record_group_fund_expense_v3(
      test_group_id, 'forged web source', 10, current_date, null,
      payer_member_id, false, payer_member_id, 'web'
    );
  exception when insufficient_privilege then
    caught_expected_error := true;
  end;
  if not caught_expected_error then
    raise exception 'web caller forged another member as input source';
  end if;

  delete from public.ledger_groups where id = test_group_id;
end;
$$;

select pass('fund input attribution cannot be forged');
select * from finish();
rollback;
