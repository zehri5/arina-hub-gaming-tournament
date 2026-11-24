import 'dart:io' show Platform;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../config.dart';
import 'admin_config.dart';  // FIX 32 (merge step 4): AdminMode moved here with the panel removal — same repoint as auth_screen.dart.
import '../utils.dart';
import 'device_ban_gate.dart';
import 'presence_service.dart';
import 'push_service.dart';
import 'supabase_db.dart';

/// FIX 30 (2026-11-24): the auth logic behind the new AI Studio
/// LoginScreen / SignupScreen / forgot-password sheet.
///
/// This is the logic from `AuthScreen` (`lib/screens/auth_screen.dart`,
/// left in place, unused) moved verbatim into static methods so the new
/// screens can call it through their callbacks: Firebase email/password
/// login + signup, Google sign-in, forgot-password reset email, the P2
/// device-ban gate, the duplicate-device warning, login-session
/// recording, push/presence sync. NO behaviour changed — the only
/// differences from the AuthScreen originals are mechanical:
///   * `mounted` -> `context.mounted` (static methods have no State);
///   * the `_busy` setState is gone — the new screens own their own
///     loading state around the callbacks;
///   * `sendPasswordReset` THROWS on failure (instead of toasting) so
///     the forgot-password sheet can show the error inline; on success
///     it completes silently — the sheet's own "Reset link sent"
///     panel is the confirmation (it replaces today's toast).
/// Post-login navigation is unchanged: nothing here navigates — the
/// SplashGate's authStateChanges stream swaps to HomeShell on sign-in,
/// exactly as before.
class AuthService {
  AuthService._();

  /// Email/password LOGIN. Same validation + toast as AuthScreen.
  static Future<void> signInWithEmail(
      BuildContext context, String email, String password) async {
    email = email.trim();
    password = password.trim();
    if (email.isEmpty || password.length < 6) {
      toast(context,
          'Enter a valid email and a password of at least 6 characters.');
      return;
    }
    try {
      final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email, password: password);
      // P2 device-ban gate: a banned account/device stops HERE —
      // before profile sync, login-session record and push/presence.
      if (await _checkDeviceBan(context, cred.user!.uid)) return;
      // Normal login must NEVER restore admin mode: a previous
      // Admin Login marker is cleared here (logout also clears it).
      await AdminMode.set(false);
      await SupaDb.ensureUserProfile(cred.user!);
      await _deviceCheck(context, cred.user!.uid);
      await _recordLoginSession(cred.user!.uid);
      await PushService.syncPlayerId();
      await PresenceService.goOnline();
    } on FirebaseAuthException catch (e) {
      if (context.mounted) toast(context, e.message ?? 'Authentication failed.');
    } catch (e) {
      if (context.mounted) toast(context, 'Error: $e');
    }
  }

  /// Email/password SIGNUP. `referralCode` is optional (empty = none);
  /// `fullName` becomes the profile display name (empty = none).
  static Future<void> signUpWithEmail(
    BuildContext context, {
    required String fullName,
    required String email,
    required String password,
    String referralCode = '',
  }) async {
    email = email.trim();
    password = password.trim();
    fullName = fullName.trim();
    referralCode = referralCode.trim();
    if (email.isEmpty || password.length < 6) {
      toast(context,
          'Enter a valid email and a password of at least 6 characters.');
      return;
    }
    try {
      final cred = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: password);
      // Same gate on signup: a banned device must not create a
      // usable profile (the just-created Firebase account is
      // signed out by _checkDeviceBan; it stays an orphan account
      // that cannot log in from this device).
      if (await _checkDeviceBan(context, cred.user!.uid)) return;
      await SupaDb.ensureUserProfile(
        cred.user!,
        referralCodeFromSignup: referralCode,
        displayNameOverride: fullName.isEmpty ? null : fullName,
      );
      await _deviceCheck(context, cred.user!.uid);
      await _recordLoginSession(cred.user!.uid);
      await PushService.syncPlayerId();
      await PresenceService.goOnline();
    } on FirebaseAuthException catch (e) {
      if (context.mounted) toast(context, e.message ?? 'Authentication failed.');
    } catch (e) {
      if (context.mounted) toast(context, 'Error: $e');
    }
  }

  /// Google Sign-In, fixed code-side (2026-10-27):
  /// - Explicit serverClientId when configured (AppConfig
  ///   .googleServerClientId, from Firebase Console → Authentication
  ///   → Google → Web client ID). This is the QUETTA-proven pattern
  ///   for signing in WITHOUT google-services.json in the app.
  /// - New Google user gets the same profile defaults as email
  ///   signup (ensureUserProfile), and OneSignal player ID + presence
  ///   sync run after sign-in, exactly like email login.
  /// - Error 10 (DEVELOPER_ERROR) is now detected in BOTH exception
  ///   branches (previously the FirebaseAuthException branch swallowed
  ///   it and only showed the raw message). Error 10 means this app's
  ///   SHA-1 is not registered in Firebase/Cloud Console for
  ///   com.protournament.app — it is NOT a password/account problem,
  ///   and sign-in CANNOT work until that console step is done.
  ///   That console step is OUTSIDE this code and is reported to the
  ///   parent separately; it is never claimed as done here.
  static Future<void> signInWithGoogle(BuildContext context) async {
    try {
      final signIn = AppConfig.googleServerClientId.isEmpty
          ? GoogleSignIn()
          : GoogleSignIn(serverClientId: AppConfig.googleServerClientId);
      final googleUser = await signIn.signIn();
      if (googleUser == null) {
        // User cancelled - graceful, no crash.
        if (context.mounted) toast(context, 'Google sign-in cancelled.');
        return;
      }
      final googleAuth = await googleUser.authentication;
      if (googleAuth.idToken == null || googleAuth.idToken!.isEmpty) {
        throw Exception(
            'Google ne idToken nahi diya — Firebase Console me Web client ID / SHA-1 registration check karen.');
      }
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      final cred = await FirebaseAuth.instance.signInWithCredential(credential);
      // P2 device-ban gate (see signInWithEmail): stops here on a hit.
      if (await _checkDeviceBan(context, cred.user!.uid)) return;
      // Normal login must NEVER restore admin mode (see signInWithEmail).
      await AdminMode.set(false);
      await SupaDb.ensureUserProfile(cred.user!);
      await _deviceCheck(context, cred.user!.uid);
      await _recordLoginSession(cred.user!.uid);
      await PushService.syncPlayerId();
      await PresenceService.goOnline();
    } on FirebaseAuthException catch (e) {
      if (context.mounted) {
        final msg = '${e.code} ${e.message ?? ''}';
        final isError10 = msg.contains('10') ||
            msg.contains('DEVELOPER_ERROR') ||
            msg.contains('sign_in_failed') ||
            msg.contains('invalid-credential');
        toast(
          context,
          isError10
              ? 'Google sign-in failed (error 10): is app ka SHA-1 (0A:78:65:38…) Firebase + Cloud Console me com.protournament.app ke liye register nahi hai, isliye Google login nahi chalega jab tak wo register na ho. Email login se kaam chalayen.'
              : (e.message ?? 'Google sign-in failed.'),
        );
      }
    } catch (e) {
      final msg = e.toString();
      final isError10 = msg.contains('ApiException: 10') ||
          msg.contains('DEVELOPER_ERROR') ||
          msg.contains('sign_in_failed');
      if (context.mounted) {
        toast(
          context,
          isError10
              ? 'Google sign-in failed (error 10): is app ka SHA-1 Firebase + Cloud Console me register nahi hai, isliye Google login nahi chalega jab tak wo register na ho. Email login se kaam chalayen.'
              : 'Google sign-in failed: $e',
        );
      }
    }
  }

  /// Forgot password: sends the Firebase reset email. THROWS on
  /// failure so the forgot-password sheet can show the error inline;
  /// on success completes silently (the sheet's success panel is the
  /// confirmation). The old AuthScreen version toasted in both cases.
  static Future<void> sendPasswordReset(
      BuildContext context, String email) async {
    email = email.trim();
    if (email.isEmpty) {
      throw Exception('Enter your email first.');
    }
    await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
  }

  /// P2 device-ban gate (2026-11-22): runs AFTER Firebase sign-in,
  /// BEFORE profile sync. Returns true when the login must stop:
  /// the Firebase session is signed out and a ban message is shown,
  /// and the caller returns early so no profile is created/synced,
  /// no login session is recorded and no push/presence sync runs.
  /// FAIL-OPEN: a failed ban read never blocks login (see
  /// [DeviceBanGate.isBanned] — the read itself, and this wrapper,
  /// both swallow errors and return "not banned").
  static Future<bool> _checkDeviceBan(BuildContext context, String uid) async {
    try {
      final deviceId = await DeviceBanGate.localDeviceId();
      if (!await DeviceBanGate.isBanned(uid: uid, deviceId: deviceId)) {
        return false;
      }
    } catch (_) {
      return false;
    }
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
    if (context.mounted) {
      toast(
        context,
        'This account or device is banned from ARENA HUB. If you think this is a mistake, contact support.',
      );
    }
    return true;
  }

  /// FULL COMPLETION expansion 2: duplicate-account detection via
  /// device. A stable per-install device id is stored locally and on
  /// the profile (migration 008 adds profiles.device_id). If OTHER
  /// accounts already use this device, the user gets a WARNING only —
  /// never a block (a shared family phone is legitimate). If the
  /// column does not exist yet, everything is silently skipped.
  static Future<void> _deviceCheck(BuildContext context, String uid) async {
    try {
      final deviceId = await DeviceBanGate.localDeviceId();
      try {
        await SupaDb.updateProfile(uid, {'device_id': deviceId});
      } catch (_) {
        return; // column missing (migration 008 not run) — skip silently.
      }
      final others =
          await SupaDb.getList('profiles', eqCol: 'device_id', eqVal: deviceId);
      final otherUids = others
          .map((r) => SupaDb.strOf(r['firebase_uid']))
          .where((u) => u.isNotEmpty && u != uid)
          .toSet();
      if (otherUids.isNotEmpty && context.mounted) {
        toast(context,
            'Note: is device par ${otherUids.length} aur account bhi hai. Duplicate accounts fair-play review me flag ho sakte hain.');
      }
    } catch (_) {}
  }

  /// LOGIN HISTORY (audit fix 2026-11-21; extended 2026-11-22 per
  /// draft 078_login_sessions_columns): records this sign-in in
  /// `login_sessions` so the Account Security page / SessionsPage can
  /// show real login history. Columns written, all best-effort:
  ///   * device_id — the stable per-install id from
  ///     [DeviceBanGate.localDeviceId] (same id `_deviceCheck`
  ///     mirrors onto profiles.device_id; 069 added the column).
  ///   * device_name — [SupaDb.deviceLabel] ("android 12" style;
  ///     no device_info_plus dependency — it is only transitive
  ///     here, never a direct dep, so it must not be imported).
  ///   * device_type — [Platform.operatingSystem] ("android"/"ios").
  ///   * last_active_at — now (this sign-in is the latest activity).
  ///   * ip / location are NOT written: the app has no client-side
  ///     source for the public IP or a geolocation (078 O2 leaves
  ///     the source to the writer batch — it is a server-side/IP
  ///     lookup, not invented here). The columns stay NULL until
  ///     that lands; SessionsPage shows "Unknown location" then.
  /// Tiered fallback: on a pre-078 database the full insert fails
  /// (unknown column) and the minimal row (firebase_uid +
  /// created_at) is retried, so login history never breaks login
  /// and never breaks on an older schema. A failed insert never
  /// blocks login.
  static Future<void> _recordLoginSession(String uid) async {
    try {
      final deviceId = await DeviceBanGate.localDeviceId();
      await SupaDb.client.from('login_sessions').insert({
        'firebase_uid': uid,
        'device_id': deviceId,
        'device_name': SupaDb.deviceLabel(),
        'device_type': Platform.operatingSystem,
        'last_active_at': SupaDb.isoNow(),
        'created_at': SupaDb.isoNow(),
      });
    } catch (_) {
      try {
        await SupaDb.client.from('login_sessions').insert({
          'firebase_uid': uid,
          'created_at': SupaDb.isoNow(),
        });
      } catch (_) {}
    }
  }
}
