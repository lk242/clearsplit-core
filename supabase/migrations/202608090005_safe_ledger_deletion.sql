-- Owner-only full-ledger deletion. The financial rows are removed in an
-- explicit dependency order, while a privacy-safe deletion receipt remains.

create table public.ledger_deletion_receipts (
  id uuid primary key default gen_random_uuid(),
  deleted_group_id uuid not null,
  group_name_hash bytea not null,
  deleted_by uuid references auth.users(id) on delete set null,
  member_count integer not null check (member_count >= 0),
  expense_count integer not null check (expense_count >= 0),
  deleted_at timestamptz not null default now()
);

alter table public.ledger_deletion_receipts enable row level security;
revoke all on public.ledger_deletion_receipts from public, anon, authenticated;

create function public.get_ledger_access(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  group_record public.ledger_groups;
begin
  if current_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select * into group_record from public.ledger_groups where id = p_group_id;
  if not found or not (
    group_record.created_by = current_user_id or public.is_group_member(p_group_id)
  ) then
    raise exception 'ledger access denied' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'groupId', group_record.id,
    'groupName', group_record.name,
    'isOwner', group_record.created_by = current_user_id,
    'memberCount', (select count(*) from public.members where group_id = p_group_id),
    'expenseCount', (select count(*) from public.expenses where group_id = p_group_id)
  );
end;
$$;

create function public.delete_ledger_group(
  p_group_id uuid,
  p_confirmation text
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
  select * into group_record from public.ledger_groups where id = p_group_id for update;
  if not found or current_user_id is null or group_record.created_by <> current_user_id then
    raise exception 'group owner permission required' using errcode = '42501';
  end if;
  if p_confirmation is distinct from group_record.name then
    raise exception 'ledger name confirmation does not match' using errcode = '22023';
  end if;

  select count(*) into deleted_member_count from public.members where group_id = p_group_id;
  select count(*) into deleted_expense_count from public.expenses where group_id = p_group_id;

  insert into public.ledger_deletion_receipts (
    deleted_group_id, group_name_hash, deleted_by, member_count, expense_count
  ) values (
    p_group_id,
    extensions.digest(group_record.name, 'sha256'),
    current_user_id,
    deleted_member_count,
    deleted_expense_count
  ) returning id into receipt_id;

  delete from public.line_expense_drafts where group_id = p_group_id;
  delete from public.line_group_bindings where group_id = p_group_id;
  delete from public.line_bind_codes where group_id = p_group_id;
  delete from public.settlement_confirmation_events where group_id = p_group_id;
  delete from public.expense_shares where group_id = p_group_id;
  delete from public.expenses where group_id = p_group_id;
  delete from public.group_invites where group_id = p_group_id;
  delete from public.members where group_id = p_group_id;
  delete from public.audit_events where group_id = p_group_id;
  delete from public.ledger_groups where id = p_group_id;

  return jsonb_build_object(
    'receiptId', receipt_id,
    'deletedGroupId', p_group_id,
    'memberCount', deleted_member_count,
    'expenseCount', deleted_expense_count,
    'deletedAt', now()
  );
end;
$$;

revoke all on function public.get_ledger_access(uuid) from public, anon;
revoke all on function public.delete_ledger_group(uuid, text) from public, anon;
grant execute on function public.get_ledger_access(uuid) to authenticated;
grant execute on function public.delete_ledger_group(uuid, text) to authenticated;
