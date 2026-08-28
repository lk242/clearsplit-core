-- Deleting a ledger must remain correct as new dependent tables are added.
-- Delete the ledger root and let declared foreign-key cascades own the graph.
-- Audit triggers skip only nested cascade deletes; direct financial deletes
-- remain audited normally and callers cannot opt out with a request flag.

create or replace function public.write_audit_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  row_group_id uuid := coalesce(new.group_id, old.group_id);
  row_entity_id text;
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
    return old;
  end if;
  row_entity_id := coalesce(new.id::text, old.id::text);
  insert into public.audit_events (
    group_id, actor_user_id, entity_type, entity_id, action, old_data, new_data
  ) values (
    row_group_id,
    (select auth.uid()),
    tg_argv[0],
    row_entity_id,
    lower(tg_op),
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end
  );
  return coalesce(new, old);
end;
$$;

create or replace function public.write_share_audit_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
    return old;
  end if;
  insert into public.audit_events (
    group_id, actor_user_id, entity_type, entity_id, action, old_data, new_data
  ) values (
    coalesce(new.group_id, old.group_id),
    (select auth.uid()),
    'expense_share',
    coalesce(new.expense_id, old.expense_id)::text || ':' || coalesce(new.member_id, old.member_id)::text,
    lower(tg_op),
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end
  );
  return coalesce(new, old);
end;
$$;

create or replace function public.write_financial_audit_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  old_json jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  new_json jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  row_json jsonb := coalesce(new_json, old_json);
  row_group_id uuid := (row_json->>'group_id')::uuid;
  row_entity_id text;
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
    return old;
  end if;
  row_entity_id := coalesce(
    row_json->>'id',
    (row_json->>'expense_id') || ':' || (row_json->>'debtor_member_id'),
    (row_json->>'transaction_id') || ':' || (row_json->>'member_id'),
    (row_json->>'round_id') || ':' || (row_json->>'member_id'),
    (row_json->>'group_id') || ':' || (row_json->>'member_id'),
    row_json->>'group_id'
  );
  if row_group_id is null or row_entity_id is null then
    raise exception 'financial audit identity is unavailable' using errcode = '23514';
  end if;
  insert into public.audit_events (
    group_id, actor_user_id, entity_type, entity_id, action, old_data, new_data
  ) values (
    row_group_id, (select auth.uid()), tg_argv[0], row_entity_id,
    lower(tg_op), old_json, new_json
  );
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

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
values (36, 'transactional cascade-safe ledger deletion');
