// Supabase Edge Function — send-notification/index.ts
// Deploy with: supabase functions deploy send-notification
//
// Environment secrets required (set in Supabase Dashboard → Settings → Edge Functions):
//   FIREBASE_PROJECT_ID       — your Firebase project ID
//   FIREBASE_CLIENT_EMAIL     — service account client_email
//   FIREBASE_PRIVATE_KEY      — service account private_key (with \n line breaks)
//   SUPABASE_URL              — auto-injected by Supabase
//   SUPABASE_SERVICE_ROLE_KEY — set this manually (needed to bypass RLS when reading profiles)

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

// ── Google OAuth2 — get a short-lived access token for FCM HTTP v1 ──────────
async function getFirebaseAccessToken(clientEmail: string, privateKey: string): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: clientEmail,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };

  // Build a JWT manually (header.payload.signature)
  const header = { alg: "RS256", typ: "JWT" };
  const encode = (obj: unknown) =>
    btoa(JSON.stringify(obj))
      .replace(/=/g, "")
      .replace(/\+/g, "-")
      .replace(/\//g, "_");

  const unsignedToken = `${encode(header)}.${encode(payload)}`;

  // Import the RSA private key — handle both literal \n and real newlines
  const pemKey = privateKey.replace(/\\n/g, "\n");
  const pemBody = pemKey
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  const binaryKey = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));

  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    binaryKey,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    new TextEncoder().encode(unsignedToken)
  );

  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");

  const jwt = `${unsignedToken}.${sigB64}`;

  // Exchange JWT for an access token
  const tokenResp = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  });

  const tokenData = await tokenResp.json() as { access_token?: string; error?: string };
  if (!tokenData.access_token) {
    throw new Error(`Failed to get FCM access token: ${JSON.stringify(tokenData)}`);
  }
  return tokenData.access_token;
}

// ── Main handler ─────────────────────────────────────────────────────────────
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    // ── 1. Parse request body ────────────────────────────────────────────────
    const body = await req.json().catch(() => ({})) as Record<string, string>;
    const {
      receiver_username,
      sender_username,
      text,
      message_id,
      message_type,
      timestamp,
    } = body;

    if (!receiver_username || !sender_username) {
      return json({ error: "receiver_username and sender_username are required" }, 400);
    }

    console.log(`[send-notification] ${sender_username} → ${receiver_username}: "${text}"`);

    // ── 2. Load secrets ──────────────────────────────────────────────────────
    const projectId     = Deno.env.get("FIREBASE_PROJECT_ID");
    const clientEmail   = Deno.env.get("FIREBASE_CLIENT_EMAIL");
    const privateKey    = Deno.env.get("FIREBASE_PRIVATE_KEY");
    const supabaseUrl   = Deno.env.get("SUPABASE_URL");
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!projectId || !clientEmail || !privateKey || !supabaseUrl || !supabaseServiceKey) {
      console.error("[send-notification] Missing env vars");
      return json({ error: "Server not configured — missing env vars" }, 500);
    }

    // ── 3. Look up the receiver's FCM token from Supabase ───────────────────
    // We use the service role key here to bypass RLS and read any profile
    const profileResp = await fetch(
      `${supabaseUrl}/rest/v1/profiles?select=fcm_token&username=eq.${encodeURIComponent(receiver_username.toLowerCase())}&limit=1`,
      {
        headers: {
          apikey: supabaseServiceKey,
          Authorization: `Bearer ${supabaseServiceKey}`,
        },
      }
    );

    const profiles = await profileResp.json() as Array<{ fcm_token?: string }>;
    const fcmToken = profiles?.[0]?.fcm_token;

    if (!fcmToken) {
      console.log(`[send-notification] No FCM token for ${receiver_username} — skipping push`);
      return json({ skipped: true, reason: "no_fcm_token" });
    }

    console.log(`[send-notification] Sending FCM to token: ${fcmToken.slice(0, 20)}...`);

    // ── 4. Get Firebase access token ─────────────────────────────────────────
    const accessToken = await getFirebaseAccessToken(clientEmail, privateKey);

    // ── 5. Send FCM message (data-only, so background handler fires) ─────────
    const fcmPayload = {
      message: {
        token: fcmToken,
        // Data-only payload — our background handler shows the notification
        data: {
          type: "message",
          id: message_id ?? "",
          sender_username: sender_username,
          receiver_username: receiver_username,
          text: text ?? "",
          message_type: message_type ?? "text",
          timestamp: timestamp ?? String(Date.now()),
        },
        android: {
          priority: "high",
        },
      },
    };

    const fcmResp = await fetch(
      `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${accessToken}`,
        },
        body: JSON.stringify(fcmPayload),
      }
    );

    const fcmResult = await fcmResp.json() as { name?: string; error?: { message: string } };
    console.log("[send-notification] FCM response:", JSON.stringify(fcmResult));

    if (fcmResult.error) {
      // Token is stale — clear it so we don't keep trying
      if (fcmResult.error.message?.includes("UNREGISTERED") ||
          fcmResult.error.message?.includes("INVALID_ARGUMENT")) {
        console.log("[send-notification] Stale token — clearing from DB");
        await fetch(
          `${supabaseUrl}/rest/v1/profiles?username=eq.${encodeURIComponent(receiver_username.toLowerCase())}`,
          {
            method: "PATCH",
            headers: {
              apikey: supabaseServiceKey,
              Authorization: `Bearer ${supabaseServiceKey}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ fcm_token: null }),
          }
        );
      }
      return json({ error: fcmResult.error.message }, 500);
    }

    return json({ success: true, fcm_message_id: fcmResult.name });
  } catch (e) {
    console.error("[send-notification] Error:", (e as Error).message);
    return json({ error: `Internal error: ${(e as Error).message}` }, 500);
  }
});
