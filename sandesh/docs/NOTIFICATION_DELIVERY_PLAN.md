# Sandesh — Custom Notifications + Layered 100% Delivery

Goal: show a **custom, app-drawn notification** (with inline Reply) on the fast
path, while **guaranteeing** the recipient is notified even on aggressive
battery-killer OEMs (Xiaomi/Oppo/Vivo/Realme) — accepting a 2–3 s worst-case
delay in exchange for reliability.

## The 4 layers

1. **Custom push (fast path).** `send-push` sends a **data-only** FCM message.
   The receiver's app (foreground via Realtime, or the FCM **background
   isolate**) draws its **own** notification — which can include the inline
   **Reply** action. Custom UI + Reply, everywhere.

2. **Realtime.** While the app is alive, Supabase Realtime delivers the message
   instantly; the receiver draws the custom notification and writes a
   `message_receipts` row with status `delivered`.

3. **Store-and-forward (message can never be lost).** The cloud `messages` row
   is retained until the receiver saves it locally, then deleted. If every push
   fails, the message still arrives on the next app open / reconnect.

4. **Verified backstop (guaranteed *notification*).** After sending, the sender
   waits ~4 s for a `delivered` receipt. If none arrives, it calls the
   **`renotify`** Edge Function, which sends a **notification-shape** FCM push
   (drawn by the Android system itself — the most OEM-reliable way to guarantee
   the popup appears). Because it only fires when unconfirmed, there's no
   duplicate in the common case.

## Dedup
Every layer tags its notification with the **message id** (Android `tag` /
FCM `android.notification.tag` + `collapse_key`). Android shows at most one
notification per tag, so overlapping layers collapse into one.

## Delivery verification signal
`message_receipts(status='delivered')` is written by the receiver the instant it
shows/saves the message (Realtime path and the FCM background isolate). The
sender already subscribes to receipts (`SupabaseBroadcastService.statusStream`),
so it "knows" a message was delivered and can cancel the Layer-4 backstop.

## Components
- `supabase/functions/send-push`  — PRIMARY. Change message pushes to
  **data-only** (keep call invites as notification-shape). *(repo-ready; deploy
  only with the new APK — see release step.)*
- `supabase/functions/renotify`   — NEW, additive. JWT-verified; sends a
  notification-shape backstop push. Safe to deploy immediately (old apps never
  call it).
- App background FCM handler       — draws the custom notification (Reply +
  sound/vibrate gating + tag) and writes a `delivered` receipt.
- App sender (`sendMessage`)       — replaces the always-on direct fallback with
  a **receipt-verified** 4 s backstop that calls `renotify` only if unconfirmed.

## Release ordering (must follow)
1. Ship the new APK (contains the background-isolate custom notification + the
   verified backstop caller).
2. **Only then** deploy `send-push` in data-only mode.
   Until step 2, `send-push` stays notification-shape (current v15) so users on
   the old APK keep getting notifications.
3. `renotify` can be deployed any time (additive).

Rationale: flipping `send-push` to data-only before the APK ships would leave
current users with no app to draw the notification → missed notifications.

## Implementation status (as built)
- ✅ `renotify` — **DEPLOYED v1, ACTIVE, `verify_jwt=true`** on project
  `dexyuhjngnmljofxdfwe`. Re-checks `message_receipts` before sending (skips if
  a `delivered`/`read` receipt already landed) and honours `messages_enabled`.
  Notification-shape push tagged with the message id (+ `apns-collapse-id`).
- ✅ App background FCM handler (`main.dart`) — `_showBackgroundChatNotification`
  draws a custom notification **with the inline Reply action** ONLY for
  data-only pushes (`message.notification == null`); when a `notification` block
  is present (current v15 send-push) Android already showed it, so we skip to
  avoid a duplicate. This makes the client safe to ship BEFORE the send-push
  data-only flip. It also calls `_sendDeliveredReceiptFromBackground` to write
  the Layer-4 `delivered` receipt from the killed-app isolate.
- ✅ App sender (`SupabaseBroadcastService`) — `_scheduleDeliveryBackstop`
  replaces the old always-on `send-notification` fallback: arms a 4 s timer
  (`_backstopTimers[messageId]`) that calls `renotify` only if no receipt lands;
  `_applyReceipt` cancels the timer the instant a `delivered`/`read` receipt
  arrives. No duplicate in the common (fast) case.
- ⏳ `send-push` data-only flip — NOT done yet (still v15 notification-shape).
  Flip only after the new APK ships (see release ordering above).
