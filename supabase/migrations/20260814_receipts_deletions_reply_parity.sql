-- ============================================================
-- Message receipts (ticks), delete-for-everyone, and reply parity.
--
-- This migration DOCUMENTS and GUARANTEES the backend state the app
-- now depends on for features #1–#4:
--   #1 select / delete (for me / for everyone)  -> message_deletions
--   #2 swipe-to-reply                           -> reply_to_* columns
--   #3 reply to photo / video                   -> reply_to_type column
--   #4 sent / delivered / read ticks            -> message_receipts
--
-- The live database already has all of this (message_receipts,
-- message_deletions, the reply_to_* columns on messages and
-- group_messages, RLS, and realtime publication). This file exists so
-- the schema is reproducible from the repo. It is FULLY IDEMPOTENT and
-- makes NO destructive changes — every statement is guarded by
-- IF NOT EXISTS / IF EXISTS and can be safely re-run.
-- ============================================================

-- 1. Reply parity columns on 1:1 messages (no-op if already present).
ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS reply_to_id     text,
  ADD COLUMN IF NOT EXISTS reply_to_sender text,
  ADD COLUMN IF NOT EXISTS reply_to_text   text,
  ADD COLUMN IF NOT EXISTS reply_to_type   text;

-- 2. Reply parity columns on group messages (no-op if already present).
ALTER TABLE public.group_messages
  ADD COLUMN IF NOT EXISTS reply_to_id     text,
  ADD COLUMN IF NOT EXISTS reply_to_sender text,
  ADD COLUMN IF NOT EXISTS reply_to_text   text,
  ADD COLUMN IF NOT EXISTS reply_to_type   text;

-- 3. message_receipts: one row per (message, reader) recording the
--    highest status that reader has reached ('delivered' | 'read').
--    The message author reads these back to render ticks.
CREATE TABLE IF NOT EXISTS public.message_receipts (
  message_id      text        NOT NULL,
  sender_username text        NOT NULL,
  reader_username text        NOT NULL,
  status          text        NOT NULL DEFAULT 'read',
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, reader_username)
);

-- 4. message_deletions: records a delete-for-everyone so every
--    recipient device can remove its local copy on sync / realtime.
CREATE TABLE IF NOT EXISTS public.message_deletions (
  message_id       text        NOT NULL,
  sender_username  text        NOT NULL,
  receiver_username text       NOT NULL,
  is_group         boolean     NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, receiver_username)
);

-- 5. RLS is already enabled and correctly policied on both tables in the
--    live database, so this migration intentionally DOES NOT create,
--    drop, or alter any policy (per the "RLS already set up correctly"
--    requirement). We only assert RLS is on, which is a no-op when it
--    already is — never a destructive change.
ALTER TABLE public.message_receipts  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_deletions ENABLE ROW LEVEL SECURITY;

-- 6. Realtime: ensure the four tables the client subscribes to are in
--    the supabase_realtime publication (guarded, so re-running is safe).
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['messages','group_messages','message_receipts','message_deletions']
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
  END LOOP;
END $$;

-- 7. Realtime DELETE payloads must carry the primary key so clients can
--    identify which message was removed. The PK is included under the
--    default replica identity, so no change is required here — noted for
--    clarity only.
