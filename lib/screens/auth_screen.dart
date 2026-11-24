import 'dart:io' show Platform;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../components/arena_components.dart';
import '../config.dart';
import '../services/device_ban_gate.dart';
import '../services/presence_service.dart';
import '../services/push_service.dart';
import '../services/supabase_db.dart';
import '../utils.dart';
import '../widgets/arena_ui.dart';
import '../services/admin_config.dart';

/// Login + signup (email/password) + forgot password + Google Sign-In.
/// Google: new user gets the same users/{uid} defaults as email signup;
/// existing user just signs in. Cancelled sign-in = toast, no crash.
/// Wave B #33 restyle (hubahu to mockup 95635775): crown + ARENA HUB
/// lockup, "WELCOME BACK, / PLAYER" headline, mail/lock fields with
/// visibility toggle, gold LOGIN pill, OR divider, "Continue with
/// Google" pill with drawn multicolour G, "New player? Create
/// Account" footer. NO auth logic changed. A-7: NO admin affordance
/// on this screen (verified — none present).
/// P2 device-ban login gate — BUILT 2026-11-22 (see
/// DeviceBanGate): after Firebase sign-in, before profile sync,
/// `device_bans` is checked by firebase_uid and by the local
/// device_id; on a hit the session is signed out and a ban message
/// is shown. FAIL-OPEN: a failed ban read never blocks login.
/// PHASE 2 REDESIGN S14 (Screen 14 — Login, 2026-11-23, styling
/// ONLY, NO logic/flow change): ArenaBackground gradient +
/// golden glow + FireSparks particles behind the form; fields,
/// Login CTA and Google button rebuilt on the shared F2
/// components (ArenaTextField / ArenaPrimaryButton /
/// ArenaCardButton since FIX 23 item 29 Part C); spacing via kSpace* tokens; Forgot
/// Password given a full tap target. Auth, validation, password
/// visibility, Google sign-in, ban gate, keyboard behaviour —
/// all UNCHANGED. The mail/lock prefix icons are gone: the shared
/// ArenaTextField has no prefix-icon slot (contract signature),
/// so the fields follow the shared input style exactly.
/// PHASE 2 REDESIGN S15 (Screen 15 — Create Account, 2026-11-23):
/// screen-level styling merged — subtitle + footer text on
/// kStyleBody, form spacing on kSpace* (S14 had already tokenised
/// the same spacing lines). Per the S14↔S15 decision (NOTE 3) the
/// shared [_AuthField]/[_GoldPillButton] stay S14's contract
/// rebuilds (ArenaTextField / ArenaPrimaryButton) — S15's kept
/// prefix icons + radius-30 pill did NOT merge, so both screens'
/// auth fields are identical.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isLogin = true;
  bool _busy = false;
  bool _obscurePassword = true;
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _referral = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _referral.dispose();
    super.dispose();
  }

  Future<void> _emailAuth() async {
    final email = _email.text.trim();
    final password = _password.text.trim();
    if (email.isEmpty || password.length < 6) {
      toast(context, 'Enter a valid email and a password of at least 6 characters.');
      return;
    }
    setState(() => _busy = true);
    try {
      UserCredential cred;
      if (_isLogin) {
        cred = await FirebaseAuth.instance.signInWithEmailAndPassword(email: email, password: password);
        // P2 device-ban gate: a banned account/device stops HERE —
        // before profile sync, login-session record and push/presence.
        if (await _checkDeviceBan(cred.user!.uid)) return;
        // Normal login must NEVER restore admin mode: a previous
        // Admin Login marker is cleared here (logout also clears it).
        await AdminMode.set(false);
        await SupaDb.ensureUserProfile(cred.user!);
      } else {
        cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(email: email, password: password);
        // Same gate on signup: a banned device must not create a
        // usable profile (the just-created Firebase account is
        // signed out by _checkDeviceBan; it stays an orphan account
        // that cannot log in from this device).
        if (await _checkDeviceBan(cred.user!.uid)) return;
        await SupaDb.ensureUserProfile(
          cred.user!,
          referralCodeFromSignup: _referral.text.trim(),
          displayNameOverride: _name.text.trim().isEmpty ? null : _name.text.trim(),
        );
      }
      await _deviceCheck(cred.user!.uid);
      await _recordLoginSession(cred.user!.uid);
      await PushService.syncPlayerId();
      await PresenceService.goOnline();
    } on FirebaseAuthException catch (e) {
      if (mounted) toast(context, e.message ?? 'Authentication failed.');
    } catch (e) {
      if (mounted) toast(context, 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// P2 device-ban gate (2026-11-22): runs AFTER Firebase sign-in,
  /// BEFORE profile sync. Returns true when the login must stop:
  /// the Firebase session is signed out and a ban message is shown,
  /// and the caller returns early so no profile is created/synced,
  /// no login session is recorded and no push/presence sync runs.
  /// FAIL-OPEN: a failed ban read never blocks login (see
  /// [DeviceBanGate.isBanned] — the read itself, and this wrapper,
  /// both swallow errors and return "not banned").
  Future<bool> _checkDeviceBan(String uid) async {
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
    if (mounted) {
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
  Future<void> _deviceCheck(String uid) async {
    try {
      final deviceId = await DeviceBanGate.localDeviceId();
      try {
        await SupaDb.updateProfile(uid, {'device_id': deviceId});
      } catch (_) {
        return; // column missing (migration 008 not run) — skip silently.
      }
      final others = await SupaDb.getList('profiles', eqCol: 'device_id', eqVal: deviceId);
      final otherUids = others.map((r) => SupaDb.strOf(r['firebase_uid'])).where((u) => u.isNotEmpty && u != uid).toSet();
      if (otherUids.isNotEmpty && mounted) {
        toast(context, 'Note: is device par ${otherUids.length} aur account bhi hai. Duplicate accounts fair-play review me flag ho sakte hain.');
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
  Future<void> _recordLoginSession(String uid) async {
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
  Future<void> _googleSignIn() async {
    setState(() => _busy = true);
    try {
      final signIn = AppConfig.googleServerClientId.isEmpty
          ? GoogleSignIn()
          : GoogleSignIn(serverClientId: AppConfig.googleServerClientId);
      final googleUser = await signIn.signIn();
      if (googleUser == null) {
        // User cancelled - graceful, no crash.
        if (mounted) toast(context, 'Google sign-in cancelled.');
        return;
      }
      final googleAuth = await googleUser.authentication;
      if (googleAuth.idToken == null || googleAuth.idToken!.isEmpty) {
        throw Exception('Google ne idToken nahi diya — Firebase Console me Web client ID / SHA-1 registration check karen.');
      }
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      final cred = await FirebaseAuth.instance.signInWithCredential(credential);
      // P2 device-ban gate (see _emailAuth): stops here on a hit.
      if (await _checkDeviceBan(cred.user!.uid)) return;
      // Normal login must NEVER restore admin mode (see _emailAuth).
      await AdminMode.set(false);
      await SupaDb.ensureUserProfile(cred.user!);
      await _deviceCheck(cred.user!.uid);
      await _recordLoginSession(cred.user!.uid);
      await PushService.syncPlayerId();
      await PresenceService.goOnline();
    } on FirebaseAuthException catch (e) {
      if (mounted) {
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
      if (mounted) {
        toast(
          context,
          isError10
              ? 'Google sign-in failed (error 10): is app ka SHA-1 Firebase + Cloud Console me register nahi hai, isliye Google login nahi chalega jab tak wo register na ho. Email login se kaam chalayen.'
              : 'Google sign-in failed: $e',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgotPassword() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      toast(context, 'Enter your email first, then tap Forgot Password.');
      return;
    }
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (mounted) toast(context, 'Password reset email sent.');
    } catch (e) {
      if (mounted) toast(context, 'Could not send reset email: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // FIX 23 item 27 (2026-11-23 23:52): the STATIC ember_bg.png
      // image is REMOVED from the auth pages (Sameer: it should not
      // be there) — the background is now animation: the app-wide
      // smoke + ember sparks (via ArenaBackground's
      // AppBackgroundLayer) over the dark background. The local
      // FireSparks layer is gone too (sparks are app-wide now —
      // a third instance would triple the embers). The _SlashPanels
      // stay (code-drawn mockup #33 decor, not an image). The form
      // itself is unchanged.
      body: ArenaBackground(
        showGoldenGlow: true,
        child: Stack(
        children: [
          // Mockup #33: large sharp diagonal metallic SLASH panels
          // in dark silver-grey cutting in from the top-right and
          // bottom-right corners. ember_bg.png does NOT have them,
          // so they are drawn (static, behind the form). No
          // animation — the mockup is static.
          const Positioned.fill(child: IgnorePointer(child: _SlashPanels())),
          SafeArea(
        child: SingleChildScrollView(
          // KEYBOARD FIX (2026-11-20): bottom padding follows the
          // keyboard (viewInsets) so the form can always scroll
          // clear of it; fields scroll into view on focus (_kbAware).
          // Layout unchanged when the keyboard is closed.
          padding: EdgeInsets.only(left: kSpace24, right: kSpace24, bottom: MediaQuery.of(context).viewInsets.bottom + kSpace24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: kSpace16),
              // FIX 23 item 25: the new logo image replaces the
              // crown + wordmark on the sign-in/sign-up screens.
              const Center(
                  child: ArenaHubLogoImage(size: 120, ringWidth: 3)),
              const SizedBox(height: 28),
              Text(
                _isLogin ? 'WELCOME BACK,' : 'CREATE YOUR',
                textAlign: TextAlign.center,
                style: TextStyle(color: kText, fontSize: 28, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, height: 1.1),
              ),
              Text(
                _isLogin ? 'PLAYER' : 'ACCOUNT',
                textAlign: TextAlign.center,
                style: TextStyle(color: kGold, fontSize: 52, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, height: 1.05),
              ),
              const SizedBox(height: kSpace8),
              Text(
                _isLogin ? 'Your next victory starts here.' : 'Join the arena and start competing.',
                textAlign: TextAlign.center,
                style: kStyleBody.copyWith(color: kMuted),
              ),
              const SizedBox(height: kSpace32),
              if (!_isLogin)
                _kbAware(_AuthField(controller: _name, label: 'Full Name', hint: 'Enter your name')),
              _kbAware(_AuthField(controller: _email, label: 'Email Address', hint: 'Enter your email', keyboardType: TextInputType.emailAddress)),
              _kbAware(
                _AuthField(
                  controller: _password,
                  label: 'Password',
                  hint: '••••••••',
                  obscure: _obscurePassword,
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: kMuted),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),
              if (!_isLogin)
                _kbAware(_AuthField(controller: _referral, label: 'Referral Code (Optional)', hint: 'Enter referral code')),
              // Forgot Password — right aligned, gold (#33); login only.
              // S14: full tap target (default padded target + generous
              // padding) so the link is clearly tappable — the old
              // shrinkWrap style made it a ~22px-high target.
              if (_isLogin)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _forgotPassword,
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: kSpace12, horizontal: kSpace12)),
                    child: Text('Forgot Password?', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 14)),
                  ),
                ),
              const SizedBox(height: kSpace12),
              // Gold gradient CTA (S14: shared ArenaPrimaryButton).
              _GoldPillButton(label: _isLogin ? 'LOGIN' : 'SIGN UP', busy: _busy, onPressed: _emailAuth),
              const SizedBox(height: kSpace20),
              Row(
                children: [
                  Expanded(child: Divider(color: kBorder)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: kSpace12),
                    child: Text('OR', style: TextStyle(color: kMuted, fontWeight: FontWeight.bold, fontSize: 14)),
                  ),
                  Expanded(child: Divider(color: kBorder)),
                ],
              ),
              const SizedBox(height: kSpace20),
              // Google button (S14: card-style ArenaCardButton —
              // item-23 card look, multicolour G, white label).
              _GooglePillButton(busy: _busy, onPressed: _busy ? null : _googleSignIn),
              const SizedBox(height: 28),
              // Sign-up / login toggle (#33 footer).
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(_isLogin ? 'New player? ' : 'Already a player? ', style: kStyleBody.copyWith(color: kMuted)),
                  GestureDetector(
                    onTap: () => setState(() => _isLogin = !_isLogin),
                    child: Text(
                      _isLogin ? 'Create Account' : 'Login',
                      style: TextStyle(color: kGold, fontSize: 15, fontWeight: FontWeight.bold, decoration: TextDecoration.underline, decorationColor: kGold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: kSpace12),
              // A-7 (2026-11-19): NO admin affordance on the login
              // screen. The "Admin Login" button was removed here;
              // admin entry moved to Settings -> "Admin Access"
              // (designated admin UID only, fetchDesignatedAdminUid
              // gate, fail closed).
              // OTP login was removed from the app, so the OTP
              // Verification link is gone too (mockup #33 has no such
              // link) — email/Google login only.
              const SizedBox(height: kSpace24),
            ],
          ),
        ),
          ),
        ],
      ),
      ),
    );
  }
}

/// KEYBOARD FIX (2026-11-20, defense in depth): wraps a form field
/// so that gaining focus scrolls it into view above the keyboard —
/// once right away, once after the keyboard animation (~300 ms) so
/// the post-keyboard layout is covered too. The v2002 black keyboard
/// area was the legacy targetSdk=1 manifest (fixed by the
/// coordinator's build), not this screen — the Stack / ember_bg /
/// _SlashPanels background is pure paint and resizes with the
/// Scaffold body — but this guarantees a focused field can never
/// sit behind the keyboard whatever the device does. The wrapper
/// never takes focus itself (canRequestFocus: false), so traversal
/// is unchanged; it only listens for a descendant field gaining
/// focus. Visuals unchanged.
Widget _kbAware(Widget child) {
  return Builder(
    builder: (ctx) => Focus(
      canRequestFocus: false,
      onFocusChange: (hasFocus) {
        if (!hasFocus) return;
        void reveal() {
          if (ctx.mounted) {
            Scrollable.ensureVisible(
              ctx,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        }

        WidgetsBinding.instance.addPostFrameCallback((_) => reveal());
        Future.delayed(const Duration(milliseconds: 300), reveal);
      },
      child: child,
    ),
  );
}

/// S14 field: thin wrapper over the shared [ArenaTextField] —
/// label above, dark filled field, grey border, gold focus,
/// optional suffix (password visibility toggle). No prefix icon:
/// the shared component has no prefix-icon slot (contract).
class _AuthField extends StatelessWidget {
  const _AuthField({required this.controller, required this.label, required this.hint, this.suffixIcon, this.obscure = false, this.keyboardType});
  final TextEditingController controller;
  final String label;
  final String hint;
  final Widget? suffixIcon;
  final bool obscure;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ArenaTextField(
          controller: controller,
          labelText: label,
          hintText: hint,
          obscureText: obscure,
          suffixIcon: suffixIcon,
          keyboardType: keyboardType,
        ),
        const SizedBox(height: kSpace16),
      ],
    );
  }
}

/// S14 gold CTA: full-width, 56 high, shared
/// [ArenaPrimaryButton] — yellow gradient fill, dark bold label,
/// warm shadow. Busy state (spinner, button disabled) preserved.
class _GoldPillButton extends StatelessWidget {
  const _GoldPillButton({required this.label, required this.onPressed, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ArenaPrimaryButton(
        onPressed: busy ? null : onPressed,
        child: busy
            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0A0A0F)))
            : Text(label, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18, letterSpacing: 1.2)),
      ),
    );
  }
}

/// Mockup #33 silver diagonal slash panels (see the Stack in
/// AuthScreen.build): brushed-metal shards in silver-grey with a
/// brighter edge, top-right and bottom-right corners.
class _SlashPanels extends StatelessWidget {
  const _SlashPanels();
  @override
  Widget build(BuildContext context) => const CustomPaint(painter: _SlashPainter(), size: Size.infinite);
}

class _SlashPainter extends CustomPainter {
  const _SlashPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final fill = Paint()..color = const Color(0xFF9AA3B2).withValues(alpha: 0.16);
    final fillSoft = Paint()..color = const Color(0xFF9AA3B2).withValues(alpha: 0.10);
    final edge = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1.5;
    // Top-right: one wide blade + one thin blade below it.
    final topMain = Path()
      ..moveTo(w * 0.60, 0)
      ..lineTo(w, 0)
      ..lineTo(w, h * 0.17)
      ..lineTo(w * 0.84, h * 0.05)
      ..close();
    canvas.drawPath(topMain, fill);
    canvas.drawLine(Offset(w * 0.84, h * 0.05), Offset(w, h * 0.17), edge);
    final topThin = Path()
      ..moveTo(w * 0.76, h * 0.06)
      ..lineTo(w, h * 0.02)
      ..lineTo(w, h * 0.065)
      ..lineTo(w * 0.83, h * 0.105)
      ..close();
    canvas.drawPath(topThin, fillSoft);
    // Bottom-right: one wide blade rising from the bottom edge.
    final bottomMain = Path()
      ..moveTo(w, h * 0.72)
      ..lineTo(w, h)
      ..lineTo(w * 0.68, h)
      ..lineTo(w * 0.90, h * 0.82)
      ..close();
    canvas.drawPath(bottomMain, fill);
    canvas.drawLine(Offset(w * 0.90, h * 0.82), Offset(w, h * 0.72), edge);
    final bottomThin = Path()
      ..moveTo(w, h * 0.84)
      ..lineTo(w, h * 0.93)
      ..lineTo(w * 0.82, h)
      ..lineTo(w * 0.93, h * 0.90)
      ..close();
    canvas.drawPath(bottomThin, fillSoft);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// S14 Google button: FIX 23 item 29 Part C — the card look
/// ([ArenaCardButton], item-23 cardDecoration), multicolour G +
/// white label. The gold LOGIN pill stays yellow (primary CTA).
class _GooglePillButton extends StatelessWidget {
  const _GooglePillButton({required this.onPressed, this.busy = false});
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ArenaCardButton(
        onPressed: busy ? null : onPressed,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const _GoogleLogo(size: 24),
            const SizedBox(width: kSpace12),
            Text('Continue with Google', style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
      ),
    );
  }
}

/// Multicolour Google "G" drawn with arcs (no asset dependency).
class _GoogleLogo extends StatelessWidget {
  const _GoogleLogo({this.size = 24});
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(size, size), painter: _GoogleGPainter());
  }
}

class _GoogleGPainter extends CustomPainter {
  static const _blue = Color(0xFF4285F4);
  static const _red = Color(0xFFEA4335);
  static const _yellow = Color(0xFFFDC903);
  static const _green = Color(0xFF34A853);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    final stroke = size.width * 0.22;
    Paint arc(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;
    // Angles: 0° = east, clockwise (Flutter y-down). Red top-right,
    // yellow right, green bottom, blue left + the horizontal bar.
    canvas.drawArc(Rect.fromCircle(center: c, radius: r - stroke / 2), _deg(-75), _deg(80), false, arc(_red));
    canvas.drawArc(Rect.fromCircle(center: c, radius: r - stroke / 2), _deg(5), _deg(50), false, arc(_yellow));
    canvas.drawArc(Rect.fromCircle(center: c, radius: r - stroke / 2), _deg(55), _deg(55), false, arc(_green));
    canvas.drawArc(Rect.fromCircle(center: c, radius: r - stroke / 2), _deg(110), _deg(175), false, arc(_blue));
    // Blue bar from the centre to the right edge.
    final barPaint = Paint()..color = _blue;
    final barH = stroke * 0.95;
    canvas.drawRect(Rect.fromLTWH(c.dx, c.dy - barH / 2, r, barH), barPaint);
  }

  double _deg(double d) => d * 3.141592653589793 / 180;

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
