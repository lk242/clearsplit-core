-- A real member selected as the responsible member must receive the same
-- management authority as the bootstrap creator. The creator remains an
-- administrative fallback, but is never inserted into the financial roster.

create or replace function public.is_group_owner(target_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select (
    exists (
      select 1
      from public.ledger_groups
      where id = target_group_id and created_by = (select auth.uid())
    )
    or exists (
      select 1
      from public.members
      where group_id = target_group_id
        and user_id = (select auth.uid())
        and role = 'owner'
    )
  );
$$;

create or replace function public.get_ledger_access(p_group_id uuid)
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
  if not found or not public.is_group_member(p_group_id) then
    raise exception 'ledger access denied' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'groupId', group_record.id,
    'groupName', group_record.name,
    'isOwner', public.is_group_owner(p_group_id),
    'memberCount', (select count(*) from public.members where group_id = p_group_id),
    'expenseCount', (select count(*) from public.expenses where group_id = p_group_id)
  );
end;
$$;

create or replace function public.delete_ledger_group(
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
  if not found or current_user_id is null or not public.is_group_owner(p_group_id) then
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

revoke all on function public.is_group_owner(uuid) from public;
revoke all on function public.get_ledger_access(uuid) from public, anon;
revoke all on function public.delete_ledger_group(uuid, text) from public, anon;
grant execute on function public.is_group_owner(uuid) to authenticated;
grant execute on function public.get_ledger_access(uuid) to authenticated;
grant execute on function public.delete_ledger_group(uuid, text) to authenticated;
