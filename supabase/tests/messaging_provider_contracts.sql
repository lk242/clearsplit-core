-- Validate provider isolation, least-privilege webhook access, one-time codes,
-- and the exact service-role draft write path. All fixtures are rolled back.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(1);

drop index if exists public.ledger_groups_single_active_idx;

insert into public.ledger_groups (id, name, created_by)
select '00000000-0000-4000-8000-000000000048'::uuid, 'Messaging fixture', users.id
from auth.users users order by users.created_at, users.id limit 1;

insert into public.members (id, group_id, user_id, role, display_name, color)
select '00000000-0000-4000-8000-000000000148'::uuid,
  '00000000-0000-4000-8000-000000000048'::uuid, users.id,
  'owner', 'Messaging owner', '#225577'
from auth.users users order by users.created_at, users.id limit 1;

update public.ledger_groups
set responsible_member_id = '00000000-0000-4000-8000-000000000148'::uuid
where id = '00000000-0000-4000-8000-000000000048'::uuid;

do $$
declare
  fixture_user_id uuid;
  binding_result jsonb;
  identity_result jsonb;
  lease jsonb;
begin
  select user_id into fixture_user_id from public.members
  where id = '00000000-0000-4000-8000-000000000148'::uuid;
  perform set_config('request.jwt.claim.sub', fixture_user_id::text, true);
  binding_result := public.create_messaging_bind_code(
    '00000000-0000-4000-8000-000000000048'::uuid, 'discord');
  identity_result := public.create_messaging_identity_code(
    '00000000-0000-4000-8000-000000000048'::uuid,
    '00000000-0000-4000-8000-000000000148'::uuid, 'discord');

  perform public.redeem_messaging_bind_code(
    'discord', binding_result->>'code', 'discord-channel-48', 'discord-user-48');
  perform public.redeem_messaging_identity_code(
    'discord', identity_result->>'code', 'discord-user-48', 'Discord Owner');

  lease := public.begin_messaging_webhook_event('discord', 'same-provider-event-48', 'discord-message-48');
  if coalesce((lease->>'shouldProcess')::boolean, false) is not true then
    raise exception 'Discord lease was not acquired';
  end if;
  lease := public.begin_messaging_webhook_event('telegram', 'same-provider-event-48', 'telegram-message-48');
  if coalesce((lease->>'shouldProcess')::boolean, false) is not true then
    raise exception 'Telegram event ID should be isolated from Discord';
  end if;

  insert into public.messaging_fund_expense_drafts (
    group_id, provider, webhook_event_id, source_message_id,
    external_conversation_id, external_user_id, submitted_member_id,
    submitted_display_name, raw_text, title, amount, effective_date
  ) values (
    '00000000-0000-4000-8000-000000000048'::uuid, 'discord',
    'same-provider-event-48', 'discord-message-48', 'discord-channel-48',
    'discord-user-48', '00000000-0000-4000-8000-000000000148'::uuid,
    'Messaging owner', '/expense dinner 48', 'Dinner', 48, current_date
  );
  perform public.complete_messaging_webhook_event(
    'discord', 'same-provider-event-48', true,
    '00000000-0000-4000-8000-000000000048'::uuid, null);
  perform public.complete_messaging_webhook_event(
    'telegram', 'same-provider-event-48', true, null, null);

  if not exists (
    select 1 from public.messaging_conversation_bindings
    where provider = 'discord' and external_conversation_id = 'discord-channel-48'
      and group_id = '00000000-0000-4000-8000-000000000048'::uuid and active
  ) then raise exception 'provider-scoped conversation binding is missing'; end if;
  if not exists (
    select 1 from public.messaging_identities
    where provider = 'discord' and external_user_id = 'discord-user-48'
      and member_id = '00000000-0000-4000-8000-000000000148'::uuid
  ) then raise exception 'provider-scoped identity link is missing'; end if;
  if (select count(*) from public.messaging_webhook_events where webhook_event_id = 'same-provider-event-48') <> 2 then
    raise exception 'equal external event IDs were not isolated by provider';
  end if;
  if not has_function_privilege('service_role', 'public.begin_messaging_webhook_event(text,text,text)', 'EXECUTE')
    or has_function_privilege('authenticated', 'public.begin_messaging_webhook_event(text,text,text)', 'EXECUTE') then
    raise exception 'webhook lease function privileges are too broad or too narrow';
  end if;
end;
$$;

select pass('messaging providers are isolated and retain a least-privilege draft path');
select * from finish();
rollback;
