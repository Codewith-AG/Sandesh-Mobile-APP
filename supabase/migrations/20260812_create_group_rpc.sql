CREATE OR REPLACE FUNCTION public.create_group(
    p_name text,
    p_description text,
    p_avatar_url text,
    p_members text[]
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_group_id uuid;
    v_creator text;
    v_member text;
BEGIN
    v_creator := public.username_of(auth.uid());
    IF v_creator IS NULL THEN
        RAISE EXCEPTION 'Not authenticated or username not found';
    END IF;

    -- 1. Insert into groups
    INSERT INTO public.groups (name, description, avatar_url, created_by)
    VALUES (p_name, COALESCE(p_description, ''), COALESCE(p_avatar_url, ''), v_creator)
    RETURNING id INTO v_group_id;

    -- 2. Insert creator as admin
    INSERT INTO public.group_members (group_id, username, role)
    VALUES (v_group_id, v_creator, 'admin');

    -- 3. Insert other members
    IF p_members IS NOT NULL THEN
        FOREACH v_member IN ARRAY p_members
        LOOP
            IF v_member <> v_creator THEN
                INSERT INTO public.group_members (group_id, username, role)
                VALUES (v_group_id, v_member, 'member');
            END IF;
        END LOOP;
    END IF;

    RETURN v_group_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_group(text, text, text, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_group(text, text, text, text[]) TO authenticated;
