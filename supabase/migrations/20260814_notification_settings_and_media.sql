-- Migration for Notification Settings and Shared Media Queries
-- Created: 2026-08-14

-- 1. Create notification_settings table
CREATE TABLE IF NOT EXISTS public.notification_settings (
    username TEXT PRIMARY KEY,
    messages_enabled BOOLEAN DEFAULT true,
    groups_enabled BOOLEAN DEFAULT true,
    calls_enabled BOOLEAN DEFAULT true,
    sounds_enabled BOOLEAN DEFAULT true,
    vibrate_enabled BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Note: We assume profiles.username is UNIQUE, but we won't add foreign key unless it's strictly a UNIQUE constraint.
-- In typical Supabase setups, id is the primary key and username is just unique.

ALTER TABLE public.notification_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own settings"
ON public.notification_settings FOR SELECT
USING (username = (SELECT username FROM public.profiles WHERE id = auth.uid()));

CREATE POLICY "Users can insert their own settings"
ON public.notification_settings FOR INSERT
WITH CHECK (username = (SELECT username FROM public.profiles WHERE id = auth.uid()));

CREATE POLICY "Users can update their own settings"
ON public.notification_settings FOR UPDATE
USING (username = (SELECT username FROM public.profiles WHERE id = auth.uid()))
WITH CHECK (username = (SELECT username FROM public.profiles WHERE id = auth.uid()));

-- 2. Add an index to `messages` for fast shared media queries
CREATE INDEX IF NOT EXISTS idx_messages_media 
ON public.messages(message_type, sender_username, receiver_username);
