// Supabase Edge Function: send-group-push
// Called by the client (authenticated) right after a group message is inserted.
// Fans out an FCM HTTP v1 push to every OTHER member of the group, skipping any
// member whose notification_settings.groups_enabled is false.
//
// Required Supabase Secrets (same ones send-push already uses):
//   FIREBASE_PROJECT_ID
//   FIREBASE_CLIENT_EMAIL
//   FIREBASE_PRIVATE_KEY
//   SUPABASE_URL              (auto-injected)
//   SUPABASE_ANON_KEY         (auto-injected)
//   SUPABASE_SERVICE_ROLE_KEY

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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

// ─── base64url + Google OAuth2 access token (same approach as send-push) ──────
function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function encodeJwtPart(obj: object): string {
  return base64url(new TextEncoder().encode(JSON.stringify(obj)));
}
async function getGoogleAccessToken(): Promise<string> {
  const clientEmail = Deno.env.get("FIREBASE_CLIENT_EMAIL")!;
  const privateKeyRaw = Deno.env.get("FIREBASE_PRIVATE_KEY")!.replace(/\\n/g, "\n");
  const now = Math.floor(Date.now() / 1000);
  const signingInput = `${encodeJwtPart({ alg: "RS256", typ: "JWT" })}.${encodeJwtPart({
    iss: clientEmail,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  })}`;
  const keyData = privateKeyRaw
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  const binaryKey = Uint8Array.from(atob(keyData), (c) => c.charCodeAt(0));
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    binaryKey.buffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    new TextEncoder().encode(signingInput),
  );
  const jwt = `${signingInput}.${base64url(new Uint8Array(signature))}`;
  const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  const tokenJson = await tokenRes.json();
  if (!tokenJson.access_token) {
    throw new Error(`Failed to get Google access token: ${JSON.stringify(tokenJson)}`);
  }
  return tokenJson.access_token;
}

// ─── Main handler ─────────────────────────────────────────────────────────────
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // ── Verify the caller's JWT and resolve their username (anti-spoof) ──
    const authHeader = req.headers.get("Authorization") ?? "";
    if (!authHeader.startsWith("Bearer ")) return json({ error: "Unauthorized" }, 401);

    const authClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: userErr } = await authClient.auth.getUser();
    if (userErr || !user) return json({ error: "Unauthorized" }, 401);

    const body = await req.json().catch(() => ({})) as Record<string, string>;
    const groupId = body.group_id;
    const senderUsername = (body.sender_username ?? "").toLowerCase();
    const text = body.text ?? "";
    const messageType = body.message_type ?? "text";
    let groupName = body.group_name ?? "Group";

    if (!groupId || !senderUsername) {
      return json({ error: "group_id and sender_username are required" }, 400);
    }

    // Don't notify for system notices.
    if (messageType === "system") return json({ skipped: true, reason: "system" });

    // Confirm the caller really is the sender.
    const { data: callerProfile } = await authClient
      .from("profiles")
      .select("username")
      .eq("id", user.id)
      .maybeSingle();
    if ((callerProfile?.username ?? "").toLowerCase() !== senderUsername) {
      return json({ error: "Forbidden: sender mismatch" }, 403);
    }

    // ── Service-role client for the fan-out reads ──
    const svc = createClient(supabaseUrl, serviceKey);

    // Group name (fallback to provided value).
    const { data: grp } = await svc
      .from("groups")
      .select("name")
      .eq("id", groupId)
      .maybeSingle();
    if (grp?.name) groupName = grp.name;

    // Members except the sender.
    const { data: members } = await svc
      .from("group_members")
      .select("username")
      .eq("group_id", groupId);
    const recipients = (members ?? [])
      .map((m: { username: string }) => (m.username ?? "").toLowerCase())
      .filter((u: string) => u && u !== senderUsername);
    if (recipients.length === 0) return json({ skipped: true, reason: "no_recipients" });

    // Tokens + per-member group toggle.
    const { data: profs } = await svc
      .from("profiles")
      .select("username, fcm_token")
      .in("username", recipients);
    const { data: settings } = await svc
      .from("notification_settings")
      .select("username, groups_enabled")
      .in("username", recipients);

    const tokenByUser = new Map<string, string>();
    for (const p of (profs ?? [])) {
      if (p.fcm_token) tokenByUser.set((p.username ?? "").toLowerCase(), p.fcm_token);
    }
    const groupsDisabled = new Set<string>();
    for (const s of (settings ?? [])) {
      if (s.groups_enabled === false) groupsDisabled.add((s.username ?? "").toLowerCase());
    }

    const bodyText =
      text && text.trim() !== "" && text !== "null" ? text : "📎 Sent an attachment";
    const projectId = Deno.env.get("FIREBASE_PROJECT_ID")!;
    const accessToken = await getGoogleAccessToken();

    let sent = 0;
    let skipped = 0;
    for (const username of recipients) {
      if (groupsDisabled.has(username)) { skipped++; continue; }
      const token = tokenByUser.get(username);
      if (!token) { skipped++; continue; }

      const fcmPayload = {
        message: {
          token,
          notification: {
            title: groupName,
            body: `${senderUsername}: ${bodyText}`,
          },
          data: {
            type: "group_message",
            group_id: String(groupId),
            group_name: String(groupName),
            sender_username: senderUsername,
            msg_type: String(messageType),
            text: bodyText,
            timestamp: String(body.timestamp ?? Date.now()),
          },
          android: {
            priority: "high",
            notification: {
              channel_id: "messages_channel",
              sound: "default",
              click_action: "FLUTTER_NOTIFICATION_CLICK",
              notification_priority: "PRIORITY_MAX",
              visibility: "PUBLIC",
            },
          },
          apns: {
            headers: { "apns-priority": "10" },
            payload: { aps: { sound: "default", "content-available": 1 } },
          },
        },
      };

      const res = await fetch(
        `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${accessToken}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(fcmPayload),
        },
      );
      if (res.ok) sent++;
      else {
        skipped++;
        console.error("[send-group-push] FCM error:", JSON.stringify(await res.json()));
      }
    }

    console.log(`[send-group-push] group=${groupId} sent=${sent} skipped=${skipped}`);
    return json({ success: true, sent, skipped });
  } catch (e) {
    console.error("[send-group-push] Error:", (e as Error).message);
    return json({ error: `Internal error: ${(e as Error).message}` }, 500);
  }
});
