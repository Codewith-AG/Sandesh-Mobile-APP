-- ============================================================
-- Fix: all group members must be able to SEE and SEND messages.
--
-- Root cause: the group membership + sender checks compared the
-- lowercase-stored usernames (group_members.username /
-- group_messages.sender_username) against the mixed-case
-- profiles.username. Members whose profile username contained any
-- uppercase letters were therefore denied both read and insert on
-- group_messages, so they could neither see nor send group messages.
--
-- Fix: make every group membership + sender check FULLY
-- case-insensitive. username_of() already lower()s profiles.username;
-- we now also lower() the stored column in every comparison and
-- normalise existing rows.
--
-- Safe / idempotent: CREATE OR REPLACE + DROP POLICY IF EXISTS.
-- ============================================================

-- 0. Normalise any existing mixed-case rows so comparisons are stable.
UPDATE public.group_members  SET username        = lower(username)        WHERE username        <> lower(username);
UPDATE public.group_messages SET sender_username = lower(sender_username) WHERE sender_username <> lower(sender_username);
UPDATE public.groups         SET created_by      = lower(created_by)      WHERE created_by      <> lower(created_by);

-- 1. Case-insensitive membership helpers.
CREATE OR REPLACE FUNCTION public.is_group_member(gid uuid) RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM group_members
    WHERE group_id = gid
      AND lower(username) = public.username_of(auth.uid())
  );
$$;

CREATE OR REPLACE FUNCTION public.is_group_admin(gid uuid) RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM group_members
    WHERE group_id = gid
      AND lower(username) = public.username_of(auth.uid())
      AND role = 'admin'
  );
$$;

REVOKE ALL ON FUNCTION public.is_group_member(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_group_member(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.is_group_admin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_group_admin(uuid) TO authenticated;

-- 2. group_messages: every member can READ; every member can SEND as themselves.
DROP POLICY IF EXISTS "Members can read group messages" ON public.group_messages;
CREATE POLICY "Members can read group messages"
  ON public.group_messages FOR SELECT
  TO authenticated
  USING (public.is_group_member(group_id));

DROP POLICY IF EXISTS "Members can send group messages" ON public.group_messages;
CREATE POLICY "Members can send group messages"
  ON public.group_messages FOR INSERT
  TO authenticated
  WITH CHECK (
    lower(sender_username) = public.username_of(auth.uid())
    AND public.is_group_member(group_id)
  );

-- 3. Keep group_members / groups consistent with the helpers above.
DROP POLICY IF EXISTS "Members can view fellow members" ON public.group_members;
CREATE POLICY "Members can view fellow members"
  ON public.group_members FOR SELECT
  TO authenticated
  USING (public.is_group_member(group_id));

DROP POLICY IF EXISTS "Members can view their groups" ON public.groups;
CREATE POLICY "Members can view their groups"
  ON public.groups FOR SELECT
  TO authenticated
  USING (public.is_group_member(id));

-- 4. Ensure realtime delivers new group messages to every member.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'group_messages'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.group_messages';
  END IF;
END $$;
