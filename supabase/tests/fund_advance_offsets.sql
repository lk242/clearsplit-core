-- Gross collection, advance offset and actual cash must remain conserved.
-- The complete fixture is rolled back.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(1);

-- Singleton mode is restored automatically by the final rollback. Dropping
-- the index only inside this transaction lets the isolated fixture coexist
-- with the real active ledger without reading or modifying its rows.
drop index if exists public.ledger_groups_single_active_idx;

do $$
declare
  owner_user_id uuid;
  advance_user_id uuid;
  test_user_ids uuid[];
  test_group_id uuid := gen_random_uuid();
  owner_member_id uuid := gen_random_uuid();
  advance_member_id uuid := gen_random_uuid();
  test_advance_id uuid;
  test_round_id uuid;
  test_entry_id uuid;
  result jsonb;
  caught_expected_error boolean := false;
begin
  select array_agg(id order by created_at, id) into test_user_ids
  from (select id, created_at from auth.users order by created_at, id limit 2) users;
  if coalesce(cardinality(test_user_ids), 0) <> 2 then
    raise exception 'fund offset test requires two auth users';
  end if;
  owner_user_id := test_user_ids[1];
  advance_user_id := test_user_ids[2];

  insert into public.ledger_groups (id, name, created_by)
  values (test_group_id, 'fund offset fixture', owner_user_id);
  insert into public.members (id, group_id, user_id, role, display_name, color)
  values
    (owner_member_id, test_group_id, owner_user_id, 'owner', 'offset owner', '#225577'),
    (advance_member_id, test_group_id, advance_user_id, 'member', 'offset member', '#772255');
  update public.ledger_groups
  set responsible_member_id = owner_member_id
  where id = test_group_id;

  perform set_config('request.jwt.claim.sub', owner_user_id::text, true);
  perform public.initialize_group_fund(test_group_id, 100, current_date);

  perform set_config('request.jwt.claim.sub', advance_user_id::text, true);
  perform public.record_group_fund_expense_v2(
    test_group_id, 'offset expense', 800, current_date, null,
    advance_member_id, true
  );
  select id into test_advance_id
  from public.fund_advances
  where group_id = test_group_id and member_id = advance_member_id and status = 'open';
  if test_advance_id is null or not exists (
    select 1 from public.fund_advances
    where id = test_advance_id and amount = 700 and settled_amount = 0
  ) then
    raise exception 'fund expense did not create the expected 700 advance';
  end if;

  perform set_config('request.jwt.claim.sub', owner_user_id::text, true);
  result := public.create_group_fund_collection_round_v3(
    test_group_id, 'offset collection', 1500, current_date, true
  );
  select round.id, entry.id into test_round_id, test_entry_id
  from public.fund_collection_rounds round
  join public.fund_collection_entries entry on entry.round_id = round.id
  where round.group_id = test_group_id and round.status = 'open'
    and entry.member_id = advance_member_id;
  if not exists (
    select 1
    from public.fund_collection_advance_offsets advance_offset
    where advance_offset.entry_id = test_entry_id and advance_offset.advance_id = test_advance_id
      and advance_offset.amount = 700 and advance_offset.status = 'pending'
  ) then
    raise exception 'collection did not reserve the member advance';
  end if;
  if (select (entry->>'cashAmount')::bigint
      from jsonb_array_elements(result->'rounds'->0->'entries') entry
      where entry->>'memberId' = advance_member_id::text) <> 800 then
    raise exception 'collection preview did not expose the 800 cash leg';
  end if;

  perform set_config('request.jwt.claim.sub', advance_user_id::text, true);
  begin
    perform public.record_group_fund_advance_confirmation(
      test_group_id, test_advance_id, 'member', true
    );
  exception when check_violation then
    caught_expected_error := true;
  end;
  if not caught_expected_error then
    raise exception 'reserved advance was allowed to settle twice';
  end if;

  perform public.record_group_fund_collection_confirmation(
    test_group_id, test_round_id, advance_member_id, 'member', true
  );
  perform set_config('request.jwt.claim.sub', owner_user_id::text, true);
  perform public.record_group_fund_collection_confirmation(
    test_group_id, test_round_id, advance_member_id, 'responsible', true
  );
  if not exists (
    select 1 from public.fund_advances
    where id = test_advance_id and status = 'completed'
      and settled_amount = 700 and completed_at is not null
  ) then
    raise exception 'full collection offset did not close the advance';
  end if;
  if (select balance from public.group_funds where group_id = test_group_id) <> 800
    or public.fund_available_cash(test_group_id) <> 800 then
    raise exception 'full offset did not conserve the 800 actual cash';
  end if;
  if not exists (
    select 1 from public.fund_transactions
    where id = (select transaction_id from public.fund_collection_entries where id = test_entry_id)
      and amount_delta = 1500
      and note like '%代墊折抵 700%現金 800%'
  ) then
    raise exception 'collection journal did not preserve gross/offset/cash amounts';
  end if;

  -- Complete the owner's entry so another collection can be opened.
  perform public.record_group_fund_collection_confirmation(
    test_group_id, test_round_id, owner_member_id, 'member', true
  );
  perform public.record_group_fund_collection_confirmation(
    test_group_id, test_round_id, owner_member_id, 'responsible', true
  );

  -- Partial offset: expense uses current cash and leaves a 700 claim; a 500
  -- contribution settles only 500 and keeps 200 open.
  perform set_config('request.jwt.claim.sub', advance_user_id::text, true);
  perform public.record_group_fund_expense_v2(
    test_group_id, 'partial offset expense', 3000, current_date, null,
    advance_member_id, true
  );
  select id into test_advance_id from public.fund_advances
  where group_id = test_group_id and member_id = advance_member_id and status = 'open'
  order by created_at desc limit 1;
  if (select amount from public.fund_advances where id = test_advance_id) <> 700 then
    raise exception 'partial-offset fixture advance is not 700';
  end if;

  perform set_config('request.jwt.claim.sub', owner_user_id::text, true);
  perform public.create_group_fund_collection_round_v3(
    test_group_id, 'partial offset collection', 500, current_date, true
  );
  select round.id, entry.id into test_round_id, test_entry_id
  from public.fund_collection_rounds round
  join public.fund_collection_entries entry on entry.round_id = round.id
  where round.group_id = test_group_id and round.status = 'open'
    and entry.member_id = advance_member_id;
  perform set_config('request.jwt.claim.sub', advance_user_id::text, true);
  perform public.record_group_fund_collection_confirmation(
    test_group_id, test_round_id, advance_member_id, 'member', true
  );
  perform set_config('request.jwt.claim.sub', owner_user_id::text, true);
  perform public.record_group_fund_collection_confirmation(
    test_group_id, test_round_id, advance_member_id, 'responsible', true
  );
  if not exists (
    select 1 from public.fund_advances
    where id = test_advance_id and status = 'open'
      and settled_amount = 500 and amount - settled_amount = 200
  ) then
    raise exception 'partial collection offset did not preserve the remaining claim';
  end if;

  perform public.record_group_fund_collection_confirmation(
    test_group_id, test_round_id, owner_member_id, 'member', true
  );
  perform public.record_group_fund_collection_confirmation(
    test_group_id, test_round_id, owner_member_id, 'responsible', true
  );

  -- Cancelling an offset proposal releases the advance for direct repayment.
  perform public.create_group_fund_collection_round_v3(
    test_group_id, 'cancelled offset collection', 100, current_date, true
  );
  select id into test_round_id from public.fund_collection_rounds
  where group_id = test_group_id and status = 'open';
  perform public.cancel_group_fund_collection_round(test_group_id, test_round_id);
  if exists (
    select 1 from public.fund_collection_advance_offsets advance_offset
    where advance_offset.advance_id = test_advance_id and advance_offset.status = 'pending'
  ) then
    raise exception 'cancelled collection kept an advance reservation';
  end if;

  perform set_config('request.jwt.claim.sub', advance_user_id::text, true);
  perform public.record_group_fund_advance_confirmation(
    test_group_id, test_advance_id, 'member', true
  );
  perform set_config('request.jwt.claim.sub', owner_user_id::text, true);
  perform public.record_group_fund_advance_confirmation(
    test_group_id, test_advance_id, 'responsible', true
  );
  if not exists (
    select 1 from public.fund_advances
    where id = test_advance_id and status = 'completed'
      and settled_amount = amount
  ) then
    raise exception 'released advance could not be repaid directly';
  end if;

  -- The responsible member can explicitly collect cash without applying an
  -- available advance. This is opt-in because offsetting is the safe default.
  perform set_config('request.jwt.claim.sub', advance_user_id::text, true);
  perform public.record_group_fund_expense_v2(
    test_group_id, 'cash-only collection fixture', 700, current_date, null,
    advance_member_id, true
  );
  select id into test_advance_id from public.fund_advances
  where group_id = test_group_id and member_id = advance_member_id and status = 'open'
  order by created_at desc limit 1;
  perform set_config('request.jwt.claim.sub', owner_user_id::text, true);
  result := public.create_group_fund_collection_round_v3(
    test_group_id, 'cash-only collection', 100, current_date, false
  );
  if exists (
    select 1 from public.fund_collection_advance_offsets advance_offset
    where advance_offset.advance_id = test_advance_id and advance_offset.status = 'pending'
  ) or (select (entry->>'cashAmount')::bigint
        from jsonb_array_elements(result->'rounds'->0->'entries') entry
        where entry->>'memberId' = advance_member_id::text) <> 100 then
    raise exception 'cash-only collection unexpectedly reserved an advance';
  end if;

  delete from public.ledger_groups where id = test_group_id;
end;
$$;

select pass('fund advance offsets conserve cash and liability totals');
select * from finish();
rollback;
