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

// ─── Google OAuth2 JWT helper ──────────────────────────────────────────────────

async function getGoogleAccessToken(): Promise<string> {
  const projectId = Deno.env.get("FIREBASE_PROJECT_ID")!;
  const clientEmail = Deno.env.get("FIREBASE_CLIENT_EMAIL")!;
  // Supabase secrets preserve literal \n — replace them with real newlines
  const privateKeyRaw = Deno.env.get("FIREBASE_PRIVATE_KEY")!.replace(/\\n/g, "\n");

  const now = Math.floor(Date.now() / 1000);

  // Build unsigned JWT header + claim
  const header = { alg: "RS256", typ: "JWT" };
  const claim = {
    iss: clientEmail,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };

  const encode = (obj: object) =>
    btoa(JSON.stringify(obj))
      .replace(/=/g, "")
      .replace(/\+/g, "-")
      .replace(/\//g, "_");

  const signingInput = `${encode(header)}.${encode(claim)}`;

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

  const signatureB64 = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");

  const jwt = `${signingInput}.${signatureB64}`;

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

// ─── Main handler ──────────────────────────────────────────────────────────────

serve(async (req) => {
  try {
    const payload = await req.json();

    // Supabase Webhook sends the row inside payload.record
    const record = payload.record ?? payload;
    const { id, sender_username, receiver_username, text, timestamp } = record;

    console.log(`[send-push] New message from ${sender_username} → ${receiver_username}`);

    if (!receiver_username) {
      return new Response("Missing receiver_username", { status: 400 });
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
      console.log(`[send-push] No FCM token for ${receiver_username} — skipping`);
      return new Response("No FCM token registered", { status: 200 });
    }

    // Get a short-lived Google OAuth2 access token
    const accessToken = await getGoogleAccessToken();
    const projectId = Deno.env.get("FIREBASE_PROJECT_ID")!;

    // Build the FCM HTTP v1 payload
    const fcmPayload = {
      message: {
        token: profile.fcm_token,

        // Visible system notification (shown even when app is killed)
        notification: {
          title: sender_username,
          body: text ?? "Sent an attachment",
        },

        // Data payload — processed by Flutter _firebaseMessagingBackgroundHandler
        data: {
          id: String(id ?? ""),
          sender_username: String(sender_username ?? ""),
          receiver_username: String(receiver_username ?? ""),
          text: String(text ?? ""),
          timestamp: String(timestamp ?? Date.now()),
        },

        // Android-specific: high priority to wake device, correct channel
        android: {
          priority: "high",
          notification: {
            channel_id: "messages_channel",
            sound: "default",
            click_action: "FLUTTER_NOTIFICATION_CLICK",
          },
        },
      },
    };

    // Send to FCM HTTP v1 API
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

    console.log(`[send-push] FCM delivered: ${fcmJson.name}`);
    return new Response(JSON.stringify({ success: true, name: fcmJson.name }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("[send-push] Unhandled error:", err);
    return new Response(String(err), { status: 500 });
  }
});
