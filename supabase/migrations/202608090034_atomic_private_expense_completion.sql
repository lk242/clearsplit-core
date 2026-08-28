-- A private obligation's second confirmation must set completed_at in the
-- same statement. Otherwise the completion-state CHECK sees a transient row
-- with both confirmations present but no completion timestamp.

create or replace function public.record_private_expense_confirmation(
  p_group_id uuid,
  p_expense_id uuid,
  p_debtor_member_id uuid,
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
  expense_record public.expenses;
  debtor_share public.expense_shares;
  receipt_record public.expense_receipts;
  outstanding_count integer;
  confirmation_time timestamptz;
  state_changed boolean := false;
  just_completed boolean := false;
begin
  if current_user_id is null or p_actor_role not in ('debtor', 'payer')
    or p_confirm is null then
    raise exception 'invalid private expense confirmation' using errcode = '22023';
  end if;
  select id into current_member_id from public.members
  where group_id = p_group_id and user_id = current_user_id;

  select * into expense_record from public.expenses
  where id = p_expense_id and group_id = p_group_id for update;
  if not found then raise exception 'expense is unavailable' using errcode = '22023'; end if;
  if p_debtor_member_id = expense_record.payer_member_id then
    raise exception 'payer share does not require settlement' using errcode = '22023';
  end if;
  if p_actor_role = 'debtor' and current_member_id is distinct from p_debtor_member_id then
    raise exception 'debtor confirmation required' using errcode = '42501';
  end if;
  if p_actor_role = 'payer' and current_member_id is distinct from expense_record.payer_member_id then
    raise exception 'payer confirmation required' using errcode = '42501';
  end if;

  select * into debtor_share from public.expense_shares
  where expense_id = p_expense_id and group_id = p_group_id
    and member_id = p_debtor_member_id;
  if not found or debtor_share.amount <= 0 then
    raise exception 'expense debtor is unavailable' using errcode = '22023';
  end if;

  select * into receipt_record from public.expense_receipts
  where expense_id = p_expense_id and debtor_member_id = p_debtor_member_id
  for update;

  confirmation_time := now();
  if not found then
    if p_confirm then
      insert into public.expense_receipts (
        expense_id, group_id, debtor_member_id, amount,
        paid_at, paid_confirmed_by, received_at, received_confirmed_by
      ) values (
        p_expense_id, p_group_id, p_debtor_member_id, debtor_share.amount,
        case when p_actor_role = 'debtor' then confirmation_time end,
        case when p_actor_role = 'debtor' then current_user_id end,
        case when p_actor_role = 'payer' then confirmation_time end,
        case when p_actor_role = 'payer' then current_user_id end
      ) returning * into receipt_record;
      state_changed := true;
    end if;
  elsif p_actor_role = 'debtor' then
    if p_confirm and receipt_record.paid_at is null then
      update public.expense_receipts
      set amount = debtor_share.amount,
          paid_at = confirmation_time,
          paid_confirmed_by = current_user_id,
          completed_at = case
            when receipt_record.received_at is not null then confirmation_time
            else null
          end
      where expense_id = p_expense_id and debtor_member_id = p_debtor_member_id
      returning * into receipt_record;
      state_changed := true;
      just_completed := receipt_record.completed_at is not null;
    elsif not p_confirm and receipt_record.paid_at is not null then
      update public.expense_receipts
      set paid_at = null, paid_confirmed_by = null, completed_at = null
      where expense_id = p_expense_id and debtor_member_id = p_debtor_member_id
      returning * into receipt_record;
      state_changed := true;
    end if;
  else
    if p_confirm and receipt_record.received_at is null then
      update public.expense_receipts
      set amount = debtor_share.amount,
          received_at = confirmation_time,
          received_confirmed_by = current_user_id,
          completed_at = case
            when receipt_record.paid_at is not null then confirmation_time
            else null
          end
      where expense_id = p_expense_id and debtor_member_id = p_debtor_member_id
      returning * into receipt_record;
      state_changed := true;
      just_completed := receipt_record.completed_at is not null;
    elsif not p_confirm and receipt_record.received_at is not null then
      update public.expense_receipts
      set received_at = null, received_confirmed_by = null, completed_at = null
      where expense_id = p_expense_id and debtor_member_id = p_debtor_member_id
      returning * into receipt_record;
      state_changed := true;
    end if;
  end if;

  if state_changed and receipt_record.paid_at is null and receipt_record.received_at is null then
    delete from public.expense_receipts
    where expense_id = p_expense_id and debtor_member_id = p_debtor_member_id;
  end if;

  if state_changed then
    insert into public.private_expense_confirmation_events (
      expense_id, group_id, debtor_member_id, amount,
      actor_user_id, actor_role, action
    ) values (
      p_expense_id, p_group_id, p_debtor_member_id, debtor_share.amount,
      current_user_id, p_actor_role, case when p_confirm then 'confirm' else 'revoke' end
    );
    if just_completed then
      insert into public.private_expense_confirmation_events (
        expense_id, group_id, debtor_member_id, amount,
        actor_user_id, actor_role, action
      ) values (
        p_expense_id, p_group_id, p_debtor_member_id, debtor_share.amount,
        current_user_id, p_actor_role, 'complete'
      );
    end if;
  end if;

  select count(*) into outstanding_count
  from public.expense_shares share
  where share.expense_id = p_expense_id
    and share.member_id <> expense_record.payer_member_id
    and share.amount > 0
    and not exists (
      select 1 from public.expense_receipts receipt
      where receipt.expense_id = share.expense_id
        and receipt.debtor_member_id = share.member_id
        and receipt.amount = share.amount
        and receipt.paid_at is not null
        and receipt.received_at is not null
        and receipt.completed_at is not null
    );

  if state_changed then
    perform set_config('clearsplit.private_confirmation', 'on', true);
    update public.expenses
    set status = case when outstanding_count = 0 then 'resolved' else 'active' end,
        resolved_at = case when outstanding_count = 0 then coalesce(resolved_at, now()) else null end,
        version = version + 1,
        updated_by = current_user_id
    where id = p_expense_id;
  end if;

  return public.private_expense_json(p_expense_id);
end;
$$;

insert into public.app_schema_versions (version, name)
values (34, 'atomic private-expense second confirmation');
