-- LINE is an intake channel for public-fund expenses only. A message creates
-- a reviewable draft; only the responsible member can post it to the fund.
-- Webhook events are leased durably so transient failures are retried without
-- creating the same draft twice.

insert into public.app_schema_versions (version, name)
values (29, 'LINE Bot public fund drafts and durable webhook handling');

update public.line_expense_drafts
set status = 'cancelled', raw_text = null
where status in ('pending', 'needs_input');

revoke all on function public.confirm_line_expense_draft(uuid, boolean) from authenticated;
revoke all on function public.cancel_line_expense_draft(uuid) from authenticated;

create table public.line_webhook_events (
  webhook_event_id text primary key check (char_length(webhook_event_id) between 10 and 120),
  source_message_id text check (source_message_id is null or char_length(source_message_id) between 1 and 120),
  group_id uuid references public.ledger_groups(id) on delete cascade,
  status text not null check (status in ('processing', 'processed', 'failed')),
  attempt_count integer not null default 1 check (attempt_count > 0),
  processing_started_at timestamptz not null default now(),
  processed_at timestamptz,
  last_error text check (last_error is null or char_length(last_error) <= 1000),
  first_received_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index line_webhook_events_status_idx
  on public.line_webhook_events(status, updated_at);

create table public.line_fund_expense_drafts (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  webhook_event_id text not null unique references public.line_webhook_events(webhook_event_id) on delete cascade,
  source_message_id text not null unique check (char_length(source_message_id) between 1 and 120),
  source_line_user_id text not null check (source_line_user_id ~ '^U[0-9a-f]{32}$'),
  submitted_member_id uuid not null,
  submitted_display_name text not null check (char_length(trim(submitted_display_name)) between 1 and 80),
  raw_text text check (raw_text is null or char_length(raw_text) <= 5000),
  title text not null check (char_length(trim(title)) between 1 and 120),
  amount bigint not null check (amount > 0 and amount <= 999999999),
  effective_date date not null,
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'cancelled')),
  parser_version text not null default 'public-fund-v1',
  confirmed_transaction_id uuid references public.fund_transactions(id),
  confirmed_by uuid references auth.users(id),
  confirmed_at timestamptz,
  cancelled_by uuid references auth.users(id),
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint line_fund_draft_submitter_same_group_fk
    foreign key (submitted_member_id, group_id) references public.members(id, group_id),
  constraint line_fund_draft_confirmation_state_check check (
    (status = 'pending' and confirmed_transaction_id is null and confirmed_at is null and cancelled_at is null)
    or (status = 'confirmed' and confirmed_transaction_id is not null and confirmed_at is not null and cancelled_at is null)
    or (status = 'cancelled' and confirmed_transaction_id is null and confirmed_at is null and cancelled_at is not null)
  )
);

create index line_fund_drafts_group_status_idx
  on public.line_fund_expense_drafts(group_id, status, created_at desc);

create trigger line_webhook_events_set_updated_at
before update on public.line_webhook_events
for each row execute function public.set_updated_at();

create trigger line_fund_drafts_set_updated_at
before update on public.line_fund_expense_drafts
for each row execute function public.set_updated_at();

alter table public.line_webhook_events enable row level security;
alter table public.line_fund_expense_drafts enable row level security;

revoke all on public.line_webhook_events from public, anon, authenticated;
revoke all on public.line_fund_expense_drafts from public, anon, authenticated;
grant select on public.line_fund_expense_drafts to authenticated;

create policy line_fund_drafts_select_group
on public.line_fund_expense_drafts for select to authenticated
using (public.is_group_member(group_id));

create function public.begin_line_webhook_event(
  p_webhook_event_id text,
  p_source_message_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  event_record public.line_webhook_events;
begin
  if p_webhook_event_id is null or char_length(p_webhook_event_id) not between 10 and 120
    or (p_source_message_id is not null and char_length(p_source_message_id) not between 1 and 120) then
    raise exception 'invalid LINE webhook identity' using errcode = '22023';
  end if;

  insert into public.line_webhook_events (
    webhook_event_id, source_message_id, status
  ) values (
    p_webhook_event_id, p_source_message_id, 'processing'
  )
  on conflict (webhook_event_id) do update set
    source_message_id = coalesce(excluded.source_message_id, public.line_webhook_events.source_message_id),
    status = 'processing',
    attempt_count = public.line_webhook_events.attempt_count + 1,
    processing_started_at = now(),
    processed_at = null,
    last_error = null
  where public.line_webhook_events.status = 'failed'
    or (public.line_webhook_events.status = 'processing'
      and public.line_webhook_events.processing_started_at < now() - interval '5 minutes')
  returning * into event_record;

  if found then
    return jsonb_build_object('shouldProcess', true, 'attemptCount', event_record.attempt_count);
  end if;

  select * into event_record
  from public.line_webhook_events
  where webhook_event_id = p_webhook_event_id;
  return jsonb_build_object(
    'shouldProcess', false,
    'attemptCount', event_record.attempt_count,
    'status', event_record.status
  );
end;
$$;

create function public.complete_line_webhook_event(
  p_webhook_event_id text,
  p_success boolean,
  p_group_id uuid default null,
  p_error text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.line_webhook_events
  set status = case when p_success then 'processed' else 'failed' end,
      group_id = coalesce(p_group_id, group_id),
      processed_at = case when p_success then now() else null end,
      last_error = case when p_success then null else left(coalesce(p_error, 'unknown error'), 1000) end
  where webhook_event_id = p_webhook_event_id and status = 'processing';
  if not found then
    raise exception 'LINE webhook lease is unavailable' using errcode = '40001';
  end if;
end;
$$;

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
  fund_record public.group_funds;
  duplicate_record public.fund_transactions;
  created_transaction public.fund_transactions;
  fund_result jsonb;
  duplicate_reason text;
begin
  select * into draft_record
  from public.line_fund_expense_drafts
  where id = p_draft_id
  for update;

  if not found or current_user_id is null or not public.is_group_owner(draft_record.group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;
  if draft_record.status <> 'pending' then
    raise exception 'public fund draft is not pending' using errcode = '23514';
  end if;

  select * into fund_record
  from public.group_funds
  where group_id = draft_record.group_id
  for update;
  if not found or fund_record.status <> 'active' then
    raise exception 'group fund is not accepting expenses' using errcode = '23514';
  end if;

  select * into duplicate_record
  from public.fund_transactions transaction
  where transaction.group_id = draft_record.group_id
    and transaction.cycle_number = fund_record.cycle_number
    and transaction.transaction_type = 'expense'
    and transaction.amount_delta = -draft_record.amount
    and transaction.effective_date = draft_record.effective_date
  order by
    case when lower(regexp_replace(trim(transaction.title), '[[:space:][:punct:]]+', '', 'g'))
      = lower(regexp_replace(trim(draft_record.title), '[[:space:][:punct:]]+', '', 'g')) then 0 else 1 end,
    transaction.created_at desc
  limit 1;

  if found and not coalesce(p_allow_duplicate, false) then
    duplicate_reason := case
      when lower(regexp_replace(trim(duplicate_record.title), '[[:space:][:punct:]]+', '', 'g'))
        = lower(regexp_replace(trim(draft_record.title), '[[:space:][:punct:]]+', '', 'g'))
      then 'exact_match' else 'same_amount_date' end;
    return jsonb_build_object(
      'status', 'duplicate',
      'candidate', jsonb_build_object(
        'id', duplicate_record.id,
        'title', duplicate_record.title,
        'amount', abs(duplicate_record.amount_delta),
        'date', duplicate_record.effective_date,
        'cycleNumber', duplicate_record.cycle_number,
        'reason', duplicate_reason
      )
    );
  end if;

  fund_result := public.record_group_fund_expense_v2(
    draft_record.group_id,
    draft_record.title,
    draft_record.amount,
    draft_record.effective_date,
    '由 LINE #記帳公帳草稿確認入帳',
    p_advance_member_id,
    true
  );

  select * into created_transaction
  from public.fund_transactions transaction
  where transaction.group_id = draft_record.group_id
    and transaction.cycle_number = fund_record.cycle_number
    and transaction.transaction_type = 'expense'
    and transaction.title = draft_record.title
    and transaction.amount_delta = -draft_record.amount
    and transaction.effective_date = draft_record.effective_date
    and transaction.created_by = current_user_id
  order by transaction.created_at desc
  limit 1;
  if not found then
    raise exception 'created public fund transaction is unavailable' using errcode = '23514';
  end if;

  update public.line_fund_expense_drafts
  set status = 'confirmed',
      confirmed_transaction_id = created_transaction.id,
      confirmed_by = current_user_id,
      confirmed_at = now(),
      raw_text = null
  where id = draft_record.id;

  return jsonb_build_object(
    'status', 'confirmed',
    'transactionId', created_transaction.id,
    'fund', fund_result
  );
end;
$$;

create function public.cancel_line_fund_expense_draft(p_draft_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  draft_group_id uuid;
begin
  select group_id into draft_group_id
  from public.line_fund_expense_drafts
  where id = p_draft_id
  for update;
  if not found or current_user_id is null or not public.is_group_owner(draft_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;
  update public.line_fund_expense_drafts
  set status = 'cancelled', cancelled_by = current_user_id,
      cancelled_at = now(), raw_text = null
  where id = p_draft_id and status = 'pending';
  if not found then
    raise exception 'public fund draft is not pending' using errcode = '23514';
  end if;
end;
$$;

revoke all on function public.begin_line_webhook_event(text, text)
  from public, anon, authenticated;
revoke all on function public.complete_line_webhook_event(text, boolean, uuid, text)
  from public, anon, authenticated;
grant execute on function public.begin_line_webhook_event(text, text) to service_role;
grant execute on function public.complete_line_webhook_event(text, boolean, uuid, text) to service_role;

revoke all on function public.confirm_line_fund_expense_draft(uuid, uuid, boolean)
  from public, anon;
revoke all on function public.cancel_line_fund_expense_draft(uuid)
  from public, anon;
grant execute on function public.confirm_line_fund_expense_draft(uuid, uuid, boolean) to authenticated;
grant execute on function public.cancel_line_fund_expense_draft(uuid) to authenticated;
