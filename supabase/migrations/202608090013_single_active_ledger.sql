-- ClearSplit is a reusable single-group ledger. A new ledger may only be
-- created after the current one has been deleted.
do $$
begin
  if (select count(*) from public.ledger_groups) > 1 then
    raise exception 'multiple active ledgers must be resolved before enabling singleton mode'
      using errcode = '23505';
  end if;
end;
$$;
create unique index if not exists ledger_groups_single_active_idx
  on public.ledger_groups ((true));

create or replace function public.bootstrap_ledger_group(
  p_group_name text,
  p_participants jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  current_user_id uuid := (select auth.uid());
  new_group public.ledger_groups;
  raw_setup_token text := encode(extensions.gen_random_bytes(16), 'hex');
  setup_expires_at timestamptz := now() + interval '30 days';
  participant jsonb;
  new_member public.members;
  member_rows jsonb := '[]'::jsonb;
  participant_index integer := 0;
  participant_name text;
  participant_color text;
begin
  if current_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if char_length(trim(p_group_name)) not between 1 and 80 then
    raise exception 'invalid group name' using errcode = '22023';
  end if;
  if jsonb_typeof(p_participants) <> 'array'
    or jsonb_array_length(p_participants) not between 0 and 50 then
    raise exception 'participants must contain 0 to 50 entries' using errcode = '22023';
  end if;

  -- The advisory lock provides a clear precondition error while the unique
  -- index remains the final concurrency guarantee.
  perform pg_advisory_xact_lock(20260809, 13);
  if exists (select 1 from public.ledger_groups) then
    raise exception 'an active ledger already exists' using errcode = '23505';
  end if;

  insert into public.ledger_groups (name, created_by)
  values (trim(p_group_name), current_user_id)
  returning * into new_group;

  insert into public.ledger_setup_tokens (group_id, token_hash, expires_at)
  values (new_group.id, extensions.digest(raw_setup_token, 'sha256'), setup_expires_at);

  for participant in select value from jsonb_array_elements(p_participants)
  loop
    participant_name := trim(participant->>'name');
    participant_color := coalesce(nullif(participant->>'color', ''), '#64748b');

    if char_length(participant_name) not between 1 and 80 then
      raise exception 'invalid participant name at index %', participant_index using errcode = '22023';
    end if;
    if participant_color !~ '^#[0-9A-Fa-f]{6}$' then
      raise exception 'invalid participant color at index %', participant_index using errcode = '22023';
    end if;

    insert into public.members (group_id, role, display_name, color)
    values (new_group.id, 'member', participant_name, participant_color)
    returning * into new_member;

    member_rows := member_rows || jsonb_build_array(jsonb_build_object(
      'clientId', participant->>'clientId',
      'id', new_member.id,
      'name', new_member.display_name,
      'color', new_member.color,
      'createdAt', new_member.created_at,
      'linked', false
    ));
    participant_index := participant_index + 1;
  end loop;

  return jsonb_build_object(
    'groupId', new_group.id,
    'groupName', new_group.name,
    'members', member_rows,
    'setupToken', raw_setup_token,
    'setupExpiresAt', setup_expires_at
  );
end;
$$;
