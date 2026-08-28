-- Require an explicit override before a LINE draft can duplicate a same-day expense.

revoke all on function public.confirm_line_expense_draft(uuid) from authenticated;

create function public.confirm_line_expense_draft(
  p_draft_id uuid,
  p_allow_duplicate boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  draft_record public.line_expense_drafts;
  expense_record public.expenses;
  duplicate_record public.expenses;
  member_id uuid;
  member_index integer := 0;
  member_count integer;
  base_share bigint;
  remainder bigint;
  draft_date date;
  duplicate_reason text;
begin
  select * into draft_record
  from public.line_expense_drafts
  where id = p_draft_id
  for update;

  if not found or current_user_id is null or not public.is_group_member(draft_record.group_id) then
    raise exception 'draft access denied' using errcode = '42501';
  end if;
  if draft_record.status <> 'pending' or draft_record.amount is null or draft_record.title is null
    or draft_record.payer_member_id is null or draft_record.participant_member_ids is null then
    raise exception 'draft is not confirmable' using errcode = '22023';
  end if;

  member_count := cardinality(draft_record.participant_member_ids);
  if member_count < 1 or (
    select count(*) from public.members
    where group_id = draft_record.group_id and id = any(draft_record.participant_member_ids)
  ) <> member_count then
    raise exception 'draft members are invalid' using errcode = '23514';
  end if;

  draft_date := (draft_record.created_at at time zone 'Asia/Taipei')::date;
  select * into duplicate_record
  from public.expenses
  where group_id = draft_record.group_id
    and amount = draft_record.amount
    and payer_member_id = draft_record.payer_member_id
    and expense_date = draft_date
  order by
    case when lower(regexp_replace(trim(title), '[[:space:][:punct:]]+', '', 'g'))
      = lower(regexp_replace(trim(draft_record.title), '[[:space:][:punct:]]+', '', 'g')) then 0 else 1 end,
    created_at desc
  limit 1;

  if found and not coalesce(p_allow_duplicate, false) then
    duplicate_reason := case
      when lower(regexp_replace(trim(duplicate_record.title), '[[:space:][:punct:]]+', '', 'g'))
        = lower(regexp_replace(trim(draft_record.title), '[[:space:][:punct:]]+', '', 'g'))
      then 'exact_match'
      else 'same_amount_payer_date'
    end;
    return jsonb_build_object(
      'status', 'duplicate',
      'candidate', jsonb_build_object(
        'id', duplicate_record.id,
        'title', duplicate_record.title,
        'amount', duplicate_record.amount,
        'paidById', duplicate_record.payer_member_id,
        'date', duplicate_record.expense_date,
        'reason', duplicate_reason
      )
    );
  end if;

  insert into public.expenses (
    group_id, title, amount, category, payer_member_id, expense_date,
    note, created_by, updated_by
  ) values (
    draft_record.group_id, draft_record.title, draft_record.amount, 'other',
    draft_record.payer_member_id, draft_date, '由 LINE #記帳草稿確認入帳',
    current_user_id, current_user_id
  ) returning * into expense_record;

  base_share := draft_record.amount / member_count;
  remainder := draft_record.amount % member_count;
  foreach member_id in array draft_record.participant_member_ids
  loop
    insert into public.expense_shares (expense_id, group_id, member_id, amount, share_order)
    values (
      expense_record.id,
      draft_record.group_id,
      member_id,
      base_share + case when member_index < remainder then 1 else 0 end,
      member_index
    );
    member_index := member_index + 1;
  end loop;

  update public.line_expense_drafts
  set status = 'confirmed', confirmed_expense_id = expense_record.id, raw_text = null
  where id = draft_record.id;

  return jsonb_build_object(
    'status', 'confirmed',
    'expense', jsonb_build_object(
      'id', expense_record.id,
      'title', expense_record.title,
      'amount', expense_record.amount,
      'category', expense_record.category,
      'paidById', expense_record.payer_member_id,
      'participantIds', to_jsonb(draft_record.participant_member_ids),
      'date', expense_record.expense_date,
      'note', expense_record.note,
      'version', expense_record.version,
      'createdAt', expense_record.created_at
    )
  );
end;
$$;

revoke all on function public.confirm_line_expense_draft(uuid, boolean) from public, anon;
grant execute on function public.confirm_line_expense_draft(uuid, boolean) to authenticated;
