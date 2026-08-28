-- The balance constraint is deferred until transaction commit. At that point
-- a SECURITY DEFINER fund RPC has returned to the authenticated caller role,
-- so the trigger must retain narrowly scoped read authority itself.

create or replace function public.assert_fund_transaction_balanced()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  target_transaction_id uuid := coalesce(new.transaction_id, old.transaction_id);
  expected_delta bigint;
  allocated_delta bigint;
begin
  select amount_delta into expected_delta
  from public.fund_transactions
  where id = target_transaction_id;

  if expected_delta is null then return null; end if;

  select coalesce(sum(amount_delta), 0) into allocated_delta
  from public.fund_transaction_lines
  where transaction_id = target_transaction_id;

  if expected_delta <> allocated_delta then
    raise exception 'fund transaction % is not balanced: lines %, transaction %',
      target_transaction_id, allocated_delta, expected_delta
      using errcode = '23514';
  end if;
  return null;
end;
$$;

revoke all on function public.assert_fund_transaction_balanced()
  from public, anon, authenticated;
