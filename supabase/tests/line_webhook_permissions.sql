-- Exercise the exact direct-table operations performed by line-webhook while
-- running as service_role. The fixture is rolled back completely.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(1);

drop index if exists public.ledger_groups_single_active_idx;

insert into public.ledger_groups (id, name, created_by)
select
  '00000000-0000-4000-8000-000000000043'::uuid,
  'LINE webhook permission fixture',
  users.id
from auth.users users
order by users.created_at, users.id
limit 1;

insert into public.members (
  id, group_id, user_id, role, display_name, color, line_user_id
)
select
  '00000000-0000-4000-8000-000000000143'::uuid,
  '00000000-0000-4000-8000-000000000043'::uuid,
  users.id,
  'owner',
  'LINE permission member',
  '#225577',
  'U00000000000000000000000000000043'
from auth.users users
order by users.created_at, users.id
limit 1;

update public.ledger_groups
set responsible_member_id = '00000000-0000-4000-8000-000000000143'::uuid
where id = '00000000-0000-4000-8000-000000000043'::uuid;

insert into public.line_group_bindings (
  group_id, line_group_id, bound_by_line_user_id
) values (
  '00000000-0000-4000-8000-000000000043'::uuid,
  'C00000000000000000000000000000043',
  'U00000000000000000000000000000043'
);

set local role service_role;

do $$
declare
  fixture_group_id uuid;
  fixture_member_id uuid;
  fixture_member_name text;
  lease jsonb;
  fixture_draft_id uuid;
begin
  select binding.group_id into fixture_group_id
  from public.line_group_bindings binding
  where binding.line_group_id = 'C00000000000000000000000000000043'
    and binding.active;
  if fixture_group_id is distinct from
    '00000000-0000-4000-8000-000000000043'::uuid then
    raise exception 'service_role could not resolve the active LINE binding';
  end if;

  select member.id, member.display_name
  into fixture_member_id, fixture_member_name
  from public.members member
  where member.group_id = fixture_group_id
    and member.line_user_id = 'U00000000000000000000000000000043';
  if fixture_member_id is null or fixture_member_name is null then
    raise exception 'service_role could not resolve the LINE member';
  end if;

  lease := public.begin_line_webhook_event(
    'line-permission-event-000000000043',
    'line-permission-message-000000000043'
  );
  if coalesce((lease->>'shouldProcess')::boolean, false) is not true then
    raise exception 'service_role could not acquire the webhook lease';
  end if;

  insert into public.line_fund_expense_drafts (
    group_id, webhook_event_id, source_message_id, source_line_user_id,
    submitted_member_id, submitted_display_name, raw_text, title, amount,
    effective_date
  ) values (
    fixture_group_id,
    'line-permission-event-000000000043',
    'line-permission-message-000000000043',
    'U00000000000000000000000000000043',
    fixture_member_id,
    fixture_member_name,
    '#record permission test 43',
    'permission test',
    43,
    current_date
  ) returning id into fixture_draft_id;

  update public.line_fund_expense_drafts
  set raw_text = null,
      status = 'cancelled',
      cancelled_at = now()
  where source_message_id = 'line-permission-message-000000000043'
    and status = 'pending';

  if not exists (
    select 1 from public.line_fund_expense_drafts draft
    where draft.id = fixture_draft_id
      and draft.group_id = fixture_group_id
      and draft.status = 'cancelled'
  ) then
    raise exception 'service_role could not insert, update, and read the draft';
  end if;

  perform public.complete_line_webhook_event(
    'line-permission-event-000000000043',
    true,
    fixture_group_id,
    null
  );
end;
$$;

reset role;

select pass('LINE webhook service role retains only the required write path');
select * from finish();
rollback;
