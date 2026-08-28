-- Financial audit entity identities must parenthesize every JSON text lookup
-- before concatenation. PostgreSQL otherwise associates the generic operators
-- from left to right and can attempt to apply ->> to an already-concatenated
-- text value, which rolls back the financial transaction being audited.

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

revoke all on function public.write_financial_audit_event()
  from public, anon, authenticated;

insert into public.app_schema_versions (version, name)
values (31, 'fix financial audit entity identity composition');
