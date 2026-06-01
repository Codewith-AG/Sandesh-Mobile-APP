-- ============================================================
-- Sandesh Mobile App – Groups & Block-list Migration
-- Created: 2026-06-01
-- ============================================================
-- This migration creates four new tables:
--   1. blocked_users   – tracks user-level blocks
--   2. groups           – group chat metadata
--   3. group_members    – membership + roles for each group
--   4. group_messages   – individual messages within a group
--
-- Row-Level Security (RLS) is enabled on every table with
-- policies that resolve the current user's username via:
--   (SELECT username FROM profiles WHERE id = auth.uid())
-- ============================================================

-- ----------------------------------------------------------
-- Helper: reusable sub-select for the authenticated username
-- (referenced inside every policy below)
-- ----------------------------------------------------------
-- Usage inside policies:
--   (SELECT username FROM profiles WHERE id = auth.uid())

-- ==========================================================
-- 1. blocked_users
-- ==========================================================
CREATE TABLE IF NOT EXISTS blocked_users (
  blocker_username TEXT NOT NULL,
  blocked_username TEXT NOT NULL,
  created_at       TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (blocker_username, blocked_username)
);

-- Enable RLS
ALTER TABLE blocked_users ENABLE ROW LEVEL SECURITY;

-- Policy: users can see their own blocks (rows where they are the blocker)
CREATE POLICY "Users can view their own blocks"
  ON blocked_users FOR SELECT
  USING (
    blocker_username = (SELECT username FROM profiles WHERE id = auth.uid())
  );

-- Policy: users can insert a block only for themselves
CREATE POLICY "Users can block others"
  ON blocked_users FOR INSERT
  WITH CHECK (
    blocker_username = (SELECT username FROM profiles WHERE id = auth.uid())
  );

-- Policy: users can remove their own blocks
CREATE POLICY "Users can unblock others"
  ON blocked_users FOR DELETE
  USING (
    blocker_username = (SELECT username FROM profiles WHERE id = auth.uid())
  );

-- ==========================================================
-- 2. groups
-- ==========================================================
CREATE TABLE IF NOT EXISTS groups (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  description TEXT DEFAULT '',
  avatar_url  TEXT DEFAULT '',
  created_by  TEXT NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT now()
);

-- Enable RLS
ALTER TABLE groups ENABLE ROW LEVEL SECURITY;

-- Policy: authenticated users can read groups they belong to
CREATE POLICY "Members can view their groups"
  ON groups FOR SELECT
  USING (
    id IN (
      SELECT group_id FROM group_members
      WHERE username = (SELECT username FROM profiles WHERE id = auth.uid())
    )
  );

-- Policy: any authenticated user can create a group (they must be the creator)
CREATE POLICY "Authenticated users can create groups"
  ON groups FOR INSERT
  WITH CHECK (
    created_by = (SELECT username FROM profiles WHERE id = auth.uid())
  );

-- Policy: only the group creator can update group metadata
CREATE POLICY "Creator can update group"
  ON groups FOR UPDATE
  USING (
    created_by = (SELECT username FROM profiles WHERE id = auth.uid())
  )
  WITH CHECK (
    created_by = (SELECT username FROM profiles WHERE id = auth.uid())
  );

-- ==========================================================
-- 3. group_members
-- ==========================================================
CREATE TABLE IF NOT EXISTS group_members (
  group_id  UUID REFERENCES groups(id) ON DELETE CASCADE,
  username  TEXT NOT NULL,
  role      TEXT NOT NULL DEFAULT 'member',   -- 'admin' | 'member'
  joined_at TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (group_id, username)
);

-- Enable RLS
ALTER TABLE group_members ENABLE ROW LEVEL SECURITY;

-- Policy: users can see members of groups they themselves belong to
CREATE POLICY "Members can view fellow members"
  ON group_members FOR SELECT
  USING (
    group_id IN (
      SELECT group_id FROM group_members
      WHERE username = (SELECT username FROM profiles WHERE id = auth.uid())
    )
  );

-- Policy: group admins can add new members
CREATE POLICY "Admins can add members"
  ON group_members FOR INSERT
  WITH CHECK (
    -- The inserting user must be an admin of the target group,
    -- OR the user is adding themselves (creator bootstrapping).
    group_id IN (
      SELECT group_id FROM group_members
      WHERE username = (SELECT username FROM profiles WHERE id = auth.uid())
        AND role = 'admin'
    )
    OR username = (SELECT username FROM profiles WHERE id = auth.uid())
  );

-- Policy: group admins can remove members (or a user can remove themselves)
CREATE POLICY "Admins can remove members"
  ON group_members FOR DELETE
  USING (
    -- Admin of the group
    group_id IN (
      SELECT group_id FROM group_members
      WHERE username = (SELECT username FROM profiles WHERE id = auth.uid())
        AND role = 'admin'
    )
    -- OR the user is removing themselves (leaving the group)
    OR username = (SELECT username FROM profiles WHERE id = auth.uid())
  );

-- ==========================================================
-- 4. group_messages
-- ==========================================================
CREATE TABLE IF NOT EXISTS group_messages (
  id              TEXT PRIMARY KEY,
  group_id        UUID REFERENCES groups(id) ON DELETE CASCADE,
  sender_username TEXT NOT NULL,
  text            TEXT,
  media_url       TEXT,
  file_name       TEXT,
  message_type    TEXT NOT NULL DEFAULT 'text',  -- 'text' | 'image' | 'file'
  timestamp       BIGINT NOT NULL
);

-- Indexes for efficient queries
CREATE INDEX IF NOT EXISTS idx_grpmsg_group ON group_messages(group_id);
CREATE INDEX IF NOT EXISTS idx_grpmsg_ts    ON group_messages(timestamp);

-- Enable RLS
ALTER TABLE group_messages ENABLE ROW LEVEL SECURITY;

-- Policy: members of a group can read its messages
CREATE POLICY "Members can read group messages"
  ON group_messages FOR SELECT
  USING (
    group_id IN (
      SELECT group_id FROM group_members
      WHERE username = (SELECT username FROM profiles WHERE id = auth.uid())
    )
  );

-- Policy: members of a group can send messages (sender must be themselves)
CREATE POLICY "Members can send group messages"
  ON group_messages FOR INSERT
  WITH CHECK (
    sender_username = (SELECT username FROM profiles WHERE id = auth.uid())
    AND group_id IN (
      SELECT group_id FROM group_members
      WHERE username = (SELECT username FROM profiles WHERE id = auth.uid())
    )
  );

-- ==========================================================
-- 5. Enable Supabase Realtime for group_messages
-- ==========================================================
-- This lets Flutter clients subscribe to INSERT events on group_messages
-- so new messages appear instantly for all group members.
ALTER PUBLICATION supabase_realtime ADD TABLE group_messages;

-- ============================================================
-- Done! Tables, indexes, RLS policies, and Realtime are ready.
-- ============================================================
