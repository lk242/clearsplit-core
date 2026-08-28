-- The webhook runs with the Supabase service_role JWT. RLS bypass alone does
-- not grant SQL privileges, so expose only the columns used by line-webhook.

grant select (group_id, line_group_id, active)
  on public.line_group_bindings to service_role;

grant select (id, group_id, display_name, line_user_id)
  on public.members to service_role;

grant select (id, group_id, source_message_id, status)
  on public.line_fund_expense_drafts to service_role;
grant insert (
  group_id, webhook_event_id, source_message_id, source_line_user_id,
  submitted_member_id, submitted_display_name, raw_text, title, amount,
  effective_date
) on public.line_fund_expense_drafts to service_role;
grant update (raw_text, status, cancelled_at)
  on public.line_fund_expense_drafts to service_role;

insert into public.app_schema_versions (version, name)
values (43, 'LINE webhook least-privilege service grants');
