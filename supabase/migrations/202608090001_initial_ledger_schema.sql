-- ClearSplit initial cloud schema.
-- Money is stored as integer TWD. Expense shares must balance exactly at commit.

create type public.group_role as enum ('owner', 'member');
create type public.settlement_direction as enum ('payment', 'receipt');
create type public.settlement_event_action as enum ('confirm', 'revoke');

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(trim(display_name)) between 1 and 80),
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ledger_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 1 and 80),
  currency text not null default 'TWD' check (currency = 'TWD'),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  role public.group_role not null default 'member',
  display_name text not null check (char_length(trim(display_name)) between 1 and 80),
  avatar_url text,
  color text not null default '#64748b' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  created_at timestamptz not null default now(),
  unique (id, group_id),
  unique (group_id, user_id)
);

create table public.group_invites (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  token_hash bytea not null unique,
  expires_at timestamptz not null,
  max_uses integer not null default 50 check (max_uses between 1 and 500),
  use_count integer not null default 0 check (use_count between 0 and max_uses),
  revoked_at timestamptz,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  title text not null check (char_length(trim(title)) between 1 and 120),
  amount bigint not null check (amount > 0),
  category text not null default 'other' check (category in ('food', 'transport', 'shopping', 'lodging', 'other')),
  payer_member_id uuid not null,
  expense_date date not null,
  note text check (note is null or char_length(note) <= 1000),
  version bigint not null default 1 check (version > 0),
  created_by uuid not null references auth.users(id),
  updated_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, group_id),
  constraint expenses_payer_same_group_fk
    foreign key (payer_member_id, group_id)
    references public.members(id, group_id)
);

create table public.expense_shares (
  expense_id uuid not null,
  group_id uuid not null,
  member_id uuid not null,
  amount bigint not null check (amount >= 0),
  created_at timestamptz not null default now(),
  primary key (expense_id, member_id),
  constraint expense_shares_expense_same_group_fk
    foreign key (expense_id, group_id)
    references public.expenses(id, group_id) on delete cascade,
  constraint expense_shares_member_same_group_fk
    foreign key (member_id, group_id)
    references public.members(id, group_id)
);

create table public.settlement_confirmation_events (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  member_id uuid not null,
  direction public.settlement_direction not null,
  fingerprint text not null check (char_length(fingerprint) between 1 and 8000),
  action public.settlement_event_action not null,
  actor_user_id uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  constraint settlement_member_same_group_fk
    foreign key (member_id, group_id)
    references public.members(id, group_id)
);

create table public.audit_events (
  id bigint generated always as identity primary key,
  group_id uuid not null references public.ledger_groups(id) on delete cascade,
  actor_user_id uuid references auth.users(id),
  entity_type text not null check (entity_type in ('member', 'expense', 'expense_share', 'settlement_confirmation')),
  entity_id text not null,
  action text not null check (action in ('insert', 'update', 'delete', 'confirm', 'revoke')),
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz not null default now()
);

create index members_group_id_idx on public.members(group_id);
create index members_user_id_idx on public.members(user_id) where user_id is not null;
create index expenses_group_date_idx on public.expenses(group_id, expense_date desc, created_at desc);
create index expense_shares_group_idx on public.expense_shares(group_id);
create index settlement_events_lookup_idx on public.settlement_confirmation_events(group_id, member_id, direction, created_at desc);
create index audit_events_group_time_idx on public.audit_events(group_id, created_at desc);

create function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_set_updated_at before update on public.profiles
for each row execute function public.set_updated_at();
create trigger groups_set_updated_at before update on public.ledger_groups
for each row execute function public.set_updated_at();
create trigger expenses_set_updated_at before update on public.expenses
for each row execute function public.set_updated_at();

create function public.assert_expense_balanced()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  target_expense_id uuid;
  expected_amount bigint;
  allocated_amount bigint;
begin
  if tg_table_name = 'expenses' then
    target_expense_id := coalesce(new.id, old.id);
  else
    target_expense_id := coalesce(new.expense_id, old.expense_id);
  end if;

  select amount into expected_amount from public.expenses where id = target_expense_id;
  if expected_amount is null then
    return null;
  end if;

  select coalesce(sum(amount), 0) into allocated_amount
  from public.expense_shares where expense_id = target_expense_id;

  if allocated_amount <> expected_amount then
    raise exception 'expense % is not balanced: shares %, expense %', target_expense_id, allocated_amount, expected_amount
      using errcode = '23514';
  end if;
  return null;
end;
$$;

create constraint trigger expense_shares_balance_check
after insert or update or delete on public.expense_shares
deferrable initially deferred
for each row execute function public.assert_expense_balanced();

create constraint trigger expenses_balance_check
after insert or update on public.expenses
deferrable initially deferred
for each row execute function public.assert_expense_balanced();

create function public.is_group_member(target_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.members
    where group_id = target_group_id and user_id = (select auth.uid())
  );
$$;

create function public.is_group_owner(target_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.ledger_groups
    where id = target_group_id and created_by = (select auth.uid())
  );
$$;

revoke all on function public.is_group_member(uuid) from public;
revoke all on function public.is_group_owner(uuid) from public;
grant execute on function public.is_group_member(uuid) to authenticated;
grant execute on function public.is_group_owner(uuid) to authenticated;

create function public.write_audit_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  row_group_id uuid := coalesce(new.group_id, old.group_id);
  row_entity_id text;
begin
  row_entity_id := coalesce(new.id::text, old.id::text);
  insert into public.audit_events (
    group_id, actor_user_id, entity_type, entity_id, action, old_data, new_data
  ) values (
    row_group_id,
    (select auth.uid()),
    tg_argv[0],
    row_entity_id,
    lower(tg_op),
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end
  );
  return coalesce(new, old);
end;
$$;

create trigger members_audit after insert or update or delete on public.members
for each row execute function public.write_audit_event('member');
create trigger expenses_audit after insert or update or delete on public.expenses
for each row execute function public.write_audit_event('expense');

create function public.write_share_audit_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.audit_events (
    group_id, actor_user_id, entity_type, entity_id, action, old_data, new_data
  ) values (
    coalesce(new.group_id, old.group_id),
    (select auth.uid()),
    'expense_share',
    coalesce(new.expense_id, old.expense_id)::text || ':' || coalesce(new.member_id, old.member_id)::text,
    lower(tg_op),
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end
  );
  return coalesce(new, old);
end;
$$;

create trigger expense_shares_audit after insert or update or delete on public.expense_shares
for each row execute function public.write_share_audit_event();

create function public.write_settlement_audit_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.audit_events (
    group_id, actor_user_id, entity_type, entity_id, action, new_data
  ) values (
    new.group_id, new.actor_user_id, 'settlement_confirmation', new.id::text, new.action::text, to_jsonb(new)
  );
  return new;
end;
$$;

create trigger settlement_events_audit after insert on public.settlement_confirmation_events
for each row execute function public.write_settlement_audit_event();

alter table public.profiles enable row level security;
alter table public.ledger_groups enable row level security;
alter table public.members enable row level security;
alter table public.group_invites enable row level security;
alter table public.expenses enable row level security;
alter table public.expense_shares enable row level security;
alter table public.settlement_confirmation_events enable row level security;
alter table public.audit_events enable row level security;

create policy profiles_select_own on public.profiles for select to authenticated
using ((select auth.uid()) = user_id);
create policy profiles_insert_own on public.profiles for insert to authenticated
with check ((select auth.uid()) = user_id);
create policy profiles_update_own on public.profiles for update to authenticated
using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

create policy groups_select_members on public.ledger_groups for select to authenticated
using (created_by = (select auth.uid()) or public.is_group_member(id));
create policy groups_insert_owner on public.ledger_groups for insert to authenticated
with check (created_by = (select auth.uid()));
create policy groups_update_owner on public.ledger_groups for update to authenticated
using (public.is_group_owner(id)) with check (public.is_group_owner(id));
create policy groups_delete_owner on public.ledger_groups for delete to authenticated
using (public.is_group_owner(id));

create policy members_select_group on public.members for select to authenticated
using (public.is_group_owner(group_id) or public.is_group_member(group_id));
create policy members_insert_owner on public.members for insert to authenticated
with check (public.is_group_owner(group_id));
create policy members_update_owner_or_self on public.members for update to authenticated
using (public.is_group_owner(group_id) or user_id = (select auth.uid()))
with check (public.is_group_owner(group_id) or user_id = (select auth.uid()));
create policy members_delete_owner on public.members for delete to authenticated
using (public.is_group_owner(group_id));

create policy invites_owner_all on public.group_invites for all to authenticated
using (public.is_group_owner(group_id)) with check (public.is_group_owner(group_id));

create policy expenses_select_group on public.expenses for select to authenticated
using (public.is_group_member(group_id));
create policy expenses_insert_group on public.expenses for insert to authenticated
with check (public.is_group_member(group_id) and created_by = (select auth.uid()) and updated_by = (select auth.uid()));
create policy expenses_update_group on public.expenses for update to authenticated
using (public.is_group_member(group_id))
with check (public.is_group_member(group_id) and updated_by = (select auth.uid()));
create policy expenses_delete_group on public.expenses for delete to authenticated
using (public.is_group_member(group_id));

create policy shares_select_group on public.expense_shares for select to authenticated
using (public.is_group_member(group_id));
create policy shares_insert_group on public.expense_shares for insert to authenticated
with check (public.is_group_member(group_id));
create policy shares_update_group on public.expense_shares for update to authenticated
using (public.is_group_member(group_id)) with check (public.is_group_member(group_id));
create policy shares_delete_group on public.expense_shares for delete to authenticated
using (public.is_group_member(group_id));

create policy settlement_events_select_group on public.settlement_confirmation_events for select to authenticated
using (public.is_group_member(group_id));
create policy settlement_events_insert_group on public.settlement_confirmation_events for insert to authenticated
with check (
  public.is_group_member(group_id)
  and actor_user_id = (select auth.uid())
  and exists (
    select 1 from public.members
    where members.id = member_id and members.group_id = settlement_confirmation_events.group_id
  )
);

create policy audit_select_group on public.audit_events for select to authenticated
using (public.is_group_member(group_id));

create view public.current_settlement_confirmations
with (security_invoker = true)
as
select distinct on (group_id, member_id, direction)
  id, group_id, member_id, direction, fingerprint, action, actor_user_id, created_at
from public.settlement_confirmation_events
order by group_id, member_id, direction, created_at desc, id desc;

revoke insert, update, delete on public.audit_events from anon, authenticated;
revoke update, delete on public.settlement_confirmation_events from anon, authenticated;
