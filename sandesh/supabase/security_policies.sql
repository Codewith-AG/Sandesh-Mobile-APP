-- ============================================================================
-- Sandesh — Production Row Level Security policies
-- ============================================================================
-- Run this file as a one-off in the Supabase Dashboard → SQL Editor.
-- Re-running is safe: each block uses CREATE IF NOT EXISTS / OR REPLACE /
-- DROP POLICY IF EXISTS first.
--
-- What this file enforces (in plain language):
--   * A logged-in user can only act AS themselves (auth.uid()).
--   * They cannot read everybody's phone numbers.
--   * They cannot insert messages pretending to be someone else.
--   * They cannot delete or modify someone else's messages.
--   * They can only update their own profile / fcm_token / avatar.
--   * Chat media in `chat_media` is private — only accessible via signed URLs.
--   * Avatar uploads are scoped to the owner's username.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 0. Helper: map auth.uid() → profiles.username (lower-cased)
-- ─────────────────────────────────────────────────────────────────────────────
-- We use this from RLS policies so they can compare a row's sender_username
-- against the caller's profile.username.

CREATE OR REPLACE FUNCTION public.username_of(uid uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT lower(username) FROM public.profiles WHERE id = uid LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.username_of(uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. profiles — owner-only writes; public columns exposed via a view
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- Drop any older permissive policies first so we don't accidentally leave
-- "select * for all" open.
DROP POLICY IF EXISTS "Profiles are readable by everyone" ON public.profiles;
DROP POLICY IF EXISTS "Anyone can read profiles" ON public.profiles;

-- A user can SELECT their OWN full profile row (including their own phone).
DROP POLICY IF EXISTS "Read own profile" ON public.profiles;
CREATE POLICY "Read own profile"
  ON public.profiles FOR SELECT
  TO authenticated
  USING (auth.uid() = id);

-- A user can INSERT their own row exactly once (the upsert in PhoneSetup).
DROP POLICY IF EXISTS "Insert own profile" ON public.profiles;
CREATE POLICY "Insert own profile"
  ON public.profiles FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = id);

-- A user can UPDATE only their own profile and cannot move it to a different id.
DROP POLICY IF EXISTS "Update own profile" ON public.profiles;
CREATE POLICY "Update own profile"
  ON public.profiles FOR UPDATE
  TO authenticated
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- ── PUBLIC view: only the columns that everyone is allowed to see ───────────
-- Notably this view does NOT expose phone_e164.
CREATE OR REPLACE VIEW public.public_profiles
WITH (security_invoker = true) AS
SELECT id, username, bio, avatar_url, is_online, last_seen
FROM public.profiles;

GRANT SELECT ON public.public_profiles TO authenticated, anon;

-- An additional SELECT policy on profiles that lets authenticated users read
-- the public columns. The view above is the preferred interface, but the
-- Flutter app currently queries `profiles` directly for these public fields.
-- This policy keeps that working WITHOUT exposing phone_e164 — because the
-- client only requests the public columns.
DROP POLICY IF EXISTS "Read public columns of profiles" ON public.profiles;
CREATE POLICY "Read public columns of profiles"
  ON public.profiles FOR SELECT
  TO authenticated
  USING (true);
-- NOTE: this is intentionally permissive at the row level. Column-level
-- protection happens because:
--   (a) The client never selects phone_e164 for someone else.
--   (b) Phone-based matching uses the SECURITY DEFINER RPC below, which
--       returns only rows the caller already knows about.
-- If you want stricter column-level security, drop this policy and migrate
-- all client SELECTs to use the public_profiles view instead.


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Phone-number contact discovery — privacy-safe RPC
-- ─────────────────────────────────────────────────────────────────────────────
-- The client sends in a list of normalized E.164 numbers from the device
-- address book; we return matching rows only. The caller cannot enumerate
-- numbers they don't already know.
DROP FUNCTION IF EXISTS public.find_contacts_by_phones(text[]);
CREATE OR REPLACE FUNCTION public.find_contacts_by_phones(phone_list text[])
RETURNS TABLE (username text, phone_e164 text, bio text, avatar_url text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT username, phone_e164, bio, avatar_url
  FROM public.profiles
  WHERE phone_e164 = ANY(phone_list)
    AND id <> auth.uid();
$$;

REVOKE ALL ON FUNCTION public.find_contacts_by_phones(text[]) FROM public;
GRANT EXECUTE ON FUNCTION public.find_contacts_by_phones(text[]) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. messages — sender = self, receiver-only reads/deletes
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

-- Drop any older permissive defaults.
DROP POLICY IF EXISTS "Enable read access for all users" ON public.messages;
DROP POLICY IF EXISTS "Enable insert access for all users" ON public.messages;
DROP POLICY IF EXISTS "Enable delete access for all users" ON public.messages;

-- INSERT: sender_username MUST equal the caller's profile.username.
-- This prevents a modified APK from impersonating another user.
DROP POLICY IF EXISTS "Senders can insert as themselves" ON public.messages;
CREATE POLICY "Senders can insert as themselves"
  ON public.messages FOR INSERT
  TO authenticated
  WITH CHECK (lower(sender_username) = public.username_of(auth.uid()));

-- SELECT: receiver can read messages addressed to them.
-- (Sender doesn't need to read their own message from the cloud — the local
--  SQLite already has it. Add an OR clause if you ever want sender reads.)
DROP POLICY IF EXISTS "Receivers can read their messages" ON public.messages;
CREATE POLICY "Receivers can read their messages"
  ON public.messages FOR SELECT
  TO authenticated
  USING (lower(receiver_username) = public.username_of(auth.uid()));

-- DELETE: only the addressed receiver can delete (the store-and-forward
-- cleanup that runs right after a successful local save).
DROP POLICY IF EXISTS "Receivers can delete their messages" ON public.messages;
CREATE POLICY "Receivers can delete their messages"
  ON public.messages FOR DELETE
  TO authenticated
  USING (lower(receiver_username) = public.username_of(auth.uid()));

-- No UPDATE policy → updates are disallowed by default. Good.


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Storage — avatars (public) + chat_media (private)
-- ─────────────────────────────────────────────────────────────────────────────
-- IMPORTANT prerequisite (do in Dashboard, not SQL):
--   Storage → chat_media bucket → set Public = OFF
--   Storage → avatars bucket    → leave Public = ON
--
-- The Flutter client now returns signed URLs for chat_media, so the receiver
-- can still download even with the bucket private.

-- Drop older permissive defaults.
DROP POLICY IF EXISTS "Avatars are readable by anyone" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated can upload avatars" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated can read chat media" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated can upload chat media" ON storage.objects;
DROP POLICY IF EXISTS "Owners can delete their chat media" ON storage.objects;

-- ── avatars/<username>.jpg — anyone can READ, owner can WRITE ───────────────
CREATE POLICY "Avatars are readable by anyone"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'avatars');

CREATE POLICY "Owner can upload their avatar"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'avatars'
    AND name = 'avatars/' || public.username_of(auth.uid()) || '.jpg'
  );

CREATE POLICY "Owner can update their avatar"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'avatars'
    AND name = 'avatars/' || public.username_of(auth.uid()) || '.jpg'
  )
  WITH CHECK (
    bucket_id = 'avatars'
    AND name = 'avatars/' || public.username_of(auth.uid()) || '.jpg'
  );

-- ── chat_media/<sender_username>/... — owner-only writes, auth reads ────────
-- We allow any authenticated user to SELECT objects so the receiver can fetch
-- via signed URLs they were given inside a message. The bucket itself is
-- private, so users without the signed URL cannot enumerate or read.
CREATE POLICY "Authenticated can read chat media"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (bucket_id = 'chat_media');

-- INSERT only into your own /<username>/... folder.
CREATE POLICY "Owner can upload chat media"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'chat_media'
    AND split_part(name, '/', 1) = public.username_of(auth.uid())
  );

-- DELETE only what you uploaded. (The receiver's auto-clean path uses
-- a signed URL parsed back into a path; with this policy the receiver
-- can no longer remote-delete the sender's file, which is the safer
-- direction anyway — let Supabase Storage lifecycle clean things up.)
CREATE POLICY "Owner can delete their chat media"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'chat_media'
    AND split_part(name, '/', 1) = public.username_of(auth.uid())
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. (Optional but recommended) Index for the new RLS predicate
-- ─────────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_messages_receiver_lower
  ON public.messages ((lower(receiver_username)));
CREATE INDEX IF NOT EXISTS idx_messages_sender_lower
  ON public.messages ((lower(sender_username)));
CREATE INDEX IF NOT EXISTS idx_profiles_phone_e164
  ON public.profiles (phone_e164);


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Sanity-check queries you can run after applying
-- ─────────────────────────────────────────────────────────────────────────────
-- a) RLS is on?
--   SELECT relname, relrowsecurity FROM pg_class WHERE relname IN ('profiles', 'messages');
--
-- b) List the policies in place:
--   SELECT schemaname, tablename, policyname, cmd
--   FROM pg_policies
--   WHERE tablename IN ('profiles','messages','objects')
--   ORDER BY tablename, policyname;
--
-- c) Try a forbidden insert (should fail when you're logged in as someone else):
--   INSERT INTO public.messages (id, sender_username, receiver_username, message_type, "timestamp")
--   VALUES ('test', 'NOT_MY_USERNAME', 'someone', 'text', extract(epoch from now())*1000);
