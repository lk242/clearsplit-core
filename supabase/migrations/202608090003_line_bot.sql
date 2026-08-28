-- LINE Bot group binding and append-first expense drafts.

create type public.line_draft_status as enum ('pending', 'needs_input', 'confirmed', 'cancelled');

create table public.line_bind_codes (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  code_hash bytea not null unique,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table public.line_group_bindings (
  group_id uuid primary key references public.ledger_groups(id) on delete cascade,
  line_group_id text not null unique check (line_group_id ~ '^C[0-9a-f]{32}$'),
  bound_by_line_user_id text check (bound_by_line_user_id is null or bound_by_line_user_id ~ '^U[0-9a-f]{32}$'),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.line_expense_drafts (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  webhook_event_id text not null unique check (char_length(webhook_event_id) between 10 and 80),
  source_message_id text not null check (char_length(source_message_id) between 1 and 80),
  source_line_user_id text check (source_line_user_id is null or source_line_user_id ~ '^U[0-9a-f]{32}$'),
  raw_text text check (raw_text is null or char_length(raw_text) <= 5000),
  title text check (title is null or char_length(title) between 1 and 120),
  amount bigint check (amount is null or amount > 0),
  payer_member_id uuid,
  participant_member_ids uuid[],
  status public.line_draft_status not null,
  issue_code text check (issue_code is null or issue_code in ('invalid_format', 'payer_not_found', 'participant_not_found', 'ambiguous_member')),
  parser_version text not null default 'line-strict-v1',
  confirmed_expense_id uuid references public.expenses(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '7 days'),
  constraint line_draft_payer_same_group_fk foreign key (payer_member_id, group_id) references public.members(id, group_id)
);

create index line_drafts_group_status_idx on public.line_expense_drafts(group_id, status, created_at desc);
create index line_drafts_source_message_idx on public.line_expense_drafts(source_message_id);

create trigger line_bindings_set_updated_at before update on public.line_group_bindings
for each row execute function public.set_updated_at();
create trigger line_drafts_set_updated_at before update on public.line_expense_drafts
for each row execute function public.set_updated_at();

create function public.create_line_bind_code(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  current_user_id uuid := (select auth.uid());
  raw_code text := encode(extensions.gen_random_bytes(16), 'hex');
  code_record public.line_bind_codes;
begin
  if current_user_id is null or not public.is_group_owner(p_group_id) then
    raise exception 'group owner permission required' using errcode = '42501';
  end if;

  insert into public.line_bind_codes (group_id, code_hash, expires_at, created_by)
  values (p_group_id, extensions.digest(raw_code, 'sha256'), now() + interval '30 minutes', current_user_id)
  returning * into code_record;

  return jsonb_build_object('code', raw_code, 'expiresAt', code_record.expires_at);
end;
$$;

create function public.redeem_line_bind_code(
  p_code text,
  p_line_group_id text,
  p_line_user_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  code_record public.line_bind_codes;
  group_record public.ledger_groups;
begin
  if p_code !~ '^[0-9a-f]{32}$' or p_line_group_id !~ '^C[0-9a-f]{32}$' then
    raise exception 'invalid binding input' using errcode = '22023';
  end if;

  select * into code_record from public.line_bind_codes
  where code_hash = extensions.digest(p_code, 'sha256')
  for update;

  if not found or code_record.used_at is not null or code_record.expires_at <= now() then
    raise exception 'binding code is unavailable' using errcode = '22023';
  end if;

  insert into public.line_group_bindings (group_id, line_group_id, bound_by_line_user_id)
  values (code_record.group_id, p_line_group_id, nullif(p_line_user_id, ''))
  on conflict (group_id) do update set
    line_group_id = excluded.line_group_id,
    bound_by_line_user_id = excluded.bound_by_line_user_id,
    active = true,
    updated_at = now();

  update public.line_bind_codes set used_at = now() where id = code_record.id;
  select * into group_record from public.ledger_groups where id = code_record.group_id;
  return jsonb_build_object('groupId', group_record.id, 'groupName', group_record.name);
end;
$$;

alter table public.line_bind_codes enable row level security;
alter table public.line_group_bindings enable row level security;
alter table public.line_expense_drafts enable row level security;

create policy line_bind_codes_owner_all on public.line_bind_codes for all to authenticated
using (public.is_group_owner(group_id)) with check (public.is_group_owner(group_id));
create policy line_bindings_select_group on public.line_group_bindings for select to authenticated
using (public.is_group_member(group_id));
create policy line_bindings_owner_update on public.line_group_bindings for update to authenticated
using (public.is_group_owner(group_id)) with check (public.is_group_owner(group_id));
create policy line_drafts_select_group on public.line_expense_drafts for select to authenticated
using (public.is_group_member(group_id));
create policy line_drafts_owner_update on public.line_expense_drafts for update to authenticated
using (public.is_group_owner(group_id)) with check (public.is_group_owner(group_id));

revoke all on function public.create_line_bind_code(uuid) from public, anon;
revoke all on function public.redeem_line_bind_code(text, text, text) from public, anon, authenticated;
grant execute on function public.create_line_bind_code(uuid) to authenticated;
grant execute on function public.redeem_line_bind_code(text, text, text) to service_role;

revoke insert, delete on public.line_group_bindings from anon, authenticated;
revoke insert, delete on public.line_expense_drafts from anon, authenticated;

create function public.confirm_line_expense_draft(p_draft_id uuid)
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
    draft_record.payer_member_id, current_date, '由 LINE #記帳 草稿確認',
    current_user_id, current_user_id
  ) returning * into expense_record;

  base_share := draft_record.amount / member_count;
  remainder := draft_record.amount % member_count;
  foreach member_id in array draft_record.participant_member_ids
  loop
    insert into public.expense_shares (expense_id, group_id, member_id, amount)
    values (
      expense_record.id,
      draft_record.group_id,
      member_id,
      base_share + case when member_index < remainder then 1 else 0 end
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
    'createdAt', expense_record.created_at
  );
end;
$$;

create function public.cancel_line_expense_draft(p_draft_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  draft_group_id uuid;
begin
  select group_id into draft_group_id from public.line_expense_drafts where id = p_draft_id;
  if draft_group_id is null or current_user_id is null or not public.is_group_member(draft_group_id) then
    raise exception 'draft access denied' using errcode = '42501';
  end if;
  update public.line_expense_drafts
  set status = 'cancelled', raw_text = null
  where id = p_draft_id and status in ('pending', 'needs_input');
end;
$$;

revoke all on function public.confirm_line_expense_draft(uuid) from public, anon;
revoke all on function public.cancel_line_expense_draft(uuid) from public, anon;
grant execute on function public.confirm_line_expense_draft(uuid) to authenticated;
grant execute on function public.cancel_line_expense_draft(uuid) to authenticated;
