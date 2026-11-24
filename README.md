# Pro Tournament — User App (Flutter, native — NO WebView)

Native Flutter port of the single-file HTML user app ("Gaming Tournament" /
"Pro Tournament") on the SAME Firebase project (Realtime Database + Auth).
Dark slate `#0F172A` theme with gold `#FACC15` accent.

Package: `com.protournament.app`. Firebase config lives in
`lib/firebase_options.dart` (generated from the HTML app's `firebaseConfig`;
no `google-services.json` — that file has caused splash freezes here).

## Screens / flows

Splash, maintenance screen (`settings/maintenanceMode`), login + signup
(email/password) + forgot password, Continue with Google, home (promotion
slider, **sponsored ads banners**, games list, my contests), tournaments
list + filter (all/upcoming/ongoing/completed, game filter), tournament
details, join tournament form (game UID, team name, slot, teammates),
room ID/password modal (joined users only), tournament chat, upload result
screenshot (ImgBB), wallet (deposit/winning/bonus balances, transactions,
withdraw modal, add amount), recharge 3-step flow (amount → method →
payment details + TID submit), earnings + referral (share referral code),
leaderboard, profile (edit name, match history, support ticket, contact
us via WhatsApp, notifications toggle, logout), notifications list,
policy modals (terms/privacy/refund/fair play/refer from `settings`),
no-internet state. No audio: sounds were optional in the spec and are
skipped entirely.

## RTDB nodes (field names match the HTML app exactly)

`users`, `games`, `promotions`, `tournaments` (+`registeredPlayers`),
`transactions`, `withdrawals`, `deposits`, `pendingReferrals`, `settings`,
`notifications`, `users/{uid}/notifications`, `users/{uid}/matchHistory`,
`chats/{tournamentId}`, `support_tickets`, `tournament_results`, plus
the NEW `ads` node (below).

Email signup creates `users/{uid}` with the HTML defaults: `uid`,
`displayName`, `email`, `photoURL`, `depositBalance: 0`, `winningCash: 0`,
`bonusCash: settings/signupBonus (default 10)`, `totalMatches: 0`,
`wonMatches: 0`, `totalEarnings: 0`, `referralEarnings: 0`,
`createdAt`, `referralCode` (8 chars A–Z/0–9), `joinedTournaments: {}`,
`isAdmin: false`, `lastCheckedNotifications`, `lastLogin`, plus
`referredBy` + a `pendingReferrals` record when a referral code was used.
Google sign-in uses the exact same defaults (name from Google account).

Join fee rule (HTML parity): spendable = `depositBalance + winningCash`
only (bonus is NOT spendable); deposit is deducted first, then winning.
Recorded as a `join_fee` transaction; `joinedTournaments/{id} = true`.

## Google Sign-In — PENDING STEP (do not claim it works yet)

1. Build the APK, read its SHA-1 (see below).
2. In Firebase console, add an **Android app** for package
   `com.protournament.app` with that SHA-1, and make sure the matching
   Android OAuth client in Google Cloud Console carries the same SHA-1.
3. Until then, email login works; Google sign-in will fail at the
   Firebase step and shows a toast (no crash). Cancelled sign-in is
   handled gracefully (toast, no crash).

## Push notifications (OneSignal, free) — PENDING STEP

- App initialises OneSignal and stores the player ID at
  `users/{uid}/onesignalId` (see `lib/services/push_service.dart`).
- The App ID is NEVER hardcoded: it comes from RTDB
  `settings/onesignal/appId` (preferred) or the empty placeholder in
  `lib/config.dart`. **The user has NOT provided a OneSignal App ID yet**,
  so push initialisation is currently skipped gracefully.
- In-app RTDB notifications (`notifications` + `users/{uid}/notifications`)
  work independently of OneSignal and are unaffected.
- The OneSignal Flutter SDK (5.x) is compatible with the installed
  Flutter 3.47.7 — no `firebase_messaging` fallback was needed.

## Ads system (QUETTA-style)

New RTDB node `ads/{adId}`:

```json
{
  "title": "string",
  "imageUrl": "string",
  "targetType": "tournament | game | promotion",
  "targetId": "string",
  "targetName": "string",
  "active": true,
  "createdAt": 0
}
```

Home shows a horizontal, YouTube-size (16:9-ish) sponsored banners row,
separate from the promotions slider. Only `active == true` ads show.
Tapping deep-links to the tournament / game / promotion detail; if the
target is deleted or inactive, the app shows
"This offer is no longer available". (The admin app owns creating ads.)

## EasyPaisa + JazzCash — API-READY, NOT API-LIVE

**What works today (manual fallback, same as the HTML deposit flow):**
recharge method picker includes EasyPaisa and JazzCash alongside UPI
and Bank Transfer. The user pays in their own wallet app, then submits
the Transaction ID/UTR; the app creates a `deposits` record with
`method: easypaisa | jazzcash` and `status: pending` for admin approval.
The payment account number/title shown come from RTDB
`settings/payments/easypaisa` / `settings/payments/jazzcash`
(fields: `enabled`, `merchantId`, `storeId`, `apiEndpoint`,
`accountNumber`, `accountTitle` — all empty placeholders by default).
If no account is set, the screen shows
"Admin se account number set karwayen".

**What does NOT work until the API is provided:**
automatic instant verification/confirmation of a payment, automatic
balance credit on payment, and any provider-side payment status check.
`PaymentService.verifyPayment()` / `getPaymentStatus()` return
`pending` in manual mode. **Do not claim automatic verification works.**

**When the user provides real API credentials/endpoints:**
only `lib/services/payment_service.dart` + the RTDB
`settings/payments/*` config need to change — implement the real
`initiatePayment` / `verifyPayment` calls there. No screen rebuilds
are needed: recharge screens only call this service.

## ImgBB uploads

Same endpoint/flow as the HTML `uploadToImgBB` (POST multipart to
`api.imgbb.com/1/upload`, `data.url` on success). The HTML app's
embedded key is deliberately NOT copied into this codebase: the key is
read at runtime from RTDB `settings/imgbbApiKey` (or the empty
placeholder in `lib/config.dart`). Uploads show a clear message while
no key is configured.

## Build notes (this environment)

```sh
export PATH="/home/hatch/flutter-sdk/bin:$PATH" JAVA_HOME=/home/hatch/jdk-17 \
  ANDROID_HOME=/home/hatch/android-sdk GRADLE_USER_HOME=/home/hatch/.gradle \
  _JAVA_OPTIONS="-Djava.net.preferIPv4Stack=true" \
  GRADLE_OPTS="-Djava.net.preferIPv4Stack=true"
flutter pub get
flutter analyze
flutter build apk --release --split-per-abi   # arm64 APK is the deliverable
```

Gradle downloads go via local mitmproxy on 127.0.0.1:8080 (start it
first with fresh `$https_proxy` credentials if nothing listens there).
`shared_preferences` is pinned to 2.3.0 + `shared_preferences_android`
2.3.3 override (2.5.x crashes at runtime here).

Debug keystore backup: `keystore-backup/debug.keystore` under
`~/workspace/tournament-flutter/` — restore it to `/root/.android/`
(`mkdir -p /root/.android` first) before later builds so the SHA-1
stays stable. Report the APK SHA-1 from apksigner/keytool after every
build; it must be registered in Firebase for Google Sign-In.

## Live chat + presence + FREE voice chat

**Online presence:** on login the app writes
`users/{uid}/presence = {online: true, lastSeen, currentTournamentId,
squadId}` and registers an `onDisconnect` handler that sets
`online: false` + `lastSeen`. A green dot (grey + last-seen when
offline) is shown on tournament player lists, squad lists, chats and
voice rooms, and on the leaderboard ONLY when the viewer shares a
tournament with that player - never as a global user directory.

**Text chat:** tournament lobby chat stays at `chats/{tournamentId}`
(realtime listener, sender name, timestamp, all joined players).
Squad chat is new at `chats/squad/{squadId}`, offered only to that
squad's members.

**Squad definition (assumption, documented):** the HTML join form has
no explicit squad record - only `teamName` (+ slot) per tournament.
So squad = players sharing the same `teamName` in the same tournament,
`squadId = <tournamentId>_<normalised teamName>` (lowercased,
non-alphanumerics to underscores). Solo players (empty teamName) have
no squad. The join screen stores `squadId` on the
`registeredPlayers` entry.

**FREE voice chat:** `flutter_webrtc` 0.12.12 peer-to-peer mesh with
Firebase RTDB signaling - no paid service, no billing, nothing
recorded or stored. Two rooms, both labelled in UI:
(a) Squad Voice Room, roomId `squad_<squadId>`, squad members only;
(b) Tournament Voice Room, roomId `tournament_<tournamentId>`,
every joined player. Controls: join/leave, mute/unmute, speaker
on/off, member list with online + muted state, push-to-talk.
Both rooms join MUTED by default. Mic permission is requested with a
graceful denial message. Leave removes signaling + peer entries.

Signaling data model:
- `voice_signaling/{roomId}/peers/{uid}` = `{name, muted, joinedAt}`
- `voice_signaling/{roomId}/inbox/{toUid}/{pushId}` =
  `{kind: offer|answer|ice, from, sdpType?, sdp?, candidate?, sdpMid?,
  sdpMLineIndex?, timestamp}` (deleted after handling; STUN is the
  free public `stun:stun.l.google.com:19302`, no account).
  The later joiner initiates offers to existing peers (tie broken by
  larger uid), so exactly one offer per pair is created.

**Admin voice gate (contract keys, read by this app):**
`settings/voiceEnabled` (global, default true) and
`tournaments/{tournamentId}/voiceEnabled` (per-tournament, default
true). If either is false, voice buttons hide/disable with a clear
message. Absent keys = enabled.

**Voice limits (honest, also shown in-app):** free mesh bandwidth/CPU
grows with room size, so large tournament rooms may degrade - the app
does NOT claim unlimited simultaneous speakers will be perfect.
"Speaking" is approximated by "unmuted": true voice-activity
detection is not available from flutter_webrtc audio tracks.
Live 2-device voice testing was NOT done (no second device in this
environment) - build + analyze verification only; voice must be
tested on two real devices before being announced as working.


### Voice build workarounds (sandbox only, 2026-10-26)

- Gradle reads via this sandbox's proxy time out on `jitpack.io`
  (curl via egress works, Gradle via local mitm hangs). Fix applied:
  the only JitPack artifact (`com.github.davidliu:audioswitch`, needed
  by flutter_webrtc) is vendored as `android/local-maven/` and listed
  first in `android/build.gradle.kts`; the JitPack repo line was
  removed from the pub-cache copy of flutter_webrtc
  (`~/.pub-cache/hosted/pub.dev/flutter_webrtc-0.12.12+hotfix.1/android/build.gradle`,
  backup at `build.gradle.bak`) so metadata queries no longer poison
  unrelated resolutions. Restore the JitPack line outside the sandbox.
- Same pub-cache copy patched: `compileSdkVersion 31` -> `36`
  (its transitive deps, e.g. fragment 1.7.1, require >= 34).
  Re-apply both patches if the flutter_webrtc version changes.

## Known gaps vs the HTML app

- No background music / click sounds (optional, skipped deliberately).
- Popup banner (`settings/popupBanner`) and forced-update prompt
  (`settings/updateConfig`) from the HTML app are not rendered as
  dialogs; maintenance + in-app flow covers the same gating.
- The HTML app's RTDB config had no `databaseURL`; this app uses the
  project's default RTDB URL in `firebase_options.dart`. If the admin's
  database lives in a non-default region, update that URL.
- `firebase_options.dart` reuses the HTML app's **web** `appId` for the
  Android options. Registering a real Android app in Firebase console
  (SHA-1 step above) and swapping in its Android `appId` is recommended.
