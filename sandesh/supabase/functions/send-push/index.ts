// Supabase Edge Function: send-push
// Triggered by a Database Webhook on AFTER INSERT on the `messages` table.
// Fetches the receiver's FCM token from `profiles`, then sends a FCM HTTP v1 push.
//
// Required Supabase Secrets (set via Supabase Dashboard → Edge Functions → Secrets):
//   FIREBASE_PROJECT_ID        = sandesh-app-544c7
//   FIREBASE_CLIENT_EMAIL      = firebase-adminsdk-fbsvc@sandesh-app-544c7.iam.gserviceaccount.com
//   FIREBASE_PRIVATE_KEY       = -----BEGIN PRIVATE KEY-----\n...full key...\n-----END PRIVATE KEY-----\n

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ─── Base64url helper (RFC 4648 §5) ───────────────────────────────────────────

/** Correctly encodes a Uint8Array as base64url with no padding. */
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

/** Encodes a plain JS object as a base64url JSON segment (for JWT headers/claims). */
function encodeJwtPart(obj: object): string {
  return base64url(new TextEncoder().encode(JSON.stringify(obj)));
}

// ─── Google OAuth2 JWT helper ──────────────────────────────────────────────────

async function getGoogleAccessToken(): Promise<string> {
  const clientEmail = Deno.env.get("FIREBASE_CLIENT_EMAIL")!;
  // Supabase secrets preserve literal \n — replace them with real newlines
  const privateKeyRaw = Deno.env.get("FIREBASE_PRIVATE_KEY")!.replace(/\\n/g, "\n");

  const now = Math.floor(Date.now() / 1000);

  // Build JWT header + claim using correct base64url encoding
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

  const binaryKey = Uint8Array.from(atob(keyData), (c) => c.charCodeAt(0));

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
    throw new Error(`Failed to get Google access token: ${JSON.stringify(tokenJson)}`);
  }
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

// ─── Main handler ──────────────────────────────────────────────────────────────

// Constant-time string comparison so a network attacker cannot brute-force the
// webhook secret by timing the response.
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

serve(async (req) => {
  try {
    // ── 1. POST-only ─────────────────────────────────────────────────────
    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    // ── 2. Webhook secret check ──────────────────────────────────────────
    // The Supabase Database Webhook must be configured to send the header
    //   x-webhook-secret: <value of SEND_PUSH_WEBHOOK_SECRET>
    // This prevents arbitrary callers from triggering pushes (spam, abuse).
    const expectedSecret = Deno.env.get("SEND_PUSH_WEBHOOK_SECRET");
    const providedSecret = req.headers.get("x-webhook-secret") ?? "";
    if (!expectedSecret || !safeEqual(providedSecret, expectedSecret)) {
      console.warn("[send-push] Unauthorized webhook call");
      return new Response("Unauthorized", { status: 401 });
    }

    // ── 3. Parse + validate payload ──────────────────────────────────────
    const payload = await req.json().catch(() => ({}));
    const record = payload.record ?? payload;
    const {
      id,
      sender_username,
      receiver_username,
      text,
      timestamp,
      message_type,
    } = record ?? {};

    // Schema validation — only known fields, basic type checks.
    if (
      typeof receiver_username !== "string" ||
      receiver_username.length === 0 ||
      receiver_username.length > 64
    ) {
      return new Response("Bad request", { status: 400 });
    }
    if (
      sender_username !== undefined &&
      (typeof sender_username !== "string" || sender_username.length > 64)
    ) {
      return new Response("Bad request", { status: 400 });
    }
    if (
      message_type !== undefined &&
      typeof message_type !== "string"
    ) {
      return new Response("Bad request", { status: 400 });
    }

    // Sanitized log: never echo message body or FCM tokens.
    console.log(
      `[send-push] type=${message_type ?? "text"} id=${id ?? "?"} to=${receiver_username}`,
    );

    // Skip intermediate call signals — only the invite needs a push.
    // Accepted / rejected / ended are delivered via Supabase Realtime when the
    // peer's app is in the foreground (which is the only state in which the
    // UI cares about them anyway).
    if (
      message_type === "call_accepted" ||
      message_type === "call_rejected" ||
      message_type === "call_ended"
    ) {
      console.log(`[send-push] Skipping FCM for ${message_type}`);
      return new Response("skipped", { status: 200 });
    }

    // Connect to Supabase using service-role key (available automatically in Edge Functions)
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Fetch the receiver's FCM token from profiles
    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("fcm_token")
      .eq("username", receiver_username)
      .maybeSingle();

    if (profileError) {
      console.error("[send-push] Profile fetch error:", profileError.message);
      return new Response("Profile fetch failed", { status: 500 });
    }

    if (!profile?.fcm_token) {
      console.log(`[send-push] No FCM token registered for receiver — skipping`);
      return new Response("No FCM token registered", { status: 200 });
    }

    // ── Build notification + data payload based on the message type ─────────
    const isCallInvite = message_type === "call_invite";

    let notificationTitle: string;
    let notificationBody: string;
    let dataPayload: Record<string, string>;

    if (isCallInvite) {
      // text holds JSON: {"channelName":"call_a_b","callType":"audio|video"}
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
      // Normal chat message — text/image/video/document
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

    // Build the FCM HTTP v1 payload
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
          priority: "high",
          notification: {
            channel_id: "messages_channel",
            sound: "default",
            click_action: "FLUTTER_NOTIFICATION_CLICK",
            notification_priority: "PRIORITY_MAX",
            visibility: "PUBLIC",
            // Call invites are sticky / ongoing so the user sees them while ringing
            ...(isCallInvite ? { tag: dataPayload.channelName } : {}),
          },
        },

        // APNs (iOS) — harmless placeholder for future use
        apns: {
          headers: { "apns-priority": "10" },
          payload: { aps: { sound: "default", "content-available": 1 } },
        },
      },
    };

    // Send to FCM HTTP v1 API
    const projectId = Deno.env.get("FIREBASE_PROJECT_ID")!;
    const accessToken = await getGoogleAccessToken();
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
      console.error("[send-push] FCM error:", JSON.stringify(fcmJson));
      return new Response(JSON.stringify(fcmJson), { status: fcmRes.status });
    }

    console.log(`[send-push] FCM delivered`);
    return new Response(JSON.stringify({ success: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    // Never include the raw error body in the response — it could leak
    // service-role usage or secret fragments via stack traces.
    console.error("[send-push] Unhandled error:", (err as Error).message);
    return new Response("Internal error", { status: 500 });
  }
});
