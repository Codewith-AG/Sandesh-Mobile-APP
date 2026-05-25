// Supabase Edge Function — agora-token/index.ts
// Deploy with: supabase functions deploy agora-token
// Environment secrets required:
//   AGORA_APP_ID
//   AGORA_APP_CERTIFICATE
//   SUPABASE_URL          (auto-injected)
//   SUPABASE_ANON_KEY     (auto-injected)
//
// Security model:
//   * The caller MUST send a valid Supabase JWT in `Authorization: Bearer …`.
//   * The user's profile.username is fetched from auth.uid().
//   * channelName must match `call_<a>_<b>` and contain the user's username.
//   * uid is derived deterministically from auth.uid() so a token cannot be
//     replayed under another user's identity inside the same channel.
//   * Token expires in 10 minutes.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { RtcTokenBuilder, RtcRole } from "npm:agora-token@2.0.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    // ── 1. Verify Supabase JWT ─────────────────────────────────────────────
    const authHeader = req.headers.get("Authorization") ?? "";
    if (!authHeader.startsWith("Bearer ")) {
      return json({ error: "Unauthorized" }, 401);
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const {
      data: { user },
      error: userErr,
    } = await supabase.auth.getUser();
    if (userErr || !user) return json({ error: "Unauthorized" }, 401);

    // ── 2. Look up the caller's username from profiles ─────────────────────
    const { data: profile, error: profErr } = await supabase
      .from("profiles")
      .select("username")
      .eq("id", user.id)
      .maybeSingle();
    if (profErr || !profile?.username) {
      return json({ error: "Profile not found" }, 403);
    }
    const myUsername = String(profile.username).toLowerCase();

    // ── 3. Validate channelName ────────────────────────────────────────────
    const body = await req.json().catch(() => ({}));
    const channelName: unknown = body.channelName;
    if (typeof channelName !== "string" || channelName.length > 80) {
      return json({ error: "channelName required" }, 400);
    }

    // Format: call_<a>_<b> where a < b alphabetically (matches Flutter helper)
    const match = /^call_([a-z0-9._-]+)_([a-z0-9._-]+)$/i.exec(channelName);
    if (!match) return json({ error: "Invalid channelName" }, 400);
    const a = match[1].toLowerCase();
    const b = match[2].toLowerCase();
    if (myUsername !== a && myUsername !== b) {
      return json({ error: "Forbidden" }, 403);
    }

    // ── 4. Derive a per-user uid from the Supabase user id ─────────────────
    // Agora uids are uint32. We hash auth.uid() (uuid) and take the first 4 bytes.
    const hashBuf = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(user.id),
    );
    const h = new Uint8Array(hashBuf);
    let uid = ((h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3]) >>> 0;
    if (uid === 0) uid = 1; // 0 means "auto-assign" in Agora — avoid

    // ── 5. Build the Agora token (10 minute expiry) ────────────────────────
    const appId = Deno.env.get("AGORA_APP_ID");
    const appCert = Deno.env.get("AGORA_APP_CERTIFICATE");
    if (!appId || !appCert) {
      return json({ error: "Agora credentials not configured" }, 500);
    }

    const expiry = Math.floor(Date.now() / 1000) + 600;
    const token = RtcTokenBuilder.buildTokenWithUid(
      appId,
      appCert,
      channelName,
      uid,
      RtcRole.PUBLISHER,
      expiry,
      expiry,
    );

    return json({ token, uid, appId, expiresAt: expiry }, 200);
  } catch (e) {
    // Never echo `e` directly — could include stack with secret refs
    console.error("[agora-token] error:", (e as Error).message);
    return json({ error: "Internal error" }, 500);
  }
});
