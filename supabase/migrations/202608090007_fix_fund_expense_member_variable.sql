-- Repair the deployed fund expense RPC's ambiguous loop variable.

create or replace function public.record_group_fund_expense(
  p_group_id uuid,
  p_title text,
  p_amount bigint,
  p_participant_ids uuid[],
  p_effective_date date,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  fund_record public.group_funds;
  participant_count integer;
  base_share bigint;
  remainder bigint;
  target_member_id uuid;
  member_index integer := 0;
  share_amount bigint;
  transaction_id uuid;
begin
  if current_user_id is null or not public.is_group_member(p_group_id) then
    raise exception 'fund access denied' using errcode = '42501';
  end if;
  if char_length(trim(p_title)) not between 1 and 120 or p_amount <= 0 then
    raise exception 'invalid fund expense' using errcode = '22023';
  end if;
  participant_count := cardinality(p_participant_ids);
  if participant_count < 1 or (select count(*) from public.members where group_id = p_group_id and id = any(p_participant_ids)) <> participant_count then
    raise exception 'invalid fund participants' using errcode = '23514';
  end if;
  select * into fund_record from public.group_funds where group_id = p_group_id for update;
  if not found or fund_record.balance < p_amount then
    raise exception 'insufficient group fund balance' using errcode = '23514';
  end if;

  update public.group_funds set balance = balance - p_amount, version = version + 1 where group_id = p_group_id;
  insert into public.fund_transactions (
    group_id, transaction_type, title, amount_delta, balance_after, effective_date, note, created_by
  ) values (
    p_group_id, 'expense', trim(p_title), -p_amount, fund_record.balance - p_amount,
    p_effective_date, nullif(trim(p_note), ''), current_user_id
  ) returning id into transaction_id;

  base_share := p_amount / participant_count;
  remainder := p_amount % participant_count;
  foreach target_member_id in array p_participant_ids loop
    share_amount := base_share + case when member_index < remainder then 1 else 0 end;
    update public.fund_member_accounts
      set balance = balance - share_amount, consumed_total = consumed_total + share_amount
      where group_id = p_group_id and fund_member_accounts.member_id = target_member_id;
    if share_amount <> 0 then
      insert into public.fund_transaction_lines (transaction_id, group_id, member_id, amount_delta)
      values (transaction_id, p_group_id, target_member_id, -share_amount);
    end if;
    member_index := member_index + 1;
  end loop;
  return public.get_group_fund(p_group_id);
end;
$$;

revoke all on function public.record_group_fund_expense(uuid, text, bigint, uuid[], date, text) from public, anon;
grant execute on function public.record_group_fund_expense(uuid, text, bigint, uuid[], date, text) to authenticated;
