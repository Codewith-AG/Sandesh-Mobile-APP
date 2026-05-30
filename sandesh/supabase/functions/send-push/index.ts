// Supabase Edge Function: send-push
// Triggered by a Database Webhook on AFTER INSERT on the `messages` table.
// Fetches the receiver's FCM token from `profiles`, then sends a FCM HTTP v1 push.
//
// Required Supabase Secrets (set via Supabase Dashboard → Edge Functions → Secrets):
//   FIREBASE_PROJECT_ID        = sandesh-app-544c7
//   FIREBASE_CLIENT_EMAIL      = firebase-adminsdk-fbsvc@sandesh-app-544c7.iam.gserviceaccount.com
//   FIREBASE_PRIVATE_KEY       = -----BEGIN PRIVATE KEY-----\n...full key...\n-----END PRIVATE KEY-----\n
//   SEND_PUSH_WEBHOOK_SECRET   = <your webhook secret>

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ─── Base64url helper (RFC 4648 §5) ───────────────────────────────────────────

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function encodeJwtPart(obj: object): string {
  return base64url(new TextEncoder().encode(JSON.stringify(obj)));
}

// ─── Google OAuth2 JWT helper ──────────────────────────────────────────────────

async function getGoogleAccessToken(): Promise<string> {
  const clientEmail = Deno.env.get("FIREBASE_CLIENT_EMAIL");
  const privateKeyEnv = Deno.env.get("FIREBASE_PRIVATE_KEY");

  if (!clientEmail) throw new Error("FIREBASE_CLIENT_EMAIL secret is not set");
  if (!privateKeyEnv) throw new Error("FIREBASE_PRIVATE_KEY secret is not set");

  console.log(`[send-push] clientEmail=${clientEmail}`);
  console.log(`[send-push] privateKey length=${privateKeyEnv.length}, starts with: ${privateKeyEnv.substring(0, 30)}...`);

  // ── CRITICAL FIX: Handle ALL possible newline escaping scenarios ──
  // Depending on how the secret was pasted into Supabase Dashboard:
  //   - It might contain literal two-char sequences: \n  (backslash + n)
  //   - It might contain double-escaped: \\n  (backslash + backslash + n)
  //   - It might already have real newlines
  // We handle all three by replacing double-escaped first, then single-escaped.
  const privateKeyRaw = privateKeyEnv
    .replace(/\\\\n/g, "\n")   // \\n → real newline (double-escaped case)
    .replace(/\\n/g, "\n");     // \n → real newline (single-escaped case — MOST COMMON)

  console.log(`[send-push] privateKey after unescape: contains real newlines=${privateKeyRaw.includes("\n")}, length=${privateKeyRaw.length}`);

  const now = Math.floor(Date.now() / 1000);

  const signingInput = `${encodeJwtPart({ alg: "RS256", typ: "JWT" })}.${encodeJwtPart({
    iss: clientEmail,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  })}`;

  // Import the RSA private key for signing
  const keyData = privateKeyRaw
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");

  console.log(`[send-push] base64 key data length=${keyData.length}`);

  let binaryKey: Uint8Array;
  try {
    binaryKey = Uint8Array.from(atob(keyData), (c) => c.charCodeAt(0));
  } catch (e) {
    throw new Error(`Failed to decode private key base64: ${(e as Error).message}. Key data (first 20 chars): ${keyData.substring(0, 20)}`);
  }

  console.log(`[send-push] binary key size=${binaryKey.length} bytes`);

  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    binaryKey.buffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    new TextEncoder().encode(signingInput)
  );

  const jwt = `${signingInput}.${base64url(new Uint8Array(signature))}`;
  console.log(`[send-push] JWT created successfully, length=${jwt.length}`);

  // Exchange JWT for a short-lived Google OAuth2 access token
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
    throw new Error(`Google token exchange failed (status=${tokenRes.status}): ${JSON.stringify(tokenJson)}`);
  }
  console.log("[send-push] Google access token obtained successfully");
  return tokenJson.access_token;
}

// ─── Helpers ───────────────────────────────────────────────────────────────────

function safeJsonParse(s: unknown): Record<string, unknown> {
  if (typeof s !== "string" || s.trim() === "") return {};
  try {
    return JSON.parse(s);
  } catch {
    return {};
  }
}

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// ─── Main handler ──────────────────────────────────────────────────────────────

serve(async (req) => {
  try {
    console.log("[send-push] ═══ Function invoked ═══");

    // ── 1. POST-only ─────────────────────────────────────────────────────
    if (req.method !== "POST") {
      console.log(`[send-push] Rejected: method=${req.method}`);
      return new Response("Method not allowed", { status: 405 });
    }

    // ── 2. Webhook secret check ──────────────────────────────────────────
    const expectedSecret = Deno.env.get("SEND_PUSH_WEBHOOK_SECRET");
    const providedSecret = req.headers.get("x-webhook-secret") ?? "";

    if (!expectedSecret) {
      console.warn("[send-push] SEND_PUSH_WEBHOOK_SECRET is NOT set — skipping auth check");
    } else if (!safeEqual(providedSecret, expectedSecret)) {
      console.warn("[send-push] ❌ Unauthorized — webhook secret mismatch");
      return new Response("Unauthorized", { status: 401 });
    } else {
      console.log("[send-push] ✓ Webhook secret verified");
    }

    // ── 3. Parse + validate payload ──────────────────────────────────────
    const payload = await req.json().catch(() => ({}));
    const record = payload.record ?? payload;
    console.log(`[send-push] Payload keys: ${JSON.stringify(Object.keys(record ?? {}))}`);

    const {
      id,
      sender_username,
      receiver_username,
      text,
      timestamp,
      message_type,
    } = record ?? {};

    console.log(`[send-push] sender=${sender_username} receiver=${receiver_username} type=${message_type ?? "text"} id=${id ?? "?"}`);

    if (
      typeof receiver_username !== "string" ||
      receiver_username.length === 0 ||
      receiver_username.length > 64
    ) {
      console.error(`[send-push] ❌ Bad request: invalid receiver_username="${receiver_username}"`);
      return new Response("Bad request", { status: 400 });
    }

    // Skip intermediate call signals
    if (
      message_type === "call_accepted" ||
      message_type === "call_rejected" ||
      message_type === "call_ended"
    ) {
      console.log(`[send-push] Skipping FCM for ${message_type}`);
      return new Response("skipped", { status: 200 });
    }

    // ── 4. Lookup receiver's FCM token ───────────────────────────────────
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("fcm_token, username")
      .eq("username", receiver_username)
      .maybeSingle();

    if (profileError) {
      console.error(`[send-push] ❌ Profile query error: ${profileError.message}`);
      return new Response("Profile fetch failed", { status: 500 });
    }

    if (!profile) {
      console.error(`[send-push] ❌ No profile found for username="${receiver_username}"`);
      return new Response("No profile found", { status: 200 });
    }

    if (!profile.fcm_token) {
      console.error(`[send-push] ❌ Profile found but fcm_token is NULL for username="${receiver_username}"`);
      return new Response("No FCM token registered", { status: 200 });
    }

    console.log(`[send-push] ✓ FCM token found for "${receiver_username}" (token starts: ${profile.fcm_token.substring(0, 20)}...)`);

    // ── 5. Build notification payload ────────────────────────────────────
    const isCallInvite = message_type === "call_invite";

    let notificationTitle: string;
    let notificationBody: string;
    let dataPayload: Record<string, string>;

    if (isCallInvite) {
      const signal = safeJsonParse(text);
      const callType = String(signal.callType ?? "audio");
      const channelName = String(signal.channelName ?? "");

      notificationTitle = `Incoming ${callType} call`;
      notificationBody = `${sender_username} is calling…`;
      dataPayload = {
        id: String(id ?? ""),
        type: "call",
        msg_type: "call_invite",
        callerUsername: String(sender_username ?? ""),
        receiverUsername: String(receiver_username ?? ""),
        sender_username: String(sender_username ?? ""),
        receiver_username: String(receiver_username ?? ""),
        callType,
        channelName,
        timestamp: String(timestamp ?? Date.now()),
      };
    } else {
      const safeBody =
        text != null && String(text).trim() !== "" && String(text) !== "null"
          ? String(text)
          : "📎 Sent an attachment";

      notificationTitle = String(sender_username ?? "New Message");
      notificationBody = safeBody;
      dataPayload = {
        id: String(id ?? ""),
        type: "message",
        msg_type: String(message_type ?? "text"),
        sender_username: String(sender_username ?? ""),
        receiver_username: String(receiver_username ?? ""),
        text: safeBody,
        timestamp: String(timestamp ?? Date.now()),
      };
    }

    console.log(`[send-push] Notification: title="${notificationTitle}" body="${notificationBody}"`);

    // ── 6. Get Google access token and send FCM ──────────────────────────
    const projectId = Deno.env.get("FIREBASE_PROJECT_ID");
    if (!projectId) {
      console.error("[send-push] ❌ FIREBASE_PROJECT_ID secret is not set");
      return new Response("Missing project ID", { status: 500 });
    }

    console.log(`[send-push] Getting Google access token for project=${projectId}...`);
    const accessToken = await getGoogleAccessToken();

    const fcmPayload = {
      message: {
        token: profile.fcm_token,

        // Visible system notification (shown even when app is killed/background)
        notification: {
          title: notificationTitle,
          body: notificationBody,
        },

        // Data payload — processed by Flutter onMessage* handlers
        data: dataPayload,

        // Android: high priority wakes the device even when terminated
        android: {
          priority: "high" as const,
          notification: {
            channel_id: "messages_channel",
            sound: "default",
            click_action: "FLUTTER_NOTIFICATION_CLICK",
            notification_priority: "PRIORITY_MAX" as const,
            visibility: "PUBLIC" as const,
            ...(isCallInvite ? { tag: dataPayload.channelName } : {}),
          },
        },

        // APNs (iOS)
        apns: {
          headers: { "apns-priority": "10" },
          payload: { aps: { sound: "default", "content-available": 1 } },
        },
      },
    };

    console.log(`[send-push] Sending FCM request to project=${projectId}...`);

    const fcmRes = await fetch(
      `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
      {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(fcmPayload),
      }
    );

    const fcmJson = await fcmRes.json();

    if (!fcmRes.ok) {
      console.error(`[send-push] ❌ FCM API error (status=${fcmRes.status}): ${JSON.stringify(fcmJson)}`);
      return new Response(JSON.stringify(fcmJson), { status: fcmRes.status });
    }

    console.log(`[send-push] ✅ FCM delivered successfully! Response: ${JSON.stringify(fcmJson)}`);
    return new Response(JSON.stringify({ success: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error(`[send-push] ❌ UNHANDLED ERROR: ${(err as Error).message}`);
    console.error(`[send-push] Stack: ${(err as Error).stack}`);
    return new Response("Internal error", { status: 500 });
  }
});
