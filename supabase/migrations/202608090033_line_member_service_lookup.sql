-- The LINE Edge Function must resolve a verified LINE user to the stable Auth
-- identity shared by LIFF and the formal site. Keep this server-only and grant
-- only the two columns used by that lookup.
grant select (line_user_id, user_id) on public.members to service_role;

insert into public.app_schema_versions (version, name)
values (33, 'service-only LINE member identity lookup');
