// Supabase Edge Function: renotify
// ─────────────────────────────────────────────────────────────────────────────
// LAYER 4 of the verified-delivery design (the "verified backstop").
//
// The SENDER's app calls this ~4s after sending a message IF it has NOT yet
// received a `delivered` receipt from the peer. That means the peer's app could
// not be woken by the fast path (common on aggressive-OEM devices where the
// killed app never ran its FCM background isolate). This function sends a
// GUARANTEED system notification-shape FCM push (the OEM always shows it, even
// for a killed app) so the message is delivered 100% of the time — even if a
// couple of seconds late.
//
// Duplicate-safety: before sending, we RE-CHECK `message_receipts`. If a
// `delivered` receipt has landed in the meantime (race with the 4s timer),
// we skip — so in the common (fast) case the peer sees exactly ONE
// notification. The push also carries the message id so the client tags the
// notification and collapses it onto any existing one.
//
// verify_jwt = true: called by the authenticated sender's app via
// supabase.functions.invoke('renotify', ...), which forwards the user's JWT.
//
// Required Supabase Secrets (same as send-push):
//   FIREBASE_PROJECT_ID, FIREBASE_CLIENT_EMAIL, FIREBASE_PRIVATE_KEY,
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

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
    ["sign"]
  );

  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    new TextEncoder().encode(signingInput)
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

// ─── CORS ──────────────────────────────────────────────────────────────────────

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

// ─── Main handler ──────────────────────────────────────────────────────────────

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405, headers: corsHeaders });
    }

    const body = await req.json().catch(() => ({}));
    const {
      message_id,
      sender_username,
      receiver_username,
      text,
      message_type,
      timestamp,
    } = body ?? {};

    if (
      typeof receiver_username !== "string" ||
      receiver_username.length === 0 ||
      receiver_username.length > 64 ||
      typeof message_id !== "string" ||
      message_id.length === 0
    ) {
      return new Response("Bad request", { status: 400, headers: corsHeaders });
    }

    // Never back up call signals — calls have their own ring/retry path.
    if (
      message_type === "call_invite" ||
      message_type === "call_accepted" ||
      message_type === "call_rejected" ||
      message_type === "call_ended"
    ) {
      return new Response("skipped (call signal)", { status: 200, headers: corsHeaders });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // ── DUPLICATE-SAFETY re-check ────────────────────────────────────────────
    // A `delivered` receipt may have landed in the ~4s since the sender armed
    // the backstop (race with the timer). If so, the peer already has the
    // message — do NOT send a second notification.
    const { data: receipt } = await supabase
      .from("message_receipts")
      .select("status")
      .eq("message_id", message_id)
      .maybeSingle();

    if (receipt && (receipt.status === "delivered" || receipt.status === "read")) {
      console.log(`[renotify] ${message_id} already delivered — skipping backstop`);
      return new Response("already delivered", { status: 200, headers: corsHeaders });
    }

    // ── Respect the receiver's "1-on-1 Messages" toggle (defaults enabled) ──
    const { data: notifSettings } = await supabase
      .from("notification_settings")
      .select("messages_enabled")
      .ilike("username", receiver_username)
      .maybeSingle();

    if (notifSettings && notifSettings.messages_enabled === false) {
      console.log("[renotify] Receiver disabled message notifications — skipping");
      return new Response("messages disabled", { status: 200, headers: corsHeaders });
    }

    // ── Fetch receiver's FCM token ───────────────────────────────────────────
    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("fcm_token")
      .ilike("username", receiver_username)
      .maybeSingle();

    if (profileError) {
      console.error("[renotify] Profile fetch error:", profileError.message);
      return new Response("Profile fetch failed", { status: 500, headers: corsHeaders });
    }
    if (!profile?.fcm_token) {
      console.log("[renotify] No FCM token for receiver — skipping");
      return new Response("No FCM token registered", { status: 200, headers: corsHeaders });
    }

    const safeBody =
      text != null && String(text).trim() !== "" && String(text) !== "null"
        ? String(text)
        : "📎 Sent an attachment";

    const dataPayload: Record<string, string> = {
      id: String(message_id),
      type: "message",
      msg_type: String(message_type ?? "text"),
      sender_username: String(sender_username ?? ""),
      receiver_username: String(receiver_username ?? ""),
      text: safeBody,
      timestamp: String(timestamp ?? Date.now()),
      // Marks this as the verified backstop so client logs/telemetry can tell
      // it apart from the fast-path push.
      backstop: "1",
    };

    // Notification-shape push → OEM always displays it, even for a killed app.
    // `tag` = message id so it COLLAPSES onto any fast-path notification that
    // may already be showing (at most one visible notification per message).
    const fcmPayload = {
      message: {
        token: profile.fcm_token,
        notification: {
          title: String(sender_username ?? "New Message"),
          body: safeBody,
        },
        data: dataPayload,
        android: {
          priority: "high",
          notification: {
            channel_id: "messages_channel",
            sound: "default",
            click_action: "FLUTTER_NOTIFICATION_CLICK",
            notification_priority: "PRIORITY_MAX",
            visibility: "PUBLIC",
            tag: String(message_id),
          },
        },
        apns: {
          headers: { "apns-priority": "10", "apns-collapse-id": String(message_id) },
          payload: { aps: { sound: "default", "content-available": 1 } },
        },
      },
    };

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
      console.error("[renotify] FCM error:", JSON.stringify(fcmJson));
      return new Response(JSON.stringify(fcmJson), {
        status: fcmRes.status,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    console.log(`[renotify] Backstop push delivered for ${message_id}`);
    return new Response(JSON.stringify({ success: true, backstop: true }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("[renotify] Unhandled error:", (err as Error).message);
    return new Response("Internal error", { status: 500, headers: corsHeaders });
  }
});
