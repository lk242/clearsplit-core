-- PostgreSQL comparisons against NULL return NULL. Before the first responsible
-- member is assigned, the API contract must still return a strict boolean.
create or replace function public.get_group_members(
  p_group_id uuid,
  p_setup_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not public.is_group_member(p_group_id)
    and not public.has_valid_ledger_setup_token(p_group_id, p_setup_token) then
    raise exception 'ledger access denied' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id,
      'name', m.display_name,
      'color', m.color,
      'avatarUrl', m.avatar_url,
      'createdAt', m.created_at,
      'isResponsible', coalesce(m.id = g.responsible_member_id, false)
    ) order by m.created_at, m.id)
    from public.members m
    join public.ledger_groups g on g.id = m.group_id
    where m.group_id = p_group_id
  ), '[]'::jsonb);
end;
$$;
