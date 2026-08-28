-- Expose only the signed-in user's verified display profile. The LINE user ID
-- remains service-only and is never returned to the browser.

create function public.get_my_line_profile()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'displayName', identity.display_name,
    'avatarUrl', identity.avatar_url
  )
  from public.line_identities identity
  where identity.user_id = (select auth.uid());
$$;

revoke all on function public.get_my_line_profile() from public, anon;
grant execute on function public.get_my_line_profile() to authenticated;

insert into public.app_schema_versions (version, name)
values (46, 'persisted LINE account profile for personalized app startup');
