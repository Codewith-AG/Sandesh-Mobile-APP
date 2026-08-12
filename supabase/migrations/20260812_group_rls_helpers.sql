CREATE OR REPLACE FUNCTION public.is_group_member(gid uuid) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM group_members
    WHERE group_id = gid
      AND username = public.username_of(auth.uid())
  );
$$;

CREATE OR REPLACE FUNCTION public.is_group_admin(gid uuid) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM group_members
    WHERE group_id = gid
      AND username = public.username_of(auth.uid())
      AND role = 'admin'
  );
$$;

REVOKE ALL ON FUNCTION public.is_group_member(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_group_member(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.is_group_admin(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_group_admin(uuid) TO authenticated;

-- Update group_members policies
DROP POLICY IF EXISTS "Members can view fellow members" ON group_members;
CREATE POLICY "Members can view fellow members" ON group_members
  FOR SELECT
  USING (public.is_group_member(group_id));

DROP POLICY IF EXISTS "Admins can add members" ON group_members;
CREATE POLICY "Admins can add members" ON group_members
  FOR INSERT
  WITH CHECK (
    public.is_group_admin(group_id)
    OR username = public.username_of(auth.uid())
  );

DROP POLICY IF EXISTS "Admins can remove members" ON group_members;
CREATE POLICY "Admins can remove members" ON group_members
  FOR DELETE
  USING (
    public.is_group_admin(group_id)
    OR username = public.username_of(auth.uid())
  );

-- Update groups policies
DROP POLICY IF EXISTS "Members can view their groups" ON groups;
CREATE POLICY "Members can view their groups" ON groups
  FOR SELECT
  USING (public.is_group_member(id));

