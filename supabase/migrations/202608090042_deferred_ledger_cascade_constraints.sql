-- Several dependent rows reference both the ledger root and a member or
-- transaction. PostgreSQL may visit the member side before the other cascade
-- has removed the dependent row. Keep these constraints immediate for normal
-- writes, but make them deferrable so the root-delete RPC can validate the
-- complete graph at transaction end.

alter table public.expense_receipts
  alter constraint expense_receipts_member_same_group_fk
  deferrable initially immediate;
alter table public.expense_shares
  alter constraint expense_shares_member_same_group_fk
  deferrable initially immediate;
alter table public.expenses
  alter constraint expenses_payer_same_group_fk
  deferrable initially immediate;
alter table public.fund_advances
  alter constraint fund_advance_member_same_group_fk
  deferrable initially immediate;
alter table public.fund_collection_advance_offsets
  alter constraint fund_collection_offset_member_same_group_fk
  deferrable initially immediate;
alter table public.fund_transactions
  alter constraint fund_transaction_source_member_same_group_fk
  deferrable initially immediate;
alter table public.line_expense_drafts
  alter constraint line_draft_payer_same_group_fk
  deferrable initially immediate;
alter table public.line_expense_drafts
  alter constraint line_expense_drafts_confirmed_expense_id_fkey
  deferrable initially immediate;
alter table public.line_fund_expense_drafts
  alter constraint line_fund_draft_submitter_same_group_fk
  deferrable initially immediate;
alter table public.line_fund_expense_drafts
  alter constraint line_fund_expense_drafts_confirmed_transaction_id_fkey
  deferrable initially immediate;
alter table public.private_expense_confirmation_events
  alter constraint private_confirmation_member_same_group_fk
  deferrable initially immediate;
alter table public.settlement_confirmation_events
  alter constraint settlement_member_same_group_fk
  deferrable initially immediate;

create or replace function public.delete_ledger_group(
  p_group_id uuid,
  p_confirmation text,
  p_setup_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  current_user_id uuid := (select auth.uid());
  group_record public.ledger_groups;
  deleted_member_count integer;
  deleted_expense_count integer;
  receipt_id uuid;
begin
  select * into group_record
  from public.ledger_groups
  where id = p_group_id
  for update;
  if not found or current_user_id is null then
    raise exception 'ledger is unavailable' using errcode = '42501';
  end if;
  if group_record.responsible_member_id is null then
    if not public.has_valid_ledger_setup_token(p_group_id, p_setup_token) then
      raise exception 'valid setup key required' using errcode = '42501';
    end if;
  elsif not public.is_group_owner(p_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;
  if p_confirmation is distinct from group_record.name then
    raise exception 'ledger name confirmation does not match' using errcode = '22023';
  end if;

  select count(*) into deleted_member_count
  from public.members where group_id = p_group_id;
  select count(*) into deleted_expense_count
  from public.expenses where group_id = p_group_id;

  insert into public.ledger_deletion_receipts (
    deleted_group_id, group_name_hash, deleted_by, member_count, expense_count
  ) values (
    p_group_id,
    extensions.digest(group_record.name, 'sha256'),
    current_user_id,
    deleted_member_count,
    deleted_expense_count
  ) returning id into receipt_id;

  set constraints all deferred;
  delete from public.ledger_groups where id = p_group_id;
  if not found then
    raise exception 'ledger deletion conflicted; retry' using errcode = '40001';
  end if;

  return jsonb_build_object(
    'receiptId', receipt_id,
    'deletedGroupId', p_group_id,
    'memberCount', deleted_member_count,
    'expenseCount', deleted_expense_count,
    'deletedAt', now()
  );
end;
$$;

revoke all on function public.delete_ledger_group(uuid, text, text)
  from public, anon;
grant execute on function public.delete_ledger_group(uuid, text, text)
  to authenticated;

insert into public.app_schema_versions (version, name)
values (42, 'deferred ledger cascade constraints');
