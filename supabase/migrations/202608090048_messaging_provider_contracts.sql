-- Provider-neutral messaging intake. LINE, Discord and Telegram all follow the
-- same safety boundary: a signed webhook may create a draft, but only the
-- ledger's responsible member may confirm it into the public fund.

create table public.messaging_bind_codes (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  provider text not null check (provider in ('line', 'discord', 'telegram')),
  code_hash bytea not null,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  unique (provider, code_hash)
);

create table public.messaging_identity_codes (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null,
  member_id uuid not null,
  provider text not null check (provider in ('line', 'discord', 'telegram')),
  code_hash bytea not null,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  constraint messaging_identity_code_member_fk
    foreign key (member_id, group_id) references public.members(id, group_id) on delete cascade,
  unique (provider, code_hash)
);

create table public.messaging_conversation_bindings (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  provider text not null check (provider in ('line', 'discord', 'telegram')),
  external_conversation_id text not null check (char_length(external_conversation_id) between 1 and 160),
  bound_by_external_user_id text check (bound_by_external_user_id is null or char_length(bound_by_external_user_id) between 1 and 160),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (provider, external_conversation_id),
  unique (provider, group_id)
);

create table public.messaging_identities (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null,
  member_id uuid not null,
  provider text not null check (provider in ('line', 'discord', 'telegram')),
  external_user_id text not null check (char_length(external_user_id) between 1 and 160),
  external_display_name text not null check (char_length(trim(external_display_name)) between 1 and 80),
  linked_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint messaging_identity_member_fk
    foreign key (member_id, group_id) references public.members(id, group_id) on delete cascade,
  unique (provider, group_id, external_user_id),
  unique (provider, group_id, member_id)
);

create table public.messaging_webhook_events (
  provider text not null check (provider in ('line', 'discord', 'telegram')),
  webhook_event_id text not null check (char_length(webhook_event_id) between 1 and 160),
  source_message_id text check (source_message_id is null or char_length(source_message_id) between 1 and 160),
  group_id uuid references public.ledger_groups(id) on delete cascade,
  status text not null check (status in ('processing', 'processed', 'failed')),
  attempt_count integer not null default 1 check (attempt_count > 0),
  processing_started_at timestamptz not null default now(),
  processed_at timestamptz,
  last_error text check (last_error is null or char_length(last_error) <= 1000),
  first_received_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (provider, webhook_event_id)
);

create table public.messaging_fund_expense_drafts (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  provider text not null check (provider in ('line', 'discord', 'telegram')),
  webhook_event_id text not null,
  source_message_id text not null check (char_length(source_message_id) between 1 and 160),
  external_conversation_id text not null check (char_length(external_conversation_id) between 1 and 160),
  external_user_id text not null check (char_length(external_user_id) between 1 and 160),
  submitted_member_id uuid not null,
  submitted_display_name text not null check (char_length(trim(submitted_display_name)) between 1 and 80),
  raw_text text check (raw_text is null or char_length(raw_text) <= 5000),
  title text not null check (char_length(trim(title)) between 1 and 120),
  amount bigint not null check (amount > 0 and amount <= 999999999),
  effective_date date not null,
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'cancelled')),
  parser_version text not null default 'messaging-v1',
  confirmed_transaction_id uuid references public.fund_transactions(id),
  confirmed_by uuid references auth.users(id),
  confirmed_at timestamptz,
  cancelled_by uuid references auth.users(id),
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint messaging_draft_event_fk
    foreign key (provider, webhook_event_id)
    references public.messaging_webhook_events(provider, webhook_event_id) on delete cascade,
  constraint messaging_draft_submitter_fk
    foreign key (submitted_member_id, group_id)
    references public.members(id, group_id),
  constraint messaging_draft_event_unique unique (provider, webhook_event_id),
  constraint messaging_draft_message_unique unique (provider, source_message_id),
  constraint messaging_draft_state_check check (
    (status = 'pending' and confirmed_transaction_id is null and confirmed_at is null and cancelled_at is null)
    or (status = 'confirmed' and confirmed_transaction_id is not null and confirmed_at is not null and cancelled_at is null)
    or (status = 'cancelled' and confirmed_transaction_id is null and confirmed_at is null and cancelled_at is not null)
  )
);

create index messaging_bind_codes_group_idx on public.messaging_bind_codes(group_id, provider, expires_at desc);
create index messaging_identity_codes_group_idx on public.messaging_identity_codes(group_id, provider, expires_at desc);
create index messaging_bindings_group_idx on public.messaging_conversation_bindings(group_id, provider, active);
create index messaging_identities_member_idx on public.messaging_identities(group_id, member_id, provider);
create index messaging_events_status_idx on public.messaging_webhook_events(status, updated_at);
create index messaging_drafts_group_status_idx on public.messaging_fund_expense_drafts(group_id, status, created_at desc);

create trigger messaging_bindings_set_updated_at before update on public.messaging_conversation_bindings
for each row execute function public.set_updated_at();
create trigger messaging_identities_set_updated_at before update on public.messaging_identities
for each row execute function public.set_updated_at();
create trigger messaging_events_set_updated_at before update on public.messaging_webhook_events
for each row execute function public.set_updated_at();
create trigger messaging_drafts_set_updated_at before update on public.messaging_fund_expense_drafts
for each row execute function public.set_updated_at();

alter table public.messaging_bind_codes enable row level security;
alter table public.messaging_identity_codes enable row level security;
alter table public.messaging_conversation_bindings enable row level security;
alter table public.messaging_identities enable row level security;
alter table public.messaging_webhook_events enable row level security;
alter table public.messaging_fund_expense_drafts enable row level security;

create policy messaging_bind_codes_owner_all on public.messaging_bind_codes for all to authenticated
using (public.is_group_owner(group_id)) with check (public.is_group_owner(group_id));
create policy messaging_identity_codes_member_select on public.messaging_identity_codes for select to authenticated
using (public.is_group_member(group_id));
create policy messaging_bindings_group_select on public.messaging_conversation_bindings for select to authenticated
using (public.is_group_member(group_id));
create policy messaging_identities_group_select on public.messaging_identities for select to authenticated
using (public.is_group_member(group_id));
create policy messaging_drafts_group_select on public.messaging_fund_expense_drafts for select to authenticated
using (public.is_group_member(group_id));

revoke all on public.messaging_bind_codes, public.messaging_identity_codes,
  public.messaging_conversation_bindings, public.messaging_identities,
  public.messaging_webhook_events, public.messaging_fund_expense_drafts
from public, anon, authenticated;
grant select on public.messaging_bind_codes, public.messaging_identity_codes,
  public.messaging_conversation_bindings, public.messaging_identities,
  public.messaging_fund_expense_drafts to authenticated;
grant select, insert, update on public.messaging_conversation_bindings,
  public.messaging_identities, public.messaging_webhook_events,
  public.messaging_fund_expense_drafts to service_role;

create function public.create_messaging_bind_code(p_group_id uuid, p_provider text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  current_user_id uuid := (select auth.uid());
  raw_code text := encode(extensions.gen_random_bytes(16), 'hex');
  code_record public.messaging_bind_codes;
begin
  if p_provider not in ('line', 'discord', 'telegram') then
    raise exception 'unsupported messaging provider' using errcode = '22023';
  end if;
  if current_user_id is null or not public.is_group_owner(p_group_id) then
    raise exception 'group owner permission required' using errcode = '42501';
  end if;
  insert into public.messaging_bind_codes (group_id, provider, code_hash, expires_at, created_by)
  values (p_group_id, p_provider, extensions.digest(raw_code, 'sha256'), now() + interval '30 minutes', current_user_id)
  returning * into code_record;
  return jsonb_build_object('code', raw_code, 'expiresAt', code_record.expires_at, 'provider', p_provider);
end;
$$;

create function public.create_messaging_identity_code(p_group_id uuid, p_member_id uuid, p_provider text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  current_user_id uuid := (select auth.uid());
  current_member_id uuid;
  raw_code text := encode(extensions.gen_random_bytes(16), 'hex');
  code_record public.messaging_identity_codes;
begin
  if p_provider not in ('line', 'discord', 'telegram') then
    raise exception 'unsupported messaging provider' using errcode = '22023';
  end if;
  select id into current_member_id from public.members
  where group_id = p_group_id and user_id = current_user_id;
  if current_user_id is null or not exists (
      select 1 from public.members where group_id = p_group_id and id = p_member_id
    ) or (current_member_id is distinct from p_member_id and not public.is_group_owner(p_group_id)) then
    raise exception 'member or group owner permission required' using errcode = '42501';
  end if;
  insert into public.messaging_identity_codes (group_id, member_id, provider, code_hash, expires_at, created_by)
  values (p_group_id, p_member_id, p_provider, extensions.digest(raw_code, 'sha256'), now() + interval '30 minutes', current_user_id)
  returning * into code_record;
  return jsonb_build_object('code', raw_code, 'expiresAt', code_record.expires_at, 'provider', p_provider);
end;
$$;

create function public.redeem_messaging_bind_code(
  p_provider text, p_code text, p_conversation_id text, p_external_user_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  code_record public.messaging_bind_codes;
  group_record public.ledger_groups;
begin
  if p_provider not in ('line', 'discord', 'telegram') or p_code !~ '^[0-9a-f]{32}$'
    or char_length(p_conversation_id) not between 1 and 160
    or char_length(p_external_user_id) not between 1 and 160 then
    raise exception 'invalid binding input' using errcode = '22023';
  end if;
  select * into code_record from public.messaging_bind_codes
  where provider = p_provider and code_hash = extensions.digest(p_code, 'sha256') for update;
  if not found or code_record.used_at is not null or code_record.expires_at <= now() then
    raise exception 'binding code is unavailable' using errcode = '22023';
  end if;
  select * into group_record from public.ledger_groups where id = code_record.group_id and status = 'active';
  if not found then raise exception 'ledger is unavailable' using errcode = '23514'; end if;

  delete from public.messaging_conversation_bindings
  where provider = p_provider and (group_id = code_record.group_id or external_conversation_id = p_conversation_id);
  insert into public.messaging_conversation_bindings (
    group_id, provider, external_conversation_id, bound_by_external_user_id
  ) values (code_record.group_id, p_provider, p_conversation_id, p_external_user_id);
  update public.messaging_bind_codes set used_at = now() where id = code_record.id;
  return jsonb_build_object('groupId', group_record.id, 'groupName', group_record.name);
end;
$$;

create function public.redeem_messaging_identity_code(
  p_provider text, p_code text, p_external_user_id text, p_external_display_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  code_record public.messaging_identity_codes;
  group_record public.ledger_groups;
  member_record public.members;
begin
  if p_provider not in ('line', 'discord', 'telegram') or p_code !~ '^[0-9a-f]{32}$'
    or char_length(p_external_user_id) not between 1 and 160
    or char_length(trim(p_external_display_name)) not between 1 and 80 then
    raise exception 'invalid identity input' using errcode = '22023';
  end if;
  select * into code_record from public.messaging_identity_codes
  where provider = p_provider and code_hash = extensions.digest(p_code, 'sha256') for update;
  if not found or code_record.used_at is not null or code_record.expires_at <= now() then
    raise exception 'identity code is unavailable' using errcode = '22023';
  end if;
  select * into group_record from public.ledger_groups where id = code_record.group_id and status = 'active';
  select * into member_record from public.members where id = code_record.member_id and group_id = code_record.group_id;
  if group_record.id is null or member_record.id is null then
    raise exception 'ledger member is unavailable' using errcode = '23514';
  end if;

  delete from public.messaging_identities
  where provider = p_provider and group_id = code_record.group_id
    and (external_user_id = p_external_user_id or member_id = code_record.member_id);
  insert into public.messaging_identities (
    group_id, member_id, provider, external_user_id, external_display_name
  ) values (
    code_record.group_id, code_record.member_id, p_provider,
    p_external_user_id, trim(p_external_display_name)
  );
  update public.messaging_identity_codes set used_at = now() where id = code_record.id;
  return jsonb_build_object(
    'groupId', group_record.id, 'groupName', group_record.name,
    'memberId', member_record.id, 'memberName', member_record.display_name
  );
end;
$$;

create function public.begin_messaging_webhook_event(
  p_provider text, p_event_id text, p_source_message_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  event_record public.messaging_webhook_events;
begin
  if p_provider not in ('line', 'discord', 'telegram')
    or char_length(p_event_id) not between 1 and 160
    or char_length(p_source_message_id) not between 1 and 160 then
    raise exception 'invalid messaging event identity' using errcode = '22023';
  end if;
  insert into public.messaging_webhook_events (provider, webhook_event_id, source_message_id, status)
  values (p_provider, p_event_id, p_source_message_id, 'processing')
  on conflict (provider, webhook_event_id) do update set
    source_message_id = coalesce(excluded.source_message_id, public.messaging_webhook_events.source_message_id),
    status = 'processing', attempt_count = public.messaging_webhook_events.attempt_count + 1,
    processing_started_at = now(), processed_at = null, last_error = null
  where public.messaging_webhook_events.status = 'failed'
    or (public.messaging_webhook_events.status = 'processing'
      and public.messaging_webhook_events.processing_started_at < now() - interval '5 minutes')
  returning * into event_record;
  if found then return jsonb_build_object('shouldProcess', true, 'attemptCount', event_record.attempt_count); end if;
  select * into event_record from public.messaging_webhook_events
  where provider = p_provider and webhook_event_id = p_event_id;
  return jsonb_build_object('shouldProcess', false, 'attemptCount', event_record.attempt_count, 'status', event_record.status);
end;
$$;

create function public.complete_messaging_webhook_event(
  p_provider text, p_event_id text, p_success boolean,
  p_group_id uuid default null, p_error text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.messaging_webhook_events
  set status = case when p_success then 'processed' else 'failed' end,
      group_id = coalesce(p_group_id, group_id),
      processed_at = case when p_success then now() else null end,
      last_error = case when p_success then null else left(coalesce(p_error, 'unknown error'), 1000) end
  where provider = p_provider and webhook_event_id = p_event_id and status = 'processing';
  if not found then raise exception 'messaging webhook lease is unavailable' using errcode = '40001'; end if;
end;
$$;

create function public.confirm_messaging_fund_expense_draft(
  p_draft_id uuid, p_advance_member_id uuid default null, p_allow_duplicate boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  draft_record public.messaging_fund_expense_drafts;
  fund_record public.group_funds;
  duplicate_record public.fund_transactions;
  created_transaction public.fund_transactions;
  fund_result jsonb;
  duplicate_reason text;
begin
  select * into draft_record from public.messaging_fund_expense_drafts where id = p_draft_id for update;
  if not found or current_user_id is null or not public.is_group_owner(draft_record.group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;
  if draft_record.status <> 'pending' then raise exception 'messaging fund draft is not pending' using errcode = '23514'; end if;
  select * into fund_record from public.group_funds where group_id = draft_record.group_id for update;
  if not found or fund_record.status <> 'active' then raise exception 'group fund is not accepting expenses' using errcode = '23514'; end if;

  select * into duplicate_record from public.fund_transactions transaction
  where transaction.group_id = draft_record.group_id
    and transaction.cycle_number = fund_record.cycle_number
    and transaction.transaction_type = 'expense'
    and transaction.amount_delta = -draft_record.amount
    and transaction.effective_date = draft_record.effective_date
  order by case when lower(regexp_replace(trim(transaction.title), '[[:space:][:punct:]]+', '', 'g'))
    = lower(regexp_replace(trim(draft_record.title), '[[:space:][:punct:]]+', '', 'g')) then 0 else 1 end,
    transaction.created_at desc limit 1;
  if found and not coalesce(p_allow_duplicate, false) then
    duplicate_reason := case when lower(regexp_replace(trim(duplicate_record.title), '[[:space:][:punct:]]+', '', 'g'))
      = lower(regexp_replace(trim(draft_record.title), '[[:space:][:punct:]]+', '', 'g')) then 'exact_match' else 'same_amount_date' end;
    return jsonb_build_object('status', 'duplicate', 'candidate', jsonb_build_object(
      'id', duplicate_record.id, 'title', duplicate_record.title,
      'amount', abs(duplicate_record.amount_delta), 'date', duplicate_record.effective_date,
      'cycleNumber', duplicate_record.cycle_number, 'reason', duplicate_reason));
  end if;

  perform set_config('app.fund_source_member_id', draft_record.submitted_member_id::text, true);
  perform set_config('app.fund_source_type', draft_record.provider, true);
  fund_result := public.record_group_fund_expense_v2(
    draft_record.group_id, draft_record.title, draft_record.amount, draft_record.effective_date,
    'Confirmed from ' || draft_record.provider || ' messaging draft', p_advance_member_id, true
  );
  perform set_config('app.fund_source_member_id', '', true);
  perform set_config('app.fund_source_type', '', true);

  select * into created_transaction from public.fund_transactions transaction
  where transaction.group_id = draft_record.group_id
    and transaction.cycle_number = fund_record.cycle_number
    and transaction.transaction_type = 'expense'
    and transaction.title = draft_record.title
    and transaction.amount_delta = -draft_record.amount
    and transaction.effective_date = draft_record.effective_date
    and transaction.created_by = current_user_id
  order by transaction.created_at desc limit 1;
  if not found then raise exception 'created public fund transaction is unavailable' using errcode = '23514'; end if;

  update public.messaging_fund_expense_drafts
  set status = 'confirmed', confirmed_transaction_id = created_transaction.id,
      confirmed_by = current_user_id, confirmed_at = now(), raw_text = null
  where id = draft_record.id;
  return jsonb_build_object('status', 'confirmed', 'transactionId', created_transaction.id,
    'fund', public.get_group_fund(draft_record.group_id));
end;
$$;

create function public.cancel_messaging_fund_expense_draft(p_draft_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  draft_group_id uuid;
begin
  select group_id into draft_group_id from public.messaging_fund_expense_drafts where id = p_draft_id for update;
  if not found or current_user_id is null or not public.is_group_owner(draft_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;
  update public.messaging_fund_expense_drafts
  set status = 'cancelled', cancelled_by = current_user_id, cancelled_at = now(), raw_text = null
  where id = p_draft_id and status = 'pending';
  if not found then raise exception 'messaging fund draft is not pending' using errcode = '23514'; end if;
end;
$$;

alter table public.fund_transactions drop constraint fund_transactions_source_type_check;
alter table public.fund_transactions add constraint fund_transactions_source_type_check
  check (source_type in ('legacy', 'web', 'line', 'discord', 'telegram'));

-- Keep existing LINE installations working without asking groups or members to relink.
insert into public.messaging_conversation_bindings (
  group_id, provider, external_conversation_id, bound_by_external_user_id, active, created_at, updated_at
)
select group_id, 'line', line_group_id, bound_by_line_user_id, active, created_at, updated_at
from public.line_group_bindings
on conflict (provider, group_id) do nothing;

insert into public.messaging_identities (
  group_id, member_id, provider, external_user_id, external_display_name, linked_at, updated_at
)
select group_id, id, 'line', line_user_id, display_name, created_at, created_at
from public.members where line_user_id is not null
on conflict (provider, group_id, member_id) do nothing;

insert into public.messaging_webhook_events (
  provider, webhook_event_id, source_message_id, group_id, status, attempt_count,
  processing_started_at, processed_at, last_error, first_received_at, updated_at
)
select 'line', webhook_event_id, source_message_id, group_id, status, attempt_count,
  processing_started_at, processed_at, last_error, first_received_at, updated_at
from public.line_webhook_events
on conflict (provider, webhook_event_id) do nothing;

insert into public.messaging_fund_expense_drafts (
  id, group_id, provider, webhook_event_id, source_message_id,
  external_conversation_id, external_user_id, submitted_member_id, submitted_display_name,
  raw_text, title, amount, effective_date, status, parser_version,
  confirmed_transaction_id, confirmed_by, confirmed_at, cancelled_by, cancelled_at,
  created_at, updated_at
)
select draft.id, draft.group_id, 'line', draft.webhook_event_id, draft.source_message_id,
  coalesce(binding.line_group_id, 'legacy-' || draft.group_id::text), draft.source_line_user_id,
  draft.submitted_member_id, draft.submitted_display_name, draft.raw_text, draft.title,
  draft.amount, draft.effective_date, draft.status, 'line-migrated-v1',
  draft.confirmed_transaction_id, draft.confirmed_by, draft.confirmed_at,
  draft.cancelled_by, draft.cancelled_at, draft.created_at, draft.updated_at
from public.line_fund_expense_drafts draft
left join public.line_group_bindings binding on binding.group_id = draft.group_id
on conflict (id) do nothing;

create function public.guard_messaging_ledger_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'archived' and old.status <> 'archived' then
    if exists (select 1 from public.messaging_fund_expense_drafts where group_id = new.id and status = 'pending') then
      raise exception 'pending messaging drafts must be completed before archiving' using errcode = 'P0001';
    end if;
    update public.messaging_conversation_bindings set active = false where group_id = new.id and active;
  end if;
  return new;
end;
$$;
create trigger ledger_groups_guard_messaging_status
before update of status on public.ledger_groups
for each row execute function public.guard_messaging_ledger_status();

create trigger messaging_bind_codes_prevent_archived before insert or update or delete on public.messaging_bind_codes
for each row execute function public.prevent_archived_ledger_mutation();
create trigger messaging_identity_codes_prevent_archived before insert or update or delete on public.messaging_identity_codes
for each row execute function public.prevent_archived_ledger_mutation();
create trigger messaging_bindings_prevent_archived before insert or update or delete on public.messaging_conversation_bindings
for each row execute function public.prevent_archived_ledger_mutation();
create trigger messaging_identities_prevent_archived before insert or update or delete on public.messaging_identities
for each row execute function public.prevent_archived_ledger_mutation();
create trigger messaging_drafts_prevent_archived before insert or update or delete on public.messaging_fund_expense_drafts
for each row execute function public.prevent_archived_ledger_mutation();

revoke all on function public.create_messaging_bind_code(uuid, text),
  public.create_messaging_identity_code(uuid, uuid, text),
  public.confirm_messaging_fund_expense_draft(uuid, uuid, boolean),
  public.cancel_messaging_fund_expense_draft(uuid) from public, anon;
grant execute on function public.create_messaging_bind_code(uuid, text),
  public.create_messaging_identity_code(uuid, uuid, text),
  public.confirm_messaging_fund_expense_draft(uuid, uuid, boolean),
  public.cancel_messaging_fund_expense_draft(uuid) to authenticated;

revoke all on function public.redeem_messaging_bind_code(text, text, text, text),
  public.redeem_messaging_identity_code(text, text, text, text),
  public.begin_messaging_webhook_event(text, text, text),
  public.complete_messaging_webhook_event(text, text, boolean, uuid, text)
from public, anon, authenticated;
grant execute on function public.redeem_messaging_bind_code(text, text, text, text),
  public.redeem_messaging_identity_code(text, text, text, text),
  public.begin_messaging_webhook_event(text, text, text),
  public.complete_messaging_webhook_event(text, text, boolean, uuid, text)
to service_role;

insert into public.app_schema_versions (version, name)
values (48, 'provider-neutral messaging adapters');
