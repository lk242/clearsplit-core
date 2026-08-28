-- RLS policies only filter rows after PostgreSQL table privileges allow the
-- operation. Keep anon blocked and grant authenticated clients the minimum
-- direct access used by the web app.

revoke all on public.members from anon;
grant select, insert, update, delete on public.members to authenticated;

revoke all on public.line_group_bindings from anon;
revoke all on public.line_expense_drafts from anon;
grant select on public.line_group_bindings to authenticated;
grant select on public.line_expense_drafts to authenticated;
