-- ============================================================
-- Security hardening (2026-08-14)
-- Sync with the Sandesh UI fixes (calls history, group messages).
--
-- Addresses Supabase security advisors:
--   * SECURITY DEFINER functions executable by the anon role
--     (0028_anon_security_definer_function_executable)
--   * check_auth_user() had a mutable search_path
--     (0011_function_search_path_mutable)
--
-- Strategy: keep EXECUTE for `authenticated` (needed by RLS + the app),
-- revoke it from `anon`/PUBLIC so unauthenticated callers cannot invoke
-- these privileged functions via /rest/v1/rpc/*.
-- ============================================================

-- 1. Trigger helper on auth.users. It only runs from the BEFORE INSERT
--    trigger, so NO role needs direct EXECUTE. Also pin its search_path.
ALTER FUNCTION public.check_auth_user() SET search_path = public;
REVOKE ALL ON FUNCTION public.check_auth_user() FROM PUBLIC, anon, authenticated;

-- 2. RLS helper functions — used inside row-level security policies.
--    Only signed-in users evaluate these; anon never should.
REVOKE ALL ON FUNCTION public.username_of(uuid)        FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.username_of(uuid)        TO authenticated;

REVOKE ALL ON FUNCTION public.is_group_member(uuid)    FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.is_group_member(uuid)    TO authenticated;

REVOKE ALL ON FUNCTION public.is_group_admin(uuid)     FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.is_group_admin(uuid)     TO authenticated;

-- 3. RPCs invoked by the app AFTER the user is authenticated.
REVOKE ALL ON FUNCTION public.create_group(text, text, text, text[]) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.create_group(text, text, text, text[]) TO authenticated;

REVOKE ALL ON FUNCTION public.find_contacts_by_phones(text[]) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.find_contacts_by_phones(text[]) TO authenticated;

REVOKE ALL ON FUNCTION public.relink_profile_to_new_auth(text, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.relink_profile_to_new_auth(text, uuid) TO authenticated;
