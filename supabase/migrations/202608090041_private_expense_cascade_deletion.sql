-- A root-ledger delete cascades into private expenses after the ledger row is
-- no longer visible to authority lookups. Skip the per-expense write check
-- only for the exact group marked by the ledger BEFORE DELETE trigger.

create or replace function public.enforce_private_expense_write_authority()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
begin
  if tg_op = 'DELETE'
    and public.is_marked_ledger_cascade_delete(old.group_id) then
    return old;
  end if;

  if current_user_id is null then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;
  if tg_op = 'UPDATE'
    and current_setting('clearsplit.private_confirmation', true) = 'on'
    and public.is_group_member(old.group_id)
    and new.title is not distinct from old.title
    and new.amount is not distinct from old.amount
    and new.category is not distinct from old.category
    and new.payer_member_id is not distinct from old.payer_member_id
    and new.split_mode is not distinct from old.split_mode
    and new.expense_date is not distinct from old.expense_date
    and new.note is not distinct from old.note
    and new.created_by is not distinct from old.created_by then
    return new;
  end if;
  if current_user_id is null or not (
    public.is_group_owner(old.group_id)
    or old.created_by = current_user_id
    or exists (
      select 1 from public.members payer
      where payer.group_id = old.group_id
        and payer.id = old.payer_member_id
        and payer.user_id = current_user_id
    )
  ) then
    raise exception 'only the creator, payer, or responsible member may change this expense'
      using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

insert into public.app_schema_versions (version, name)
values (41, 'private expense cascade-safe ledger deletion');
