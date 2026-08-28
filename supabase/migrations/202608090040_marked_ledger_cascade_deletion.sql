-- PostgreSQL reports cascaded user triggers at depth one on this schema, so
-- trigger depth cannot safely identify a root-ledger cascade. Mark the exact
-- group in a transaction-local setting before the root delete; callers still
-- cannot suppress audit rows for ordinary financial deletes.

create function public.mark_ledger_cascade_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform set_config('app.deleting_ledger_group_id', old.id::text, true);
  return old;
end;
$$;

revoke all on function public.mark_ledger_cascade_delete()
  from public, anon, authenticated;

create trigger ledger_groups_mark_cascade_delete
before delete on public.ledger_groups
for each row execute function public.mark_ledger_cascade_delete();

create function public.is_marked_ledger_cascade_delete(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    nullif(current_setting('app.deleting_ledger_group_id', true), '')::uuid = p_group_id,
    false
  );
$$;

revoke all on function public.is_marked_ledger_cascade_delete(uuid)
  from public, anon, authenticated;

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
  if tg_op = 'DELETE' and public.is_marked_ledger_cascade_delete(row_group_id) then
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
declare
  row_group_id uuid := coalesce(new.group_id, old.group_id);
begin
  if tg_op = 'DELETE' and public.is_marked_ledger_cascade_delete(row_group_id) then
    return old;
  end if;
  insert into public.audit_events (
    group_id, actor_user_id, entity_type, entity_id, action, old_data, new_data
  ) values (
    row_group_id,
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
  if tg_op = 'DELETE' and public.is_marked_ledger_cascade_delete(row_group_id) then
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

insert into public.app_schema_versions (version, name)
values (40, 'marked cascade-safe ledger deletion');
