-- Keep the database constraint aligned with webhook member-resolution results.

alter table public.line_expense_drafts
  drop constraint if exists line_expense_drafts_issue_code_check;

alter table public.line_expense_drafts
  add constraint line_expense_drafts_issue_code_check
  check (
    issue_code is null
    or issue_code in (
      'invalid_format',
      'speaker_not_member',
      'payer_not_found',
      'participant_not_found',
      'ambiguous_member'
    )
  );
