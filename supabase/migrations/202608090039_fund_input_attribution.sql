-- Every public-fund transaction keeps the member and channel that supplied
-- the input. For an advance, that source is deliberately separate from the
-- actual member who paid, so on-behalf records remain auditable.

alter table public.fund_transactions
  add column source_member_id uuid,
  add column source_type text not null default 'legacy'
    check (source_type in ('legacy', 'web', 'line')),
  add constraint fund_transaction_source_member_same_group_fk
    foreign key (source_member_id, group_id)
    references public.members(id, group_id);

update public.fund_transactions transaction
set source_member_id = member.id
from public.members member
where member.group_id = transaction.group_id
  and member.user_id = transaction.created_by;

create function public.set_fund_transaction_source()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  configured_member_id uuid;
  configured_source_type text;
begin
  configured_member_id := nullif(current_setting('app.fund_source_member_id', true), '')::uuid;
  configured_source_type := nullif(current_setting('app.fund_source_type', true), '');

  if configured_member_id is not null then
    new.source_member_id := configured_member_id;
    new.source_type := coalesce(configured_source_type, 'web');
  else
    select member.id into new.source_member_id
    from public.members member
    where member.group_id = new.group_id and member.user_id = (select auth.uid());
    new.source_type := case when new.source_member_id is null then 'legacy' else 'web' end;
  end if;
  return new;
end;
$$;

revoke all on function public.set_fund_transaction_source()
  from public, anon, authenticated;

create trigger fund_transactions_set_source
before insert on public.fund_transactions
for each row execute function public.set_fund_transaction_source();

create function public.record_group_fund_expense_v3(
  p_group_id uuid,
  p_title text,
  p_amount bigint,
  p_effective_date date,
  p_note text default null,
  p_advance_member_id uuid default null,
  p_use_available_fund boolean default true,
  p_source_member_id uuid default null,
  p_source_type text default 'web'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  current_member_id uuid;
  source_member_id uuid;
  result jsonb;
begin
  select member.id into current_member_id
  from public.members member
  where member.group_id = p_group_id and member.user_id = current_user_id;
  source_member_id := coalesce(p_source_member_id, current_member_id);

  if current_user_id is null or current_member_id is null
    or p_source_type not in ('web', 'line')
    or source_member_id is null
    or not exists (
      select 1 from public.members
      where group_id = p_group_id and id = source_member_id
    ) then
    raise exception 'invalid public fund input source' using errcode = '22023';
  end if;
  if p_source_type = 'web' and source_member_id <> current_member_id then
    raise exception 'web input source must be the current member' using errcode = '42501';
  end if;
  if p_source_type = 'line' and not public.is_group_owner(p_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;

  perform set_config('app.fund_source_member_id', source_member_id::text, true);
  perform set_config('app.fund_source_type', p_source_type, true);
  result := public.record_group_fund_expense_v2(
    p_group_id, p_title, p_amount, p_effective_date, p_note,
    p_advance_member_id, p_use_available_fund
  );
  perform set_config('app.fund_source_member_id', '', true);
  perform set_config('app.fund_source_type', '', true);
  return result;
end;
$$;

revoke execute on function public.record_group_fund_expense_v2(
  uuid, text, bigint, date, text, uuid, boolean
) from authenticated;
revoke all on function public.record_group_fund_expense_v3(
  uuid, text, bigint, date, text, uuid, boolean, uuid, text
) from public, anon;
grant execute on function public.record_group_fund_expense_v3(
  uuid, text, bigint, date, text, uuid, boolean, uuid, text
) to authenticated;

alter function public.confirm_line_fund_expense_draft(uuid, uuid, boolean)
  rename to confirm_line_fund_expense_draft_v29;
revoke all on function public.confirm_line_fund_expense_draft_v29(uuid, uuid, boolean)
  from public, anon, authenticated;

create function public.confirm_line_fund_expense_draft(
  p_draft_id uuid,
  p_advance_member_id uuid default null,
  p_allow_duplicate boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  draft_record public.line_fund_expense_drafts;
  result jsonb;
begin
  select * into draft_record
  from public.line_fund_expense_drafts
  where id = p_draft_id;
  if not found or current_user_id is null or not public.is_group_owner(draft_record.group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;

  perform set_config('app.fund_source_member_id', draft_record.submitted_member_id::text, true);
  perform set_config('app.fund_source_type', 'line', true);
  result := public.confirm_line_fund_expense_draft_v29(
    p_draft_id, p_advance_member_id, p_allow_duplicate
  );
  perform set_config('app.fund_source_member_id', '', true);
  perform set_config('app.fund_source_type', '', true);

  if result->>'status' = 'confirmed' then
    return jsonb_set(result, '{fund}', public.get_group_fund(draft_record.group_id));
  end if;
  return result;
end;
$$;

revoke all on function public.confirm_line_fund_expense_draft(uuid, uuid, boolean)
  from public, anon;
grant execute on function public.confirm_line_fund_expense_draft(uuid, uuid, boolean)
  to authenticated;

alter function public.get_group_fund(uuid) rename to get_group_fund_v38;
revoke all on function public.get_group_fund_v38(uuid)
  from public, anon, authenticated;

create function public.get_group_fund(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
  transaction_items jsonb;
  advance_items jsonb;
begin
  result := public.get_group_fund_v38(p_group_id);
  if coalesce((result->>'configured')::boolean, false) is false then
    return result;
  end if;

  select coalesce(jsonb_agg(item.value || jsonb_build_object(
    'sourceMemberId', transaction.source_member_id,
    'sourceName', source_member.display_name,
    'sourceType', transaction.source_type
  ) order by item.ordinality), '[]'::jsonb)
  into transaction_items
  from jsonb_array_elements(coalesce(result->'transactions', '[]'::jsonb))
    with ordinality item(value, ordinality)
  join public.fund_transactions transaction
    on transaction.id = (item.value->>'id')::uuid
  left join public.members source_member
    on source_member.id = transaction.source_member_id
      and source_member.group_id = transaction.group_id;

  select coalesce(jsonb_agg(item.value || jsonb_build_object(
    'recordedByMemberId', transaction.source_member_id,
    'recordedByName', source_member.display_name,
    'sourceType', transaction.source_type,
    'isOnBehalf', transaction.source_member_id is not null
      and transaction.source_member_id <> advance.member_id
  ) order by item.ordinality), '[]'::jsonb)
  into advance_items
  from jsonb_array_elements(coalesce(result->'advances', '[]'::jsonb))
    with ordinality item(value, ordinality)
  join public.fund_advances advance on advance.id = (item.value->>'id')::uuid
  join public.fund_transactions transaction on transaction.id = advance.transaction_id
  left join public.members source_member
    on source_member.id = transaction.source_member_id
      and source_member.group_id = transaction.group_id;

  return jsonb_set(
    jsonb_set(result, '{transactions}', transaction_items),
    '{advances}', advance_items
  );
end;
$$;

revoke all on function public.get_group_fund(uuid) from public, anon;
grant execute on function public.get_group_fund(uuid) to authenticated;

insert into public.app_schema_versions (version, name)
values (39, 'public-fund input attribution');
