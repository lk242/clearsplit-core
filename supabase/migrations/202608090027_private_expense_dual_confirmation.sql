-- Every private-expense obligation is completed only after the debtor confirms
-- payment and the original payer confirms receipt. Existing receipt-only rows
-- are preserved as payer confirmations; no debtor confirmation is inferred.

insert into public.app_schema_versions (version, name)
values (27, 'private expense dual confirmation and write authority');

alter table public.expense_receipts
  alter column received_at drop not null,
  alter column received_at drop default,
  alter column confirmed_by drop not null;

alter table public.expense_receipts
  rename column confirmed_by to received_confirmed_by;

alter table public.expense_receipts
  add column paid_at timestamptz,
  add column paid_confirmed_by uuid references auth.users(id),
  add column completed_at timestamptz,
  add constraint expense_receipts_paid_confirmation_pair check (
    (paid_at is null) = (paid_confirmed_by is null)
  ),
  add constraint expense_receipts_received_confirmation_pair check (
    (received_at is null) = (received_confirmed_by is null)
  ),
  add constraint expense_receipts_has_confirmation check (
    paid_at is not null or received_at is not null
  ),
  add constraint expense_receipts_completion_state check (
    (completed_at is null and not (paid_at is not null and received_at is not null))
    or (completed_at is not null and paid_at is not null and received_at is not null)
  );

create table public.private_expense_confirmation_events (
  id bigint generated always as identity primary key,
  expense_id uuid not null,
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  debtor_member_id uuid not null,
  amount bigint not null check (amount > 0),
  actor_user_id uuid not null references auth.users(id),
  actor_role text not null check (actor_role in ('debtor', 'payer')),
  action text not null check (action in ('confirm', 'revoke', 'complete')),
  created_at timestamptz not null default now(),
  constraint private_confirmation_expense_same_group_fk
    foreign key (expense_id, group_id)
    references public.expenses(id, group_id) on delete cascade,
  constraint private_confirmation_member_same_group_fk
    foreign key (debtor_member_id, group_id)
    references public.members(id, group_id)
);

create index private_expense_confirmation_events_lookup_idx
  on public.private_expense_confirmation_events(
    group_id, expense_id, debtor_member_id, created_at desc
  );

alter table public.private_expense_confirmation_events enable row level security;
revoke all on public.private_expense_confirmation_events from public, anon, authenticated;

create function public.enforce_private_expense_write_authority()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
begin
  if current_user_id is null then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;
  if tg_op = 'UPDATE'
    and current_setting('clearsplit.private_confirmation', true) = 'on'
    and public.is_group_member(old.group_id)
    and new.title is not distinct from old.title
    and new.amount is not distinct from old.amount
    and new.category is not distinct from old.category
    and new.payer_member_id is not distinct from old.payer_member_id
    and new.split_mode is not distinct from old.split_mode
    and new.expense_date is not distinct from old.expense_date
    and new.note is not distinct from old.note
    and new.created_by is not distinct from old.created_by then
    return new;
  end if;
  if current_user_id is null or not (
    public.is_group_owner(old.group_id)
    or old.created_by = current_user_id
    or exists (
      select 1 from public.members payer
      where payer.group_id = old.group_id
        and payer.id = old.payer_member_id
        and payer.user_id = current_user_id
    )
  ) then
    raise exception 'only the creator, payer, or responsible member may change this expense'
      using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

revoke all on function public.enforce_private_expense_write_authority()
  from public, anon, authenticated;

create trigger private_expense_write_authority
before update or delete on public.expenses
for each row execute function public.enforce_private_expense_write_authority();

create function public.get_editable_private_expense_ids(p_group_id uuid)
returns uuid[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
begin
  if current_user_id is null or not public.is_group_member(p_group_id) then
    raise exception 'expense access denied' using errcode = '42501';
  end if;
  return coalesce((
    select array_agg(expense.id order by expense.created_at, expense.id)
    from public.expenses expense
    where expense.group_id = p_group_id
      and (
        public.is_group_owner(p_group_id)
        or expense.created_by = current_user_id
        or exists (
          select 1 from public.members payer
          where payer.group_id = p_group_id
            and payer.id = expense.payer_member_id
            and payer.user_id = current_user_id
        )
      )
  ), '{}'::uuid[]);
end;
$$;

revoke all on function public.get_editable_private_expense_ids(uuid) from public, anon;
grant execute on function public.get_editable_private_expense_ids(uuid) to authenticated;

create or replace function public.private_expense_json(p_expense_id uuid)
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
        'paidAt', receipt.paid_at,
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
    'canEdit', public.is_group_owner(expense.group_id)
      or expense.created_by = (select auth.uid())
      or exists (
        select 1 from public.members payer
        where payer.group_id = expense.group_id
          and payer.id = expense.payer_member_id
          and payer.user_id = (select auth.uid())
      ),
    'createdAt', expense.created_at
  )
  from public.expenses expense
  where expense.id = p_expense_id;
$$;

revoke all on function public.private_expense_json(uuid) from public, anon, authenticated;

create function public.record_private_expense_confirmation(
  p_group_id uuid,
  p_expense_id uuid,
  p_debtor_member_id uuid,
  p_actor_role text,
  p_confirm boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  current_member_id uuid;
  expense_record public.expenses;
  debtor_share public.expense_shares;
  receipt_record public.expense_receipts;
  outstanding_count integer;
  state_changed boolean := false;
  just_completed boolean := false;
begin
  if current_user_id is null or p_actor_role not in ('debtor', 'payer')
    or p_confirm is null then
    raise exception 'invalid private expense confirmation' using errcode = '22023';
  end if;
  select id into current_member_id from public.members
  where group_id = p_group_id and user_id = current_user_id;

  select * into expense_record from public.expenses
  where id = p_expense_id and group_id = p_group_id for update;
  if not found then raise exception 'expense is unavailable' using errcode = '22023'; end if;
  if p_debtor_member_id = expense_record.payer_member_id then
    raise exception 'payer share does not require settlement' using errcode = '22023';
  end if;
  if p_actor_role = 'debtor' and current_member_id is distinct from p_debtor_member_id then
    raise exception 'debtor confirmation required' using errcode = '42501';
  end if;
  if p_actor_role = 'payer' and current_member_id is distinct from expense_record.payer_member_id then
    raise exception 'payer confirmation required' using errcode = '42501';
  end if;

  select * into debtor_share from public.expense_shares
  where expense_id = p_expense_id and group_id = p_group_id
    and member_id = p_debtor_member_id;
  if not found or debtor_share.amount <= 0 then
    raise exception 'expense debtor is unavailable' using errcode = '22023';
  end if;

  select * into receipt_record from public.expense_receipts
  where expense_id = p_expense_id and debtor_member_id = p_debtor_member_id
  for update;

  if not found then
    if p_confirm then
      insert into public.expense_receipts (
        expense_id, group_id, debtor_member_id, amount,
        paid_at, paid_confirmed_by, received_at, received_confirmed_by
      ) values (
        p_expense_id, p_group_id, p_debtor_member_id, debtor_share.amount,
        case when p_actor_role = 'debtor' then now() end,
        case when p_actor_role = 'debtor' then current_user_id end,
        case when p_actor_role = 'payer' then now() end,
        case when p_actor_role = 'payer' then current_user_id end
      ) returning * into receipt_record;
      state_changed := true;
    end if;
  elsif p_actor_role = 'debtor' then
    if p_confirm and receipt_record.paid_at is null then
      update public.expense_receipts
      set amount = debtor_share.amount, paid_at = now(), paid_confirmed_by = current_user_id
      where expense_id = p_expense_id and debtor_member_id = p_debtor_member_id
      returning * into receipt_record;
      state_changed := true;
    elsif not p_confirm and receipt_record.paid_at is not null then
      update public.expense_receipts
      set paid_at = null, paid_confirmed_by = null, completed_at = null
      where expense_id = p_expense_id and debtor_member_id = p_debtor_member_id
      returning * into receipt_record;
      state_changed := true;
    end if;
  else
    if p_confirm and receipt_record.received_at is null then
      update public.expense_receipts
      set amount = debtor_share.amount, received_at = now(), received_confirmed_by = current_user_id
      where expense_id = p_expense_id and debtor_member_id = p_debtor_member_id
      returning * into receipt_record;
      state_changed := true;
    elsif not p_confirm and receipt_record.received_at is not null then
      update public.expense_receipts
      set received_at = null, received_confirmed_by = null, completed_at = null
      where expense_id = p_expense_id and debtor_member_id = p_debtor_member_id
      returning * into receipt_record;
      state_changed := true;
    end if;
  end if;

  if state_changed and receipt_record.paid_at is null and receipt_record.received_at is null then
    delete from public.expense_receipts
    where expense_id = p_expense_id and debtor_member_id = p_debtor_member_id;
  elsif state_changed and receipt_record.paid_at is not null
    and receipt_record.received_at is not null and receipt_record.completed_at is null then
    update public.expense_receipts set completed_at = now()
    where expense_id = p_expense_id and debtor_member_id = p_debtor_member_id
    returning * into receipt_record;
    just_completed := true;
  end if;

  if state_changed then
    insert into public.private_expense_confirmation_events (
      expense_id, group_id, debtor_member_id, amount,
      actor_user_id, actor_role, action
    ) values (
      p_expense_id, p_group_id, p_debtor_member_id, debtor_share.amount,
      current_user_id, p_actor_role, case when p_confirm then 'confirm' else 'revoke' end
    );
    if just_completed then
      insert into public.private_expense_confirmation_events (
        expense_id, group_id, debtor_member_id, amount,
        actor_user_id, actor_role, action
      ) values (
        p_expense_id, p_group_id, p_debtor_member_id, debtor_share.amount,
        current_user_id, p_actor_role, 'complete'
      );
    end if;
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
        and receipt.paid_at is not null
        and receipt.received_at is not null
    );

  if state_changed then
    perform set_config('clearsplit.private_confirmation', 'on', true);
    update public.expenses
    set status = case when outstanding_count = 0 then 'resolved' else 'active' end,
        resolved_at = case when outstanding_count = 0 then coalesce(resolved_at, now()) else null end,
        version = version + 1,
        updated_by = current_user_id
    where id = p_expense_id;
  end if;

  return public.private_expense_json(p_expense_id);
end;
$$;

revoke all on function public.record_private_expense_confirmation(
  uuid, uuid, uuid, text, boolean
) from public, anon;
grant execute on function public.record_private_expense_confirmation(
  uuid, uuid, uuid, text, boolean
) to authenticated;

revoke execute on function public.record_private_expense_receipt(
  uuid, uuid, uuid, boolean
) from authenticated;

-- Receipt-only legacy rows remain payer confirmations and must be confirmed by
-- the debtor before the obligation can be considered complete.
update public.expenses expense
set status = case when exists (
      select 1 from public.expense_shares share
      where share.expense_id = expense.id
        and share.member_id <> expense.payer_member_id and share.amount > 0
    ) then 'active' else 'resolved' end,
    resolved_at = case when exists (
      select 1 from public.expense_shares share
      where share.expense_id = expense.id
        and share.member_id <> expense.payer_member_id and share.amount > 0
    ) then null else coalesce(expense.resolved_at, now()) end;
