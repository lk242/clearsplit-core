-- Make Supabase the canonical source for expense CRUD and preserve exact share order.

alter table public.expense_shares
  add column share_order integer;

with ranked_shares as (
  select
    expense_id,
    member_id,
    row_number() over (partition by expense_id order by amount desc, member_id) - 1 as share_order
  from public.expense_shares
)
update public.expense_shares as shares
set share_order = ranked.share_order
from ranked_shares as ranked
where shares.expense_id = ranked.expense_id
  and shares.member_id = ranked.member_id;

alter table public.expense_shares
  alter column share_order set not null,
  add constraint expense_shares_order_nonnegative check (share_order >= 0),
  add constraint expense_shares_expense_order_unique unique (expense_id, share_order);

-- Deferred triggers execute at transaction commit. Keep the integrity check privileged
-- so it can always read both tables after an authenticated RPC returns.
alter function public.assert_expense_balanced() security definer;
revoke all on function public.assert_expense_balanced() from public, anon, authenticated;

drop policy expenses_select_group on public.expenses;
create policy expenses_select_group on public.expenses for select to authenticated
using (public.is_group_owner(group_id) or public.is_group_member(group_id));

drop policy shares_select_group on public.expense_shares;
create policy shares_select_group on public.expense_shares for select to authenticated
using (public.is_group_owner(group_id) or public.is_group_member(group_id));

revoke all on public.expenses from anon;
revoke all on public.expense_shares from anon;
grant select on public.expenses to authenticated;
grant select on public.expense_shares to authenticated;

create function public.save_ledger_expense(
  p_group_id uuid,
  p_expense_id uuid,
  p_title text,
  p_amount bigint,
  p_category text,
  p_payer_member_id uuid,
  p_participant_member_ids uuid[],
  p_expense_date date,
  p_note text,
  p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  expense_record public.expenses;
  participant_count integer;
  base_share bigint;
  remainder bigint;
begin
  if current_user_id is null or not (
    public.is_group_owner(p_group_id) or public.is_group_member(p_group_id)
  ) then
    raise exception 'expense write permission required' using errcode = '42501';
  end if;

  p_title := trim(p_title);
  p_note := nullif(trim(coalesce(p_note, '')), '');
  participant_count := cardinality(p_participant_member_ids);

  if p_expense_id is null or p_title is null or char_length(p_title) not between 1 and 120
    or p_amount is null or p_amount not between 1 and 99999999
    or p_category is null or p_category not in ('food', 'transport', 'shopping', 'lodging', 'other')
    or p_payer_member_id is null or p_expense_date is null
    or participant_count is null or participant_count < 1 or participant_count > 200
    or char_length(coalesce(p_note, '')) > 1000 then
    raise exception 'invalid expense input' using errcode = '22023';
  end if;

  if exists (select 1 from unnest(p_participant_member_ids) as member_id where member_id is null)
    or (select count(distinct member_id) from unnest(p_participant_member_ids) as member_id) <> participant_count
    or (select count(*) from public.members where group_id = p_group_id and id = any(p_participant_member_ids)) <> participant_count
    or not exists (select 1 from public.members where group_id = p_group_id and id = p_payer_member_id) then
    raise exception 'expense members are invalid' using errcode = '23514';
  end if;

  select * into expense_record
  from public.expenses
  where id = p_expense_id
  for update;

  if found then
    if expense_record.group_id <> p_group_id then
      raise exception 'expense belongs to another ledger' using errcode = '42501';
    end if;
    if p_expected_version is null or expense_record.version <> p_expected_version then
      raise exception 'expense version conflict' using errcode = '40001';
    end if;

    update public.expenses
    set title = p_title,
        amount = p_amount,
        category = p_category,
        payer_member_id = p_payer_member_id,
        expense_date = p_expense_date,
        note = p_note,
        version = version + 1,
        updated_by = current_user_id
    where id = p_expense_id
    returning * into expense_record;

    delete from public.expense_shares where expense_id = p_expense_id;
  else
    if p_expected_version is not null then
      raise exception 'expense no longer exists' using errcode = '40001';
    end if;

    insert into public.expenses (
      id, group_id, title, amount, category, payer_member_id, expense_date,
      note, created_by, updated_by
    ) values (
      p_expense_id, p_group_id, p_title, p_amount, p_category, p_payer_member_id,
      p_expense_date, p_note, current_user_id, current_user_id
    )
    returning * into expense_record;
  end if;

  base_share := p_amount / participant_count;
  remainder := p_amount % participant_count;

  insert into public.expense_shares (expense_id, group_id, member_id, amount, share_order)
  select
    p_expense_id,
    p_group_id,
    participant.member_id,
    base_share + case when participant.ordinality <= remainder then 1 else 0 end,
    participant.ordinality - 1
  from unnest(p_participant_member_ids) with ordinality as participant(member_id, ordinality);

  return jsonb_build_object(
    'id', expense_record.id,
    'title', expense_record.title,
    'amount', expense_record.amount,
    'category', expense_record.category,
    'paidById', expense_record.payer_member_id,
    'participantIds', to_jsonb(p_participant_member_ids),
    'date', expense_record.expense_date,
    'note', coalesce(expense_record.note, ''),
    'version', expense_record.version,
    'createdAt', expense_record.created_at
  );
end;
$$;

create function public.delete_ledger_expense(
  p_group_id uuid,
  p_expense_id uuid,
  p_expected_version bigint
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  expense_record public.expenses;
begin
  if current_user_id is null or not (
    public.is_group_owner(p_group_id) or public.is_group_member(p_group_id)
  ) then
    raise exception 'expense delete permission required' using errcode = '42501';
  end if;

  select * into expense_record
  from public.expenses
  where id = p_expense_id and group_id = p_group_id
  for update;

  if not found then
    raise exception 'expense no longer exists' using errcode = '40001';
  end if;
  if p_expected_version is null or expense_record.version <> p_expected_version then
    raise exception 'expense version conflict' using errcode = '40001';
  end if;

  delete from public.expenses where id = p_expense_id;
end;
$$;

-- Keep LINE confirmation compatible with ordered shares and return the version
-- used by optimistic concurrency checks in the web client.
create or replace function public.confirm_line_expense_draft(p_draft_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  draft_record public.line_expense_drafts;
  expense_record public.expenses;
  member_id uuid;
  member_index integer := 0;
  member_count integer;
  base_share bigint;
  remainder bigint;
begin
  select * into draft_record from public.line_expense_drafts where id = p_draft_id for update;
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

  insert into public.expenses (
    group_id, title, amount, category, payer_member_id, expense_date,
    note, created_by, updated_by
  ) values (
    draft_record.group_id, draft_record.title, draft_record.amount, 'other',
    draft_record.payer_member_id, current_date, '由 LINE #記帳草稿確認入帳',
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
    'id', expense_record.id,
    'title', expense_record.title,
    'amount', expense_record.amount,
    'category', expense_record.category,
    'paidById', expense_record.payer_member_id,
    'participantIds', draft_record.participant_member_ids,
    'date', expense_record.expense_date,
    'note', expense_record.note,
    'version', expense_record.version,
    'createdAt', expense_record.created_at
  );
end;
$$;

revoke all on function public.save_ledger_expense(uuid, uuid, text, bigint, text, uuid, uuid[], date, text, bigint) from public, anon;
revoke all on function public.delete_ledger_expense(uuid, uuid, bigint) from public, anon;
grant execute on function public.save_ledger_expense(uuid, uuid, text, bigint, text, uuid, uuid[], date, text, bigint) to authenticated;
grant execute on function public.delete_ledger_expense(uuid, uuid, bigint) to authenticated;
