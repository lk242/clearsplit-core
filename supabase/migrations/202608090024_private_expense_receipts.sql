-- Private member expenses settle independently. Only the member who paid may
-- mark each debtor share as received; the expense resolves when none remain.

alter table public.expenses
  add column split_mode text not null default 'equal'
    check (split_mode in ('equal', 'custom')),
  add column status text not null default 'active'
    check (status in ('active', 'resolved')),
  add column resolved_at timestamptz,
  add constraint expenses_resolution_state_check check (
    (status = 'active' and resolved_at is null)
    or (status = 'resolved' and resolved_at is not null)
  );

create table public.expense_receipts (
  expense_id uuid not null,
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  debtor_member_id uuid not null,
  amount bigint not null check (amount > 0),
  received_at timestamptz not null default now(),
  confirmed_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (expense_id, debtor_member_id),
  constraint expense_receipts_expense_same_group_fk
    foreign key (expense_id, group_id)
    references public.expenses(id, group_id) on delete cascade,
  constraint expense_receipts_member_same_group_fk
    foreign key (debtor_member_id, group_id)
    references public.members(id, group_id)
);

create index expense_receipts_group_idx
  on public.expense_receipts(group_id, received_at desc);

alter table public.expense_receipts enable row level security;
create policy expense_receipts_select_group on public.expense_receipts
for select to authenticated
using (public.is_group_member(group_id));

revoke all on public.expense_receipts from anon;
revoke insert, update, delete on public.expense_receipts from authenticated;
grant select on public.expense_receipts to authenticated;

create function public.private_expense_json(p_expense_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', expense.id,
    'title', expense.title,
    'amount', expense.amount,
    'category', expense.category,
    'paidById', expense.payer_member_id,
    'participantIds', coalesce((
      select jsonb_agg(share.member_id order by share.share_order)
      from public.expense_shares share
      where share.expense_id = expense.id
    ), '[]'::jsonb),
    'shares', coalesce((
      select jsonb_agg(jsonb_build_object(
        'participantId', share.member_id,
        'amount', share.amount,
        'receivedAt', receipt.received_at
      ) order by share.share_order)
      from public.expense_shares share
      left join public.expense_receipts receipt
        on receipt.expense_id = share.expense_id
        and receipt.debtor_member_id = share.member_id
      where share.expense_id = expense.id
    ), '[]'::jsonb),
    'splitMode', expense.split_mode,
    'status', expense.status,
    'resolvedAt', expense.resolved_at,
    'date', expense.expense_date,
    'note', coalesce(expense.note, ''),
    'version', expense.version,
    'createdAt', expense.created_at
  )
  from public.expenses expense
  where expense.id = p_expense_id;
$$;

revoke all on function public.private_expense_json(uuid) from public, anon, authenticated;

create function public.save_private_expense(
  p_group_id uuid,
  p_expense_id uuid,
  p_title text,
  p_amount bigint,
  p_category text,
  p_payer_member_id uuid,
  p_shares jsonb,
  p_split_mode text,
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
  share_value jsonb;
  share_member_id uuid;
  share_amount bigint;
  share_ids uuid[] := '{}'::uuid[];
  share_amounts bigint[] := '{}'::bigint[];
  share_count integer;
  share_index integer := 1;
  base_share bigint;
  remainder bigint;
  has_obligation boolean;
begin
  if current_user_id is null or not public.is_group_member(p_group_id) then
    raise exception 'expense write permission required' using errcode = '42501';
  end if;

  p_title := trim(p_title);
  p_note := nullif(trim(coalesce(p_note, '')), '');
  if p_expense_id is null or p_title is null or char_length(p_title) not between 1 and 120
    or p_amount is null or p_amount not between 1 and 99999999
    or p_category is null or p_category not in ('food', 'transport', 'shopping', 'lodging', 'other')
    or p_payer_member_id is null or p_expense_date is null
    or p_split_mode is null or p_split_mode not in ('equal', 'custom')
    or p_shares is null
    or jsonb_typeof(p_shares) <> 'array'
    or jsonb_array_length(p_shares) not between 1 and 200
    or char_length(coalesce(p_note, '')) > 1000 then
    raise exception 'invalid expense input' using errcode = '22023';
  end if;

  for share_value in select value from jsonb_array_elements(p_shares)
  loop
    if jsonb_typeof(share_value) <> 'object'
      or not (share_value ? 'participantId')
      or (p_split_mode = 'custom' and not (share_value ? 'amount')) then
      raise exception 'invalid expense share input' using errcode = '22023';
    end if;
    begin
      share_member_id := (share_value->>'participantId')::uuid;
      share_amount := case when p_split_mode = 'custom' then (share_value->>'amount')::bigint else 0 end;
    exception when others then
      raise exception 'invalid expense share input' using errcode = '22023';
    end;
    if share_member_id is null or share_member_id = any(share_ids)
      or share_amount is null or share_amount < 0 then
      raise exception 'invalid expense share input' using errcode = '22023';
    end if;
    share_ids := array_append(share_ids, share_member_id);
    share_amounts := array_append(share_amounts, share_amount);
  end loop;

  share_count := cardinality(share_ids);
  if not exists (
      select 1 from public.members
      where group_id = p_group_id and id = p_payer_member_id
    ) or (
      select count(*) from public.members
      where group_id = p_group_id and id = any(share_ids)
    ) <> share_count then
    raise exception 'expense members are invalid' using errcode = '23514';
  end if;

  if p_split_mode = 'custom' and (
    select coalesce(sum(value), 0) from unnest(share_amounts) value
  ) <> p_amount then
    raise exception 'custom expense shares must equal total' using errcode = '23514';
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

    delete from public.expense_receipts where expense_id = p_expense_id;
    delete from public.expense_shares where expense_id = p_expense_id;
    update public.expenses
    set title = p_title,
        amount = p_amount,
        category = p_category,
        payer_member_id = p_payer_member_id,
        split_mode = p_split_mode,
        status = 'active',
        resolved_at = null,
        expense_date = p_expense_date,
        note = p_note,
        version = version + 1,
        updated_by = current_user_id
    where id = p_expense_id
    returning * into expense_record;
  else
    if p_expected_version is not null then
      raise exception 'expense no longer exists' using errcode = '40001';
    end if;
    insert into public.expenses (
      id, group_id, title, amount, category, payer_member_id, split_mode,
      expense_date, note, created_by, updated_by
    ) values (
      p_expense_id, p_group_id, p_title, p_amount, p_category, p_payer_member_id,
      p_split_mode, p_expense_date, p_note, current_user_id, current_user_id
    ) returning * into expense_record;
  end if;

  if p_split_mode = 'equal' then
    base_share := p_amount / share_count;
    remainder := p_amount % share_count;
    while share_index <= share_count loop
      insert into public.expense_shares (
        expense_id, group_id, member_id, amount, share_order
      ) values (
        p_expense_id, p_group_id, share_ids[share_index],
        base_share + case when share_index <= remainder then 1 else 0 end,
        share_index - 1
      );
      share_index := share_index + 1;
    end loop;
  else
    while share_index <= share_count loop
      insert into public.expense_shares (
        expense_id, group_id, member_id, amount, share_order
      ) values (
        p_expense_id, p_group_id, share_ids[share_index], share_amounts[share_index],
        share_index - 1
      );
      share_index := share_index + 1;
    end loop;
  end if;

  select exists (
    select 1 from public.expense_shares
    where expense_id = p_expense_id
      and member_id <> p_payer_member_id
      and amount > 0
  ) into has_obligation;
  if not has_obligation then
    update public.expenses
    set status = 'resolved', resolved_at = now()
    where id = p_expense_id;
  end if;

  return public.private_expense_json(p_expense_id);
end;
$$;

create function public.record_private_expense_receipt(
  p_group_id uuid,
  p_expense_id uuid,
  p_debtor_member_id uuid,
  p_received boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  expense_record public.expenses;
  debtor_share public.expense_shares;
  outstanding_count integer;
begin
  if current_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_received is null then
    raise exception 'invalid receipt state' using errcode = '22023';
  end if;

  select * into expense_record
  from public.expenses
  where id = p_expense_id and group_id = p_group_id
  for update;
  if not found then
    raise exception 'expense is unavailable' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.members
    where group_id = p_group_id
      and id = expense_record.payer_member_id
      and user_id = current_user_id
  ) then
    raise exception 'only the payer may confirm receipts' using errcode = '42501';
  end if;
  if p_debtor_member_id = expense_record.payer_member_id then
    raise exception 'payer share does not require a receipt' using errcode = '22023';
  end if;

  select * into debtor_share
  from public.expense_shares
  where expense_id = p_expense_id
    and group_id = p_group_id
    and member_id = p_debtor_member_id;
  if not found or debtor_share.amount <= 0 then
    raise exception 'expense debtor is unavailable' using errcode = '22023';
  end if;

  if p_received then
    insert into public.expense_receipts (
      expense_id, group_id, debtor_member_id, amount, confirmed_by
    ) values (
      p_expense_id, p_group_id, p_debtor_member_id, debtor_share.amount, current_user_id
    )
    on conflict (expense_id, debtor_member_id) do update
      set amount = excluded.amount,
          received_at = now(),
          confirmed_by = current_user_id;
  else
    delete from public.expense_receipts
    where expense_id = p_expense_id and debtor_member_id = p_debtor_member_id;
  end if;

  select count(*) into outstanding_count
  from public.expense_shares share
  where share.expense_id = p_expense_id
    and share.member_id <> expense_record.payer_member_id
    and share.amount > 0
    and not exists (
      select 1 from public.expense_receipts receipt
      where receipt.expense_id = share.expense_id
        and receipt.debtor_member_id = share.member_id
        and receipt.amount = share.amount
    );

  update public.expenses
  set status = case when outstanding_count = 0 then 'resolved' else 'active' end,
      resolved_at = case when outstanding_count = 0 then coalesce(resolved_at, now()) else null end
  where id = p_expense_id;

  return public.private_expense_json(p_expense_id);
end;
$$;

revoke all on function public.save_private_expense(
  uuid, uuid, text, bigint, text, uuid, jsonb, text, date, text, bigint
) from public, anon;
revoke all on function public.record_private_expense_receipt(
  uuid, uuid, uuid, boolean
) from public, anon;
grant execute on function public.save_private_expense(
  uuid, uuid, text, bigint, text, uuid, jsonb, text, date, text, bigint
) to authenticated;
grant execute on function public.record_private_expense_receipt(
  uuid, uuid, uuid, boolean
) to authenticated;

-- All web writes now go through the split-aware RPC above. Keeping the old
-- function defined avoids breaking historical migrations while preventing it
-- from bypassing receipt resets and custom-share validation.
revoke execute on function public.save_ledger_expense(
  uuid, uuid, text, bigint, text, uuid, uuid[], date, text, bigint
) from authenticated;

-- Expose the authenticated member identity needed for payer-only controls.
create or replace function public.get_ledger_access(
  p_group_id uuid,
  p_setup_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  current_member_id uuid;
  group_record public.ledger_groups;
  can_setup boolean;
begin
  if current_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  select * into group_record from public.ledger_groups where id = p_group_id;
  if not found then raise exception 'ledger access denied' using errcode = '42501'; end if;

  can_setup := public.has_valid_ledger_setup_token(p_group_id, p_setup_token);
  if not (public.is_group_member(p_group_id) or can_setup) then
    raise exception 'ledger access denied' using errcode = '42501';
  end if;
  select id into current_member_id
  from public.members
  where group_id = p_group_id and user_id = current_user_id;

  return jsonb_build_object(
    'groupId', group_record.id,
    'groupName', group_record.name,
    'isOwner', public.is_group_owner(p_group_id),
    'canSetup', can_setup,
    'hasResponsibleMember', group_record.responsible_member_id is not null,
    'responsibleMemberId', group_record.responsible_member_id,
    'currentMemberId', current_member_id,
    'setupExpiresAt', case when can_setup then (
      select expires_at from public.ledger_setup_tokens where group_id = p_group_id
    ) end,
    'memberCount', (select count(*) from public.members where group_id = p_group_id),
    'expenseCount', (select count(*) from public.expenses where group_id = p_group_id)
  );
end;
$$;
