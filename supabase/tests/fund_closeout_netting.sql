-- The cash=100, expense=800 and member-advance=700 boundary case must close
-- by netting each member's account position against the advance. The fixture
-- uses three real auth users and rolls back completely.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(1);

drop index if exists public.ledger_groups_single_active_idx;

do $$
declare
  test_user_ids uuid[];
  owner_user_id uuid;
  other_user_id uuid;
  advance_user_id uuid;
  test_group_id uuid := gen_random_uuid();
  owner_member_id uuid := gen_random_uuid();
  other_member_id uuid := gen_random_uuid();
  advance_member_id uuid := gen_random_uuid();
  test_advance_id uuid;
  settlement_record record;
  caught_expected_error boolean := false;
begin
  select array_agg(id order by created_at, id) into test_user_ids
  from (
    select id, created_at from auth.users order by created_at, id limit 3
  ) users;
  if coalesce(cardinality(test_user_ids), 0) <> 3 then
    raise exception 'fund closeout netting test requires three auth users';
  end if;
  owner_user_id := test_user_ids[1];
  other_user_id := test_user_ids[2];
  advance_user_id := test_user_ids[3];

  insert into public.ledger_groups (id, name, created_by)
  values (test_group_id, 'fund closeout netting fixture', owner_user_id);
  insert into public.members (id, group_id, user_id, role, display_name, color, created_at)
  values
    (owner_member_id, test_group_id, owner_user_id, 'owner', 'net owner', '#225577', now()),
    (other_member_id, test_group_id, other_user_id, 'member', 'net member', '#557722', now() + interval '1 millisecond'),
    (advance_member_id, test_group_id, advance_user_id, 'member', 'net advance', '#772255', now() + interval '2 milliseconds');
  update public.ledger_groups
  set responsible_member_id = owner_member_id
  where id = test_group_id;

  perform set_config('request.jwt.claim.sub', owner_user_id::text, true);
  perform public.initialize_group_fund(test_group_id, 100, current_date);
  perform set_config('request.jwt.claim.sub', advance_user_id::text, true);
  perform public.record_group_fund_expense_v2(
    test_group_id, 'net closeout expense', 800, current_date, null,
    advance_member_id, true
  );
  select id into test_advance_id
  from public.fund_advances
  where group_id = test_group_id and member_id = advance_member_id and status = 'open';
  if test_advance_id is null or not exists (
    select 1 from public.fund_advances
    where id = test_advance_id and amount = 700 and settled_amount = 0
  ) then
    raise exception 'closeout fixture did not create a 700 advance';
  end if;
  if (select balance from public.group_funds where group_id = test_group_id) <> -700
    or public.fund_available_cash(test_group_id) <> 0 then
    raise exception 'closeout fixture did not preserve zero physical cash';
  end if;

  perform set_config('request.jwt.claim.sub', other_user_id::text, true);
  begin
    perform public.start_group_fund_closeout(test_group_id);
  exception when insufficient_privilege then
    caught_expected_error := true;
  end;
  if not caught_expected_error then
    raise exception 'non-responsible member started closeout';
  end if;

  perform set_config('request.jwt.claim.sub', owner_user_id::text, true);
  perform public.start_group_fund_closeout(test_group_id);
  if (select count(*) from public.fund_settlement_confirmations
      where group_id = test_group_id and status = 'pending') <> 3 then
    raise exception 'closeout did not freeze all three member positions';
  end if;
  if exists (
    select 1 from public.fund_settlement_confirmations
    where group_id = test_group_id and status = 'pending'
      and (
        amount <> abs(account_balance + advance_amount)
        or advance_offset_amount <> least(greatest(-account_balance, 0), advance_amount)
        or (direction = 'refund') <> (account_balance + advance_amount > 0)
        or (direction = 'top_up') <> (account_balance + advance_amount < 0)
        or (direction = 'offset') <> (account_balance + advance_amount = 0)
      )
  ) then
    raise exception 'closeout snapshot does not conserve gross and net legs';
  end if;
  if not exists (
    select 1 from public.fund_settlement_confirmations
    where group_id = test_group_id and member_id = advance_member_id
      and status = 'pending' and direction = 'refund'
      and advance_amount = 700 and advance_offset_amount in (233, 234)
      and amount in (466, 467)
  ) then
    raise exception 'advance member did not receive the expected 466/467 net refund';
  end if;

  caught_expected_error := false;
  perform set_config('request.jwt.claim.sub', advance_user_id::text, true);
  begin
    perform public.record_group_fund_advance_confirmation(
      test_group_id, test_advance_id, 'member', true
    );
  exception when check_violation then
    caught_expected_error := true;
  end;
  if not caught_expected_error then
    raise exception 'direct advance repayment changed a frozen closeout';
  end if;

  perform public.record_group_fund_settlement_confirmation(
    test_group_id, advance_member_id, 'member', true
  );
  caught_expected_error := false;
  perform set_config('request.jwt.claim.sub', owner_user_id::text, true);
  begin
    perform public.record_group_fund_settlement_confirmation(
      test_group_id, advance_member_id, 'responsible', true
    );
  exception when check_violation then
    caught_expected_error := true;
  end;
  if not caught_expected_error then
    raise exception 'advance refund completed before required member top-ups';
  end if;

  for settlement_record in
    select confirmation.member_id, member.user_id
    from public.fund_settlement_confirmations confirmation
    join public.members member
      on member.id = confirmation.member_id and member.group_id = confirmation.group_id
    where confirmation.group_id = test_group_id
      and confirmation.status = 'pending' and confirmation.direction = 'top_up'
    order by member.created_at, member.id
  loop
    perform set_config('request.jwt.claim.sub', settlement_record.user_id::text, true);
    perform public.record_group_fund_settlement_confirmation(
      test_group_id, settlement_record.member_id, 'member', true
    );
    perform set_config('request.jwt.claim.sub', owner_user_id::text, true);
    perform public.record_group_fund_settlement_confirmation(
      test_group_id, settlement_record.member_id, 'responsible', true
    );
  end loop;

  if public.fund_available_cash(test_group_id) not in (466, 467) then
    raise exception 'member top-ups did not create the required refund cash';
  end if;
  perform public.record_group_fund_settlement_confirmation(
    test_group_id, advance_member_id, 'responsible', true
  );

  if exists (
      select 1 from public.fund_member_accounts
      where group_id = test_group_id and balance <> 0
    ) or exists (
      select 1 from public.fund_advances
      where group_id = test_group_id and status = 'open'
    ) or (select balance from public.group_funds where group_id = test_group_id) <> 0
    or public.fund_available_cash(test_group_id) <> 0 then
    raise exception 'net closeout did not zero accounts, advances and cash';
  end if;
  if not exists (
    select 1 from public.fund_advances
    where id = test_advance_id and status = 'completed'
      and settled_amount = 700 and completed_at is not null
  ) then
    raise exception 'net closeout did not complete the advance';
  end if;
  if (select count(*) from public.fund_settlement_confirmations
      where group_id = test_group_id and status = 'completed') <> 3 then
    raise exception 'not all closeout entries completed with dual confirmation';
  end if;

  perform public.complete_group_fund_closeout(test_group_id);
  if (select status from public.group_funds where group_id = test_group_id) <> 'closed' then
    raise exception 'balanced closeout could not be closed';
  end if;

  delete from public.ledger_groups where id = test_group_id;
end;
$$;

select pass('fund closeout netting remains balanced');
select * from finish();
rollback;
