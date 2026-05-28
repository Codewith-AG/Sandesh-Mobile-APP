// Supabase Edge Function — agora-token/index.ts
// Deploy with: supabase functions deploy agora-token
// Environment secrets required:
//   AGORA_APP_ID
//   AGORA_APP_CERTIFICATE
//   SUPABASE_URL       (auto-injected by Supabase)
//   SUPABASE_ANON_KEY  (auto-injected by Supabase)

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

Deno.serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    // ── 1. Verify Supabase JWT ────────────────────────────────────────────────
    const authHeader = req.headers.get("Authorization") ?? "";
    console.log("[agora-token] auth header present:", authHeader.startsWith("Bearer "));
    if (!authHeader.startsWith("Bearer ")) {
      return json({ error: "Unauthorized: missing Bearer token" }, 401);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
    console.log("[agora-token] SUPABASE_URL present:", !!supabaseUrl);

    const supabase = createClient(
      supabaseUrl!,
      supabaseAnonKey!,
      { global: { headers: { Authorization: authHeader } } },
    );

    const { data: { user }, error: userErr } = await supabase.auth.getUser();
    console.log("[agora-token] auth user:", user?.id ?? "null", "err:", userErr?.message ?? "none");
    if (userErr || !user) {
      return json({ error: "Unauthorized: invalid JWT" }, 401);
    }

    // ── 2. Look up username from profiles ────────────────────────────────────
    const { data: profile, error: profErr } = await supabase
      .from("profiles")
      .select("username")
      .eq("id", user.id)
      .maybeSingle();
    console.log("[agora-token] profile:", profile?.username ?? "null", "err:", profErr?.message ?? "none");
    if (profErr || !profile?.username) {
      return json({ error: "Profile not found for this user" }, 403);
    }

    // Strip spaces & special chars — same logic as Flutter's _makeChannelName
    // e.g. "Sandesh Sharma" → "sandeshsharma"
    const myUsername = String(profile.username).toLowerCase().replace(/[^a-z0-9]/g, "");
    console.log("[agora-token] sanitized username:", myUsername);

    // ── 3. Validate channelName ───────────────────────────────────────────────
    const body = await req.json().catch(() => ({}));
    const channelName: unknown = body.channelName;
    console.log("[agora-token] channelName:", channelName);

    if (typeof channelName !== "string" || channelName.length > 80) {
      return json({ error: "channelName is required and must be under 80 chars" }, 400);
    }

    // Format: call_<a>_<b> where a < b alphabetically
    const match = /^call_([a-z0-9]+)_([a-z0-9]+)$/i.exec(channelName);
    console.log("[agora-token] channel regex match:", match ? "OK" : "FAILED");
    if (!match) {
      return json({ error: `Invalid channelName format: "${channelName}". Expected: call_<user1>_<user2>` }, 400);
    }

    const a = match[1].toLowerCase();
    const b = match[2].toLowerCase();
    console.log("[agora-token] channel parts:", a, b, "| my username:", myUsername);

    if (myUsername !== a && myUsername !== b) {
      return json({ error: `Forbidden: "${myUsername}" not in channel "${channelName}"` }, 403);
    }

    // ── 4. Agora credentials check ───────────────────────────────────────────
    const appId = Deno.env.get("AGORA_APP_ID");
    const appCert = Deno.env.get("AGORA_APP_CERTIFICATE");
    console.log("[agora-token] AGORA_APP_ID present:", !!appId, "AGORA_APP_CERTIFICATE present:", !!appCert);
    if (!appId || !appCert) {
      return json({ error: "Agora credentials not configured on server" }, 500);
    }

    // ── 5. Derive per-user Agora uid from auth UUID ──────────────────────────
    const hashBuf = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(user.id),
    );
    const h = new Uint8Array(hashBuf);
    let uid = ((h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3]) >>> 0;
    if (uid === 0) uid = 1;
    console.log("[agora-token] derived uid:", uid);

    // ── 6. Build Agora RTC token (10 min expiry) ─────────────────────────────
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
    console.log("[agora-token] token built successfully, length:", token?.length ?? 0);

    return json({ token, uid, appId, expiresAt: expiry }, 200);

  } catch (e) {
    console.error("[agora-token] unexpected error:", (e as Error).message, (e as Error).stack);
    return json({ error: `Internal error: ${(e as Error).message}` }, 500);
  }
});
