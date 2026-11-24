import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:url_launcher/url_launcher.dart';
import 'firebase_options.dart';
import 'generated_plugin_registrant.dart';
import 'community_service.dart';
import 'screens/login_screen.dart';
import 'services/admin_config.dart';
import 'screens/pro_features.dart';
import 'screens/home_screens.dart';
import 'screens/more_screens.dart';
import 'screens/offline_screen.dart';
import 'screens/wallet_screens.dart';
import 'widgets/arena_ui.dart';
// FIX 23 item 26 REPLACED (2026-11-24): AI Studio cinematic splash.
// Prefixed — lib/arena_hub_splash_screen.dart defines an older
// ArenaHubSplashScreen (standalone, still used by tests) with the
// same class name.
import 'widgets/arena_hub_splash_screen.dart' as cinematic_splash;
// FIX 34 (2026-11-24): first-launch permission sheet (HomeShell
// initState shows it once, after login, over the first Home).
import 'widgets/first_launch_permissions_sheet.dart';
import 'package:app_links/app_links.dart';
import 'services/auth_service.dart';
import 'services/presence_service.dart';
import 'services/sound_service.dart';
import 'services/message_sounds.dart';
import 'services/push_service.dart';
import 'services/supabase_db.dart';
import 'supabase_config.dart';
import 'components/arena_components.dart';
import 'utils.dart';

/// Shell-level accent from app_settings.theme (primary hex), applied to
/// the app bar / bottom nav / splash. Screen-level gold constants are
/// unchanged, so theme application is PARTIAL — stated plainly here and
/// in the port report. A full theme pass would replace kGold everywhere.
final ValueNotifier<Color> appAccent = ValueNotifier<Color>(kGold);

/// Bottom-nav-at-bottom round (2026-11-22): a pushed Profile
/// sub-screen (#17 Activity History, #25 Player Stats) shows the
/// shared [ArenaBottomNav] above the shell. A tab tap there pops
/// back to the shell and posts the wanted tab index here (-1 = no
/// request); HomeShell listens and turns it into a normal _onTap.
/// A plain notifier (same pattern as [appAccent]) — no new route,
/// no HomeShell API change, and the push sites (more_screens.dart)
/// stay untouched.
final ValueNotifier<int> homeTabRequest = ValueNotifier<int>(-1);

/// The shared 6-tab bottom nav (Home / Events / My Matches /
/// Rankings / Community / Profile), extracted verbatim from
/// HomeShell (2026-11-22, bottom-nav-at-bottom round) so pushed
/// Profile sub-screens (#17 Activity History, #25 Player Stats)
/// show the SAME nav instead of a hand-rolled copy: same items,
/// same gold top + bottom indicator bars, same Community
/// pending-request badge, same 10/9pt fixed-scale labels.
/// [currentIndex] is the highlighted tab; [onTap] switches tabs.
/// Pushed pages pass currentIndex 5 (Profile) and an onTap that
/// pops back to the shell and posts the tab on [homeTabRequest].
class ArenaBottomNav extends StatelessWidget {
  const ArenaBottomNav({super.key, required this.currentIndex, required this.onTap});
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    // REDESIGN §5 (F2): SafeArea so the nav never sits under the
    // system gesture bar / covers content at the bottom edge.
    // FIX 23 item 23: floating purple bar (ChatGPT reference) —
    // the shell paints the fill, so the bar itself is transparent.
    return SafeArea(
      top: false,
      child: navBarShell(
        child: Stack(
          children: [
            // v2010 — v2009 screenshot: "My Matches" still clipped to
            // "My Match..." at the user's large text scale (up to
            // 1.4x). The nav labels ignore the text scale (fixed
            // 1.0 here) AND drop to 10/9pt, so all six labels fit
            // their 60dp slots at 360dp width, at any phone font size.
            MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.0)),
              child: BottomNavigationBar(
                currentIndex: currentIndex,
                onTap: onTap,
                type: BottomNavigationBarType.fixed,
                backgroundColor: Colors.transparent,
                // FIX 23 item 23: selected gold, unselected lavender.
                selectedItemColor: kGold,
                unselectedItemColor: kNavUnselected,
              // FIX ROUND 2026-10-28: the default 14pt nav labels + the
              // user's large text scale clipped "Tournaments" to "Tournam...".
              // Explicit small labels fit all six items at any text scale.
              selectedFontSize: 10,
              unselectedFontSize: 9,
              items: [
                BottomNavigationBarItem(
                    icon: const Icon(Icons.home), label: tr('Home', 'Home')),
                BottomNavigationBarItem(
                    icon: const Icon(Icons.calendar_month),
                    label: tr('Events', 'Events')),
                // HOME #37 FIX — crossed swords, not the whistle.
                BottomNavigationBarItem(
                    icon: const CrossedSwordsIcon(),
                    label: tr('My Matches', 'My Matches')),
                BottomNavigationBarItem(
                    icon: const Icon(Icons.leaderboard),
                    label: tr('Rankings', 'Rankings')),
                // COMMUNITY (2026-11-22, restructure): 5th tab is the
                // teams list now — plain icon, no badge. The
                // pending friend-request badge moved to the Profile
                // tab below, because friend requests now live under
                // Profile → Friends.
                BottomNavigationBarItem(
                  icon: const Icon(Icons.people),
                  label: tr('Community', 'Community'),
                ),
                // PROFILE (2026-11-21, user order): LAST tab, right corner.
                // Carries the live pending friend-request count badge
                // (0 = no badge; the stream never throws — it emits 0
                // when logged out, on error, or while migration 035 is
                // unapplied). Moved here 2026-11-22 with the Community
                // restructure: requests live under Profile → Friends.
                BottomNavigationBarItem(
                  icon: StreamBuilder<int>(
                    stream: CommunityService.pendingRequestCountStream,
                    builder: (context, snap) {
                      final count = snap.data ?? 0;
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          const Icon(Icons.person),
                          if (count > 0)
                            Positioned(
                              right: -6,
                              top: -4,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                    color: Colors.red,
                                    borderRadius: BorderRadius.circular(8)),
                                constraints: const BoxConstraints(
                                    minWidth: 14, minHeight: 14),
                                child: Text(count > 9 ? '9+' : '$count',
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold),
                                    textAlign: TextAlign.center),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  label: tr('Profile', 'Profile'),
                ),
              ],
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            top: 0,
            left: navBarTabCenter(context, currentIndex) - 22,
            child: Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                  color: kGold, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            bottom: 3,
            left: navBarTabCenter(context, currentIndex) - 22,
            child: Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                  color: kGold, borderRadius: BorderRadius.circular(2)),
            ),
          ),
        ],
        ),
      ),
    );
  }
}


Color _parseHex(String? hex, Color fallback) {
  if (hex == null || hex.isEmpty) return fallback;
  var h = hex.replaceAll('#', '').trim();
  if (h.length == 6) h = 'FF$h';
  final v = int.tryParse(h, radix: 16);
  return v == null ? fallback : Color(v);
}

/// FULL COMPLETION expansion 2: user text-size preference, read once
/// at startup (changing it needs an app restart — the settings page
/// says so). 1.0 = medium, 0.9 = small, 1.15 = large.
double appTextScale = 1.0;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // DART PLUGIN REGISTRANT (2026-11-20 — Google Sign-In MissingPluginException
  // root cause): the manual pipeline compiles ONLY lib/main.dart, so the
  // Flutter engine's registrant entry point never runs and NO Dart-side
  // plugin registration happened in any shipped build (v2003 kernel: zero
  // references to GoogleSignInAndroid). Every federated plugin then fell back
  // to its LEGACY method channel — which google_sign_in_android 6.x (Pigeon-
  // only) and image_picker_android do not implement, hence 'No implementation
  // found for method init'. Registering FIRST, before SharedPreferences or
  // any other plugin is touched, restores the normal-build behavior.
  GeneratedPluginRegistrant.register();
  try {
    final prefs = await SharedPreferences.getInstance();
    final size = prefs.getString('text_size') ?? 'medium';
    appTextScale = size == 'small'
        ? 0.9
        : size == 'large'
            ? 1.15
            : 1.0;
    // BOARD theme: 'light' persists per-device; default = dark board.
    themeLightNotifier.value =
        (prefs.getString('theme_mode') ?? 'dark') == 'light';
    langUrduNotifier.value = (prefs.getString('app_language') ?? 'en') == 'ur';
  } catch (_) {}
  // STARTUP FIX (2026-11-20, ported from the morning rebuild): the old
  // code awaited Firebase + Supabase BEFORE runApp with no try/catch —
  // if either init threw or hung, runApp never ran and the phone sat on
  // the white launch screen forever (seen on the TECNO CAMON 18P). Now
  // runApp runs FIRST so the splash always appears, and the services
  // initialise in the background; SplashGate waits for them (with
  // timeout) and shows its retry screen if they fail.
  _servicesFuture = _initServices();
  runApp(const ProTournamentApp());
}

/// Background service init, idempotent (safe to retry): each service
/// gets its own try/catch + timeout, so one slow/failing service can
/// never hang the app start. Returns true only when BOTH Firebase
/// and Supabase are ready (login needs Firebase, data needs Supabase).
Future<bool> _initServices() async {
  var ok = true;
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
              options: DefaultFirebaseOptions.currentPlatform)
          .timeout(const Duration(seconds: 15));
    }
  } catch (_) {
    ok = false;
  }
  try {
    var supabaseReady = false;
    try {
      // Throws if Supabase was never initialised.
      Supabase.instance.client;
      supabaseReady = true;
    } catch (_) {
      // BACKEND MOVE (2026-11-22, user order): the new server
      // answers 401 to the anon-key Bearer token, so Authorization
      // goes out EMPTY. This works because supabase-dart's
      // AuthHttpClient only ADDS the header when it is absent
      // (putIfAbsent) — a header already present, even empty, is
      // never overwritten with the Bearer token. The apikey header
      // still flows (putIfAbsent adds it), and Realtime reads the
      // empty header as an empty access token. Do not remove this
      // headers line without re-checking the new server.
      await Supabase.initialize(
              url: kSupabaseUrl,
              publishableKey: kSupabaseAnonKey,
              headers: const {'Authorization': ''},
              // O-2 (2026-11-22): send the Firebase ID token as Bearer
              // on every Supabase call, so 024's Firebase-identity RLS
              // can tell users apart. Must never throw: null = anon
              // (signed out, public tables still readable).
              // getIdToken() already refreshes an expired token — no
              // forced refresh per call (slow nets). NOTE: with the
              // empty-Authorization override above, the token does NOT
              // reach PostgREST (AuthHttpClient only fills an absent
              // Authorization) — REST stays anon until the override is
              // revisited at bridge time; the token still flows to
              // Realtime (customAccessToken).
              accessToken: () async {
                try {
                  return await FirebaseAuth.instance.currentUser?.getIdToken();
                } catch (_) {
                  return null;
                }
              })
          .timeout(const Duration(seconds: 15));
      supabaseReady = true;
    }
    if (!supabaseReady) ok = false;
  } catch (_) {
    ok = false;
  }
  try {
    await SoundService.init().timeout(const Duration(seconds: 5));
  } catch (_) {}
  return ok;
}

Future<bool>? _servicesFuture;

/// REMAINING-ITEMS: deep links open the app and land on the tournament.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

class ProTournamentApp extends StatelessWidget {
  const ProTournamentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: themeLightNotifier,
      builder: (context, light, _) {
        return ValueListenableBuilder<Color>(
          valueListenable: appAccent,
          builder: (context, accent, _) {
            return MaterialApp(
              title: 'ARENA HUB',
              debugShowCheckedModeBanner: false,
              builder: (context, child) {
                final mq = MediaQuery.of(context);
                final scaler = mq.textScaler
                    .clamp(minScaleFactor: 0.8, maxScaleFactor: 1.3);
                // scale(1.0) = the system factor; multiply by the user
                // preference, then clamp to a sane range.
                final scaled =
                    TextScaler.linear(scaler.scale(1.0) * appTextScale)
                        .clamp(minScaleFactor: 0.8, maxScaleFactor: 1.4);
                // FIX 23 items 21+22: the app-wide background image
                // sits behind the whole Navigator (remote URL when the
                // admin set one, else the bundled default artwork).
                // Scaffolds are transparent (see scaffoldBackgroundColor
                // below) so the image shows through; screens that paint
                // their own opaque background (room, ArenaBackground)
                // wire the same layer in themselves.
                return MediaQuery(
                    data: mq.copyWith(textScaler: scaled),
                    child: Stack(
                      children: [
                        const AppBackgroundLayer(),
                        child!,
                      ],
                    ));
              },
              theme: ThemeData(
                // FIX 23 items 21+22: transparent so the app-wide
                // background image (AppBackgroundLayer, in the builder
                // above) shows through every screen. The splash gates
                // keep their own explicit black (they must stay black).
                scaffoldBackgroundColor: Colors.transparent,
                brightness: light ? Brightness.light : Brightness.dark,
                // FIX ROUND 2026-10-28: the old code ALWAYS used
                // ColorScheme.dark, so Material surfaces (dialogs, chips,
                // switches) stayed dark even in light mode. The scheme now
                // follows the toggle, like scaffoldBackgroundColor already did.
                colorScheme: light
                    ? ColorScheme.light(primary: accent, surface: kCard)
                    : ColorScheme.dark(primary: accent, surface: kCard),
                // GOLD (Phase 1 — ARENA HUB): dark AppBar #0A0A0F and dark
                // nav #14141C with gold selected item; light mode keeps
                // its previous values exactly (kBg/kCard/accent).
                // PHASE E (E4): transparent AppBar app-wide — the
                // background poster shows through the header, no black
                // band anywhere. Elevations pinned at 0 so no surface
                // tint creeps back when content scrolls underneath.
                // Per-screen AppBars with their own opaque
                // backgroundColor were fixed at the same time (E4
                // audit); the theme alone would not have fixed them.
                appBarTheme: AppBarTheme(
                    backgroundColor: Colors.transparent,
                    surfaceTintColor: Colors.transparent,
                    elevation: 0,
                    scrolledUnderElevation: 0,
                    foregroundColor: kText),
                // FIX 23 item 23: purple nav (ChatGPT reference) —
                // dark purple bar, gold selected, lavender unselected.
                // (The shell navs paint the fill themselves via
                // navBarShell; this is the fallback for any plain
                // BottomNavigationBar.)
                bottomNavigationBarTheme: BottomNavigationBarThemeData(
                    backgroundColor: kCardPurpleMid,
                    selectedItemColor: kGold,
                    unselectedItemColor: kNavUnselected),
                // FIX 23 item 29: card-style input backstop — any
                // text field that does not specify its own
                // decoration gets the card look (dark purple fill,
                // purple border, radius 22, gold focus). Fields
                // with explicit decorations override per-property;
                // shell-wrapped fields set an outline border with
                // BorderSide.none (invisible, keeps label layout).
                inputDecorationTheme: InputDecorationTheme(
                  filled: true,
                  fillColor: kCardPurpleMid,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: const BorderSide(
                          color: kCardPurpleBorder, width: 1.5)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: const BorderSide(
                          color: kCardPurpleBorder, width: 1.5)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide(color: kGold, width: 1.5)),
                  errorBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide(color: kError, width: 1.5)),
                ),
                // FULL COMPLETION expansion 3: smooth animated transitions
                // on every page push (no new dependency, built-in builders).
                pageTransitionsTheme: const PageTransitionsTheme(builders: {
                  TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
                  TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
                  TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
                }),
              ),
              navigatorKey: appNavigatorKey,
              home: const SplashGate(),
            );
          },
        );
      },
    );
  }
}

/// Splash -> (maintenance | no-internet | settings-error | auth | home).
/// A settings-fetch failure is NOT labelled "no internet": connectivity
/// is checked first, and only a real offline state shows the
/// no-internet screen. Anything else shows a distinct error screen.
/// FIX 30 (2026-11-24): the signed-out screen — the AI Studio
/// LoginScreen with its callbacks wired to the real auth logic
/// ([AuthService], moved verbatim from the old AuthScreen). One helper
/// so the gate and the admin escape build the identical screen.
/// Post-login navigation is unchanged: nothing here navigates — the
/// authStateChanges stream below swaps to HomeShell on sign-in.
LoginScreen _wiredLoginScreen(BuildContext context) {
  return LoginScreen(
    onLoginSubmit: (email, password) =>
        AuthService.signInWithEmail(context, email, password),
    onGoogleLogin: () => AuthService.signInWithGoogle(context),
    onSignupSubmit: (fullName, email, password, referralCode) =>
        AuthService.signUpWithEmail(
      context,
      fullName: fullName,
      email: email,
      password: password,
      referralCode: referralCode,
    ),
    onForgotPassword: (email) => AuthService.sendPasswordReset(context, email),
  );
}

class SplashGate extends StatefulWidget {
  const SplashGate({super.key});
  @override
  State<SplashGate> createState() => _SplashGateState();
}

/// Designated-admin check for the boot gates (maintenance + force
/// update): the admin must never lock himself out of his own app.
/// Fresh admin_config read every time; any failure = NOT admin
/// (fail closed — a non-admin never bypasses on an error). A
/// logged-out user has no UID to check, so no bypass applies.
/// FIX 32 (2026-11-24, admin-panel removal) — KEPT on purpose:
/// the admin still opens the USER app as a player/moderator (rooms,
/// Watch Live moderation, runbook), and the separate admin APK does
/// not change that. The bypass is about the admin's ACCOUNT in the
/// user app, not about the panel — removing it would lock the admin
/// out of his own user app during maintenance or a forced update.
Future<bool> _isDesignatedAdminNow() async {
  try {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    final adminUid = await fetchDesignatedAdminUid();
    return adminUid.isNotEmpty && adminUid == user.uid;
  } catch (_) {
    return false;
  }
}

/// ENTRY GATE (2026-11-20, checklist item 39): Restrict must actually
/// block login. A player the admin restricted (profiles.status =
/// 'blocked', set by AdminDbPeople.restrict) must not reach the app —
/// on a restored session OR a fresh sign-in. Returns 'blocked' or
/// 'home'. Fail-OPEN on any read error / missing profile (a network
/// blip must never lock every user out); only an explicit 'blocked'
/// status blocks. The designated admin is never blocked (same
/// principle as the maintenance bypass — a misclick must not brick
/// the admin's own account).
/// FIX 32 (2026-11-24, admin-panel removal): the 'admin' outcome
/// (admin-mode restore into AdminModeShell) is GONE with the panel
/// — the user app has no admin shell to restore into. The admin
/// lands in the normal HomeShell like everyone else.
Future<String> _entryGate(String uid) async {
  try {
    if (uid.isEmpty) return 'home';
    final adminUid = await fetchDesignatedAdminUid();
    if (adminUid.isNotEmpty && adminUid == uid) {
      return 'home';
    }
    final profile =
        await SupaDb.getProfile(uid).timeout(const Duration(seconds: 10));
    if (SupaDb.strOf(profile['status']).toLowerCase() == 'blocked')
      return 'blocked';
    return 'home';
  } catch (_) {
    return 'home';
  }
}

class _SplashGateState extends State<SplashGate> {
  String _state =
      'loading'; // loading | maintenance | forceUpdate | nointernet | settingsError | done
  String _maintenanceMsg = '';
  String _updateVersion = '';
  String _updateLink = '';
  String _updateError = '';
  // WAVE 4 FIX 1 (P0): UID already profile-ensured this app lifetime.
  String? _ensuredUid;

  // FIX 23 item 26 REPLACED (AI Studio cinematic splash, Sameer
  // 2026-11-24 00:33 — "same lagao"): the gate advances only when
  // BOTH halves are done — the boot outcome (recorded by _finishBoot
  // when _boot completes) AND the 4.5s cinematic (onCompleted in the
  // loading branch). The state machine's DECISIONS are unchanged:
  // same states, same screens, same routing — the loading branch
  // simply shows the cinematic for its full 4.5s minimum. Advancing
  // on the cinematic alone would skip the maintenance / force-update
  // gates when boot is slow, so both halves must agree.
  String? _bootOutcome;
  bool _cinematicDone = false;

  /// Records the boot outcome and advances the gate once the
  /// cinematic has also completed (see _maybeAdvance).
  void _finishBoot(String outcome) {
    _bootOutcome = outcome;
    _maybeAdvance();
  }

  /// Advances the gate to the recorded boot outcome — but only once
  /// both the boot and the cinematic have finished.
  void _maybeAdvance() {
    if (_bootOutcome != null && _cinematicDone && mounted) {
      setState(() => _state = _bootOutcome!);
    }
  }

  /// WAVE 4 FIX 1 (P0): a restored Firebase session bypasses
  /// the login screen (whose callbacks call ensureUserProfile on fresh sign-in), so
  /// a signed-in user could reach HomeShell with NO profiles row —
  /// Join then failed with "Profile not found", Edit Name updated 0
  /// rows, Wallet had no row. One-shot, fire-and-forget ensure per
  /// UID per app lifetime; it never blocks the UI and never throws
  /// (ensureUserProfile itself returns the existing row when one
  /// exists, so this is a no-op for normal users).
  void _ensureProfileOnce(User user) {
    if (_ensuredUid == user.uid) return;
    _ensuredUid = user.uid;
    () async {
      try {
        await SupaDb.ensureUserProfile(user);
      } catch (_) {}
    }();
  }

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // PHASE E (E1): precache the bundled background asset during
    // the ~4.5s splash cinematic, so the poster is in the image
    // cache before Home builds and the first frame after the
    // splash shows the artwork — not the near-black base.
    AppBackgroundLayer.precacheDefaultBackground(context);
  }

  Future<void> _boot() async {
    // FIX 23 item 26: reset both halves of the gate on every
    // (re)boot — retry buttons and the admin sign-in path re-run
    // _boot, and the cinematic must replay with it.
    _bootOutcome = null;
    _cinematicDone = false;
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final conn = await Connectivity().checkConnectivity();
    if (conn.contains(ConnectivityResult.none)) {
      _finishBoot('nointernet');
      return;
    }
    // STARTUP FIX (2026-11-20, ported from the morning rebuild): wait
    // for the background service init (Firebase + Supabase) before
    // touching either of them; if it failed, retry once, then show the
    // retry screen instead of crashing on an uninitialised client.
    bool ready = false;
    try {
      ready = await (_servicesFuture ?? Future.value(false))
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      ready = false;
    }
    if (!ready) {
      try {
        _servicesFuture = _initServices();
        ready = await _servicesFuture!.timeout(const Duration(seconds: 20));
      } catch (_) {
        ready = false;
      }
    }
    if (!ready) {
      _finishBoot('settingsError');
      return;
    }
    try {
      final settings =
          await SupaDb.getAppSettings().timeout(const Duration(seconds: 10));
      // FAIL CLOSED (2026-11-20): getAppSettings swallows errors and
      // returns {} — an empty map means the settings could not be
      // verified (outage or missing row), so maintenance / force
      // state is UNKNOWN. Proceeding would silently skip both gates;
      // show the settings-error screen + Retry instead.
      if (settings.isEmpty) {
        _finishBoot('settingsError');
        return;
      }
      // Theme (partial, shell-level): app_settings.theme.primary hex.
      final theme = SupaDb.asMap(settings['theme']);
      final primary =
          SupaDb.strOf(theme['primary'], SupaDb.strOf(theme['primaryColor']));
      if (primary.isNotEmpty) appAccent.value = _parseHex(primary, kGold);
      // FIX 23 item 22: admin-set app-wide background URL (same fetch).
      // Empty = bundled default artwork (FIX 23 item 21). A new URL
      // arrives on next app start, not in an already-open app.
      SupaDb.appBackgroundUrl.value =
          SupaDb.appBackgroundUrlFromSettings(settings);
      // BOOT GATES (maintenance + force update): both checked here,
      // on FRESH settings, before any routing — so no entry path
      // (auth, home, admin-shell restore) can bypass them. The
      // designated admin bypasses BOTH (fresh check, computed once,
      // only when a gate is actually active) — otherwise the admin
      // locks himself out of his own app.
      final maintenanceOn = settings['maintenanceMode'] == true ||
          settings['maintenance_mode'] == true;
      final upd =
          SupaDb.asMap(settings['updateConfig'] ?? settings['update_config']);
      final updVersion = SupaDb.strOf(upd['version']);
      final forceUpdate = upd['show'] == true &&
          upd['force'] == true &&
          updVersion.isNotEmpty &&
          updVersion != kAppVersion;
      final isAdmin = (maintenanceOn || forceUpdate)
          ? await _isDesignatedAdminNow()
          : false;
      if (maintenanceOn && !isAdmin) {
        _maintenanceMsg = SupaDb.strOf(
            settings['maintenanceMessage'],
            SupaDb.strOf(settings['maintenance_message'],
                'App is under maintenance. Please try again later.'));
        _finishBoot('maintenance');
        return;
      }
      if (forceUpdate && !isAdmin) {
        _updateVersion = updVersion;
        _updateLink = SupaDb.strOf(upd['link']);
        _updateError = '';
        _finishBoot('forceUpdate');
        return;
      }
      PushService.init();
      // Forced-update + popup banner are handled on Home load (see
      // HomePage) and on login (LoginScreen completes into HomeShell,
      // whose HomePage runs the same checks) — single implementation.
      _finishBoot('done');
    } catch (_) {
      // Settings fetch failed while connectivity is present: this is a
      // server/settings problem, NOT "no internet". Offer retry; still
      // allow proceeding to auth so a stale-settings outage does not
      // brick login entirely? No — fail closed with a distinct screen
      // and retry, so the cause is never mislabelled.
      _finishBoot('settingsError');
    }
  }

  /// Update button on the force-update screen. An empty/invalid link
  /// used to silently do nothing — show the reason on the screen.
  Future<void> _openUpdateLink() async {
    if (_updateLink.isEmpty) {
      if (mounted)
        setState(() =>
            _updateError = 'Update link maujood nahi — admin se rabta karein.');
      return;
    }
    final uri = Uri.parse(_updateLink);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      setState(() =>
          _updateError = 'Update link maujood nahi — admin se rabta karein.');
    }
  }

  /// Logged-out admin escape from a gate screen: LoginScreen never
  /// pops itself (routing lives on authStateChanges), so watch for
  /// the sign-in, pop the pushed login screen, then re-run the boot
  /// gate — the designated-admin bypass then applies. Anyone else
  /// just lands back on the same gate screen. The first
  /// authStateChanges emission (current state) is ignored so an
  /// already-logged-in non-admin doesn't flash; the pop is guarded
  /// by canPop so a manual back-press can't double-pop the root.
  /// FIX 30: popUntil(isFirst), not a single pop — LoginScreen can
  /// push SignupScreen on top, and a single pop would leave Login
  /// standing after a signup-completes sign-in.
  Future<void> _adminSignIn() async {
    var first = true;
    var popped = false;
    final sub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (first) {
        first = false;
        return;
      }
      if (user != null &&
          !popped &&
          mounted &&
          Navigator.of(context).canPop()) {
        popped = true;
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => _wiredLoginScreen(context)));
    await sub.cancel();
    if (mounted) {
      setState(() => _state = 'loading');
      _boot();
    }
  }

  /// Shared black/gold shell for the boot-gate screens (maintenance +
  /// force update): app poster background, new logo badge, ARENA HUB
  /// wordmark (admin app_name), then the caller's content. Keeps both
  /// gates looking intentional and premium instead of like error
  /// pages. PHASE E (E23): the old ember texture + crest are gone —
  /// same new-design language as the offline screen (E21).
  Widget _gateScreen(
      {required String heading, required List<Widget> children}) {
    return Scaffold(
      body: Stack(
        children: [
          const AppBackgroundLayer(respectLightMode: false),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 220,
                        height: 220,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              kGold.withValues(alpha: 0.28),
                              kGold.withValues(alpha: 0.0)
                            ],
                          ),
                        ),
                      ),
                      // PHASE E (E23): new logo badge (E18 style),
                      // not the old splash crest.
                      ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Image.asset(
                          'assets/images/arena_hub_logo.png',
                          width: 120,
                          height: 120,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              Icon(Icons.emoji_events, color: kGold, size: 110),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Dynamic wordmark (admin app_name) — was hardcoded ARENA/HUB.
                  const ArenaWordmark(
                      fontSize: 34, textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  Text(heading,
                      style: TextStyle(
                          color: kGold,
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 3)),
                  const SizedBox(height: 16),
                  ...children,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// RESTRICTED-ACCOUNT screen (checklist item 39): shown instead of
  /// the app when _entryGate finds profiles.status == 'blocked'. Uses
  /// the shared _gateScreen shell (same premium black/gold look as
  /// maintenance / force update). The user stays signed in on this
  /// screen (signing out here would bounce to LoginScreen with no
  /// explanation); Sign Out drops them to login, and signing in
  /// again re-runs the gate.
  Widget _blockedScreen() {
    return _gateScreen(
      heading: 'ACCOUNT RESTRICTED',
      children: [
        Icon(Icons.block, color: kGold, size: 56),
        const SizedBox(height: 16),
        Text(
          'Aapka account admin ne restrict kar diya hai.\nApp use karne ke liye admin se rabta karein.',
          style: TextStyle(color: kMuted, fontSize: 15),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: kGold,
                padding: const EdgeInsets.symmetric(vertical: 14)),
            child: const Text('Sign Out',
                style: TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.bold,
                    fontSize: 16)),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_state == 'loading') {
      // FIX 23 item 26 REPLACED (2026-11-24, Sameer: "same lagao"):
      // the AI Studio cinematic splash (4.5s) replaces the interim
      // blurred-poster art. onInitialize is null — the gate does not
      // expose boot progress, so the widget runs its cinematic and
      // reports its own progress. onCompleted marks the cinematic
      // half done; the gate advances once _boot has also finished
      // (see _maybeAdvance) — so the 4.5s minimum is kept without
      // ever skipping the maintenance / force-update gates. The
      // widget builds its own Scaffold; the state machine's
      // decisions are unchanged — same states, same screens, same
      // routing.
      return cinematic_splash.ArenaHubSplashScreen(
        onCompleted: (_) {
          _cinematicDone = true;
          _maybeAdvance();
        },
      );
    }
    if (_state == 'maintenance') {
      return _gateScreen(
        heading: 'UNDER MAINTENANCE',
        children: [
          // The admin's message, prominent, in the animated mockup
          // card — the screen must look intentional and premium,
          // not like an error page.
          MockupCard(
            child: Column(
              children: [
                Icon(Icons.construction, size: 28, color: kGold),
                const SizedBox(height: 10),
                Text(_maintenanceMsg,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kText, fontSize: 15, height: 1.4)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          goldButton(
              label: 'Retry',
              onPressed: () {
                setState(() => _state = 'loading');
                _boot();
              }),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _adminSignIn,
            child: Text('Admin? Sign in',
                style: TextStyle(color: kMuted, fontSize: 13)),
          ),
        ],
      );
    }
    if (_state == 'forceUpdate') {
      return _gateScreen(
        heading: 'UPDATE REQUIRED',
        children: [
          MockupCard(
            child: Column(
              children: [
                Icon(Icons.system_update, size: 28, color: kGold),
                const SizedBox(height: 10),
                Text(
                    'A new version ($_updateVersion) is available. Please update to continue using ARENA HUB.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kText, fontSize: 15, height: 1.4)),
                if (_updateError.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(_updateError,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          goldButton(label: 'Update Now', onPressed: _openUpdateLink),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () {
              setState(() => _state = 'loading');
              _boot();
            },
            child: Text('Check again',
                style: TextStyle(color: kMuted, fontSize: 13)),
          ),
          TextButton(
            onPressed: _adminSignIn,
            child: Text('Admin? Sign in',
                style: TextStyle(color: kMuted, fontSize: 13)),
          ),
        ],
      );
    }
    if (_state == 'nointernet') {
      // P2 #11 (2026-11-21): the boot gate's no-internet branch
      // renders through OfflineScreen (same retry behaviour: back to
      // loading + _boot; same #11 mockup subtitle). Mockup #11 also
      // shows GO BACK: the boot gate has no previous route, so GO
      // BACK exits the app — the same action as the system back
      // button from the root route. PHASE E (E21/E22): the
      // backdrop is the app poster now (not ember), and
      // mid-session loss shows this screen as a root overlay
      // above the Navigator (HomeShell's listener) — the boot
      // gate below is unchanged.
      return OfflineScreen(
        message: 'Check your internet connection and try again.',
        onRetry: () {
          setState(() => _state = 'loading');
          _boot();
        },
        onGoBack: () => SystemNavigator.pop(),
      );
    }
    if (_state == 'settingsError') {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.cloud_off, size: 64, color: kGold),
                const SizedBox(height: 16),
                Text('Could not load app settings',
                    style: TextStyle(
                        color: kText,
                        fontSize: 22,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(
                    'Your connection looks fine, but the app settings could not be loaded. Please retry.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kMuted)),
                const SizedBox(height: 20),
                goldButton(
                    label: 'Retry',
                    onPressed: () {
                      setState(() => _state = 'loading');
                      _boot();
                    }),
              ],
            ),
          ),
        ),
      );
    }
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return Scaffold(
              body: Center(child: CircularProgressIndicator(color: kGold)));
        }
        if (snap.data == null) return _wiredLoginScreen(context);
        // WAVE 4 FIX 1 (P0): ensure the profile for restored
        // sessions too — the login callbacks only run on fresh sign-in.
        // Fire-and-forget; HomeShell renders immediately regardless
        // of the ensure outcome.
        _ensureProfileOnce(snap.data!);
        // FIX 32 (2026-11-24, admin-panel removal): the admin-mode
        // restore into AdminModeShell is GONE with the panel — every
        // signed-in user lands in HomeShell. The entry gate below
        // now only enforces the Restrict check.
        final uid = snap.data!.uid;
        // ENTRY GATE (2026-11-20, checklist item 39): _entryGate
        // runs the Restrict check — a 'blocked' profile lands on
        // the blocked screen, never in the app, on restored
        // sessions and fresh sign-ins alike.
        return FutureBuilder<String>(
          future: _entryGate(uid),
          builder: (context, gateSnap) {
            // While the gate is checking, show a loader — NOT
            // HomeShell — so a blocked user never flashes the app
            // before the blocked screen.
            if (gateSnap.connectionState == ConnectionState.waiting) {
              return Scaffold(
                  body: Center(child: CircularProgressIndicator(color: kGold)));
            }
            if (gateSnap.data == 'blocked') return _blockedScreen();
            // HOME FIX (2026-11-21, v2007 — user phone test): the
            // shell is keyed by uid, so switching accounts (user A
            // -> user B with NO null in between, e.g. Google
            // sign-in replacing the Firebase user) REMOUNTS
            // HomeShell + HomePage instead of reusing the old
            // shell's state with the OLD uid's streams — the old
            // unkeyed shell showed the new account an empty Home
            // until a pull-to-refresh. Same uid -> same key -> no
            // remount (token refreshes are safe). The blocked
            // branch returns a different widget above; untouched.
            return HomeShell(key: ValueKey(uid));
          },
        );
      },
    );
  }
}

/// Bottom-nav shell (Phase 2, locked 5-tab structure): Home,
/// Events, My Matches, Rankings, Profile. Wallet + Earnings live
/// under Profile (and via the AppBar wallet chip), not in the nav.
/// PHASE E (E22): the live online/offline listener shows the FULL
/// offline screen as a root overlay the moment connectivity is
/// lost (and removes it the moment it returns) — the old red
/// banner is gone (redundant with the full screen). The overlay
/// sits ABOVE the Navigator, so pushed/detail screens are covered
/// too and NOTHING is popped — when the network returns, the user
/// is exactly where they were. Maintenance is re-checked on EVERY
/// section change, not only boot.
/// Presence heartbeat re-fires on foreground/resume.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.connectivityStream});

  /// Test seam: the connectivity-change stream. Production passes
  /// nothing and the shell subscribes to
  /// `Connectivity().onConnectivityChanged`; tests inject a
  /// controlled stream to simulate loss/restore.
  final Stream<List<ConnectivityResult>>? connectivityStream;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;
  int _homeNonce = 0;
  bool _offline = false;
  bool _maintenanceDialogOpen = false;
  bool _exitDialogOpen = false;
  // FIX 21 (2026-11-21): guard flag so rapid BACK presses never stack
  // exit dialogs — the old double-back timestamp (_lastBackPress) is
  // gone with the toast it served.
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  // PHASE E (E22): the full-screen offline overlay (root Overlay,
  // above the Navigator). Null when online / not yet shown.
  OverlayEntry? _offlineEntry;
  // ROUND 6 (profile grey dot): presence used to heartbeat ONLY on
  // login / shell init / resume / Detail entry, with NO timer while
  // the app stays in the foreground. presenceIsOnline needs a
  // last_seen within 2 minutes, so after ~2 minutes of just using
  // the app the dot flipped GREY even though the user was active
  // (and switching to the Profile tab never re-heartbeated). A
  // 60-second foreground timer keeps last_seen fresh while the app
  // is open; it is cancelled on dispose, and pause/detached still
  // write offline immediately (below).
  Timer? _heartbeatTimer;
  // WAVE 4 FIX 5: the AppBar wallet chip + bell streams are created
  // ONCE (a fresh streamList/stream call per build would resubscribe
  // + refetch on every shell setState, i.e. every tab switch).
  late final Stream<Map<String, dynamic>> _profileStream;
  late final Stream<int> _unreadStream;
  // MESSAGE SOUNDS (Sameer's picks, 2026-11-22): the notification
  // bell (notif_02) plays only when the unread count RISES from a
  // known previous value — null = first emission, never a beep.
  // Wired ONLY here (the shell bell); the second bell builder in
  // home_screens.dart must stay silent or the sound double-plays.
  int? _lastUnread;
  // WAVE 4 FIX 5: the six tab pages are built ONCE and kept in an
  // IndexedStack — a fresh pages list per build would hand every
  // child a new widget instance, re-running State.build (and its
  // StreamBuilders) on every tab switch. Only the Home re-tap nonce
  // rebuilds the list (to remount HomePage with a new key).
  List<Widget>? _pages;
  int _pagesNonce = -1;

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    _profileStream = SupaDb.streamProfile(uid);
    _unreadStream = SupaDb.streamUnreadCount(uid);
    WidgetsBinding.instance.addObserver(this);
    // USER ORDER 2026-11-01: Guided Tour REMOVED entirely — no
    // first-run tour page, no tour tile anywhere in the app.
    // FIX 34 (2026-11-24): first-launch PERMISSION flow — a fresh
    // install never asked for ANY permission (no first-run flow
    // existed; the only requests live behind the room mic-take
    // gate). One post-frame check: the sheet shows once, after
    // login, over Home; a denial never blocks anything and the
    // flag keeps it from ever re-appearing. Fire-and-forget —
    // the helper swallows its own errors, and the flag check
    // makes the account-switch remount (uid-keyed shell) a no-op.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(maybeShowFirstLaunchPermissions(context));
    });
    PresenceService.goOnline();
    _listenDeepLinks();
    // Bottom-nav-at-bottom round (2026-11-22): a pushed Profile
    // sub-screen posts its tab tap on homeTabRequest (see above);
    // drain any pending request from before this shell mounted.
    homeTabRequest.addListener(_onTabRequest);
    _onTabRequest();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) PresenceService.goOnline();
    });
    _connSub = (widget.connectivityStream ??
            Connectivity().onConnectivityChanged)
        .listen((results) {
      final off = results.contains(ConnectivityResult.none);
      if (mounted) _setOffline(off);
      if (!off) PresenceService.goOnline();
    });
  }

  // PHASE E (E22): single place that flips the offline state —
  // the listener AND the overlay's RETRY button both go through
  // here, so the overlay and the flag can never disagree.
  void _setOffline(bool off) {
    if (off == _offline) return;
    setState(() => _offline = off);
    if (off) {
      _showOfflineOverlay();
    } else {
      _hideOfflineOverlay();
    }
  }

  void _showOfflineOverlay() {
    if (_offlineEntry != null || !mounted) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = OverlayEntry(
      builder: (overlayCtx) => PopScope(
        // The app is blocked while offline (same as the
        // maintenance screen) — back must not pop the user's
        // screen underneath the overlay.
        canPop: false,
        child: OfflineScreen(
          onRetry: _refreshConnectivity,
          // No GO BACK mid-session: there is nowhere to go back
          // to — the app sits frozen underneath, and the default
          // go-back (pop route / exit app) would destroy state.
          showGoBack: false,
        ),
      ),
    );
    _offlineEntry = entry;
    overlay.insert(entry);
  }

  void _hideOfflineOverlay() {
    final entry = _offlineEntry;
    _offlineEntry = null;
    entry?.remove();
  }

  // The overlay RETRY button: re-check connectivity right now
  // (the stream only fires on CHANGE). Online -> the overlay
  // drops via _setOffline; still offline -> say so, stay put.
  Future<void> _refreshConnectivity() async {
    List<ConnectivityResult> results;
    try {
      results = await Connectivity().checkConnectivity();
    } catch (_) {
      results = const [ConnectivityResult.none];
    }
    if (!mounted) return;
    final off = results.contains(ConnectivityResult.none);
    _setOffline(off);
    if (off && mounted) {
      toast(context, 'Abhi bhi offline — internet check karein.');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      PresenceService.goOnline();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Explicit offline on background/close: previously NOTHING wrote
      // offline here, so a backgrounded/killed user stayed green until
      // the staleness window expired. Resume (above) re-heartbeats, so
      // a brief switch away self-heals on return. A force-kill may
      // skip this callback entirely — the 2-minute staleness rule is
      // the backstop for that case.
      PresenceService.goOffline();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    homeTabRequest.removeListener(_onTabRequest);
    _heartbeatTimer?.cancel();
    _connSub?.cancel();
    _hideOfflineOverlay();
    super.dispose();
  }

  // Bottom-nav-at-bottom round (2026-11-22): turns a pushed
  // Profile sub-screen's tab tap (posted on homeTabRequest) into a
  // normal _onTap — same maintenance check, heartbeat and Home
  // re-tap remount as tapping the nav in the shell itself.
  void _onTabRequest() {
    final i = homeTabRequest.value;
    if (i < 0 || i > 5) return;
    homeTabRequest.value = -1;
    if (mounted) _onTap(i);
  }

  // REMAINING-ITEMS: protournament://tournament/<id> (WhatsApp share
  // sends exactly this). Opens TournamentDetailPage directly; an
  // unknown id shows a plain toast, never a crash or fake detail.
  Future<void> _openDeepLink(Uri uri) async {
    String? id;
    if (uri.scheme == 'protournament' &&
        uri.host == 'tournament' &&
        uri.pathSegments.isNotEmpty) id = uri.pathSegments.first;
    if (id == null || id.isEmpty) return;
    try {
      final rows = await SupaDb.getList('tournaments', eqCol: 'id', eqVal: id);
      if (rows.isEmpty) {
        if (mounted)
          toast(context, 'Tournament nahi mila (link purana ho sakta hai).');
        return;
      }
      if (mounted)
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => TournamentDetailPage(tournament: rows.first)));
    } catch (_) {
      if (mounted)
        toast(context, 'Link kholne me masla hua, dobara koshish karen.');
    }
  }

  void _listenDeepLinks() {
    try {
      final links = AppLinks();
      links.getInitialLink().then((uri) {
        if (uri != null && mounted) _openDeepLink(uri);
      });
      links.uriLinkStream.listen((uri) {
        if (mounted) _openDeepLink(uri);
      }, onError: (_) {});
    } catch (_) {}
  }

  // WAVE 4 FIX 5: the switch itself never awaits a network call —
  // the tab changes instantly and the maintenance check runs in the
  // background (dialog after the switch if maintenance is on),
  // instead of blocking navigation on isMaintenanceOn().
  void _onTap(int i) {
    // Tapping Home again remounts HomePage so forced-update + popup
    // banner re-run on every Home load (not only first mount).
    if (i == _index && i != 0) return;
    if (i == 0 && _index == 0) {
      setState(() => _homeNonce++);
      return;
    }
    // Switching tabs (Profile included) re-heartbeats, so a
    // tab opened after minutes in the app never shows a stale dot.
    PresenceService.goOnline();
    setState(() => _index = i);
    // Maintenance checked on section change, not only boot — now
    // in the background so a slow connection never stalls the switch.
    // The dialog is a HARD STOP (barrierDismissible: false +
    // PopScope(canPop: false)): the old OK dialog could be dismissed
    // by BACK / outside-tap and the app kept working through
    // maintenance. The designated admin never sees it. A guard flag
    // stops stacked dialogs on rapid tab switches.
    () async {
      if (_maintenanceDialogOpen) return;
      final settings = await SupaDb.getAppSettings();
      final on = settings['maintenanceMode'] == true ||
          settings['maintenance_mode'] == true;
      if (!on) return;
      if (await _isDesignatedAdminNow()) return;
      if (!mounted) return;
      _maintenanceDialogOpen = true;
      final msg = SupaDb.strOf(
          settings['maintenanceMessage'],
          SupaDb.strOf(settings['maintenance_message'],
              'App is under maintenance. Please try again later.'));
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dctx) => PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: kCardPurpleMid,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
            title: Row(children: [
              Icon(Icons.construction, color: kGold, size: 22),
              const SizedBox(width: 8),
              Text('Under Maintenance', style: TextStyle(color: kText))
            ]),
            content: Text(msg, style: TextStyle(color: kMuted)),
            actions: [
              TextButton(
                onPressed: () async {
                  // Retry: re-check fresh — closes only when
                  // maintenance is actually off.
                  if (!await SupaDb.isMaintenanceOn()) {
                    if (dctx.mounted) Navigator.pop(dctx);
                  } else if (dctx.mounted) {
                    toast(dctx, 'Abhi bhi maintenance chal rahi hai.');
                  }
                },
                child: Text('Retry', style: TextStyle(color: kGold)),
              ),
            ],
          ),
        ),
      );
      _maintenanceDialogOpen = false;
    }();
  }

  // FIX 21 (2026-11-21): shows the shared exit-confirm dialog
  // (utils.dart) and exits only on YES. Guard flag stops stacked
  // dialogs on rapid BACK presses.
  Future<void> _confirmExit() async {
    if (_exitDialogOpen) return;
    _exitDialogOpen = true;
    final yes = await showExitConfirmDialog(context);
    _exitDialogOpen = false;
    if (yes && mounted) SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    // WAVE 4 FIX 5: pages built once (see _pages above); rebuilt only
    // when the Home re-tap nonce changes.
    if (_pages == null || _pagesNonce != _homeNonce) {
      _pages = <Widget>[
        HomePage(key: ValueKey(_homeNonce)),
        const TournamentsPage(),
        const MyMatchesPage(),
        const LeaderboardPage(embedded: true),
        // COMMUNITY (2026-11-22, user order — restructure): the
        // 5th tab is the teams list (TeamsPage), NOT the old
        // friends hub — with many friends the hub pushed the chat
        // off the bottom. Friends/Requests/Messages now live under
        // Profile → Friends; communities under the "Browse
        // Communities" button on this page. `embedded` hides the
        // page's own bottom nav (the shell draws it).
        TeamsPage(uid: uid, embedded: true),
        // PROFILE (2026-11-21, user order): LAST tab, right corner.
        ProfilePage(uid: uid),
      ];
      _pagesNonce = _homeNonce;
    }
    final titles = [
      tr('ARENA HUB', 'ARENA HUB'),
      tr('Events', 'Events'),
      tr('My Matches', 'My Matches'),
      tr('Rankings', 'Rankings'),
      tr('Community', 'Community'),
      tr('Profile', 'Profile')
    ];
    return PopScope(
      // FIX 21 (2026-11-21, user order): Android BACK on the root
      // Home tab shows the exit-confirm card dialog ("Do you want
      // to exit the application?" — YES / NO). The old double-back
      // toast ("Exit karne ke liye dobara dabao") is gone. Pushed
      // routes above HomeShell pop normally (this PopScope only
      // governs the shell route itself); on any other tab, BACK
      // goes Home first.
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_index != 0) {
          setState(() => _index = 0);
          return;
        }
        _confirmExit();
      },
      child: Scaffold(
        // Wave 4 Home design-match (#37): the Home tab renders its own
        // mockup header (crown logo + bell + avatar) inside HomePage,
        // so the global AppBar (title + wallet chip + bell) is hidden
        // on the Home tab ONLY. WAVE 4 FIX 5: same for the My Matches
        // tab — MyMatchesPage renders its own in-tab "MY MATCHES"
        // header, and the global one duplicated it. Audit P2-12: same
        // for the Profile tab (index 5) — ProfilePage renders its own
        // centered PROFILE + gear header, and the global one duplicated
        // it. Other tabs keep it unchanged.
        appBar: (_index == 0 || _index == 2 || _index == 5)
            ? null
            : AppBar(
                // FIX ROUND 2026-10-28: FittedBox title (never "Pro Tourname..."
                // with a stray dot) + a slimmer wallet chip, so the title keeps
                // its full width even with the chip + bell in the actions row.
                title: boardAppBarTitle(titles[_index]),
                actions: [
                  // Wallet chip: the SAME walletTotal() formula WalletPage
                  // uses (deposit + winning + bonus), tap -> Wallet page.
                  // Phase 2: Wallet left the bottom nav (Wallet + Earnings
                  // now live under Profile); the chip pushes WalletPage.
                  StreamBuilder<Map<String, dynamic>>(
                    stream: _profileStream,
                    builder: (context, snap) {
                      final p = snap.data ?? {};
                      final loaded = p.isNotEmpty;
                      final total = walletTotal(p);
                      return InkWell(
                        onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => Scaffold(
                                    appBar: AppBar(
                                        title: boardAppBarTitle('Wallet')),
                                    body: WalletPage(uid: uid)))),
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 5),
                          // GOLD chip (Phase 1): border, flat — no glow,
                          // gold balance text; shape/padding unchanged.
                          decoration: BoxDecoration(
                              color: kCard,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: kBorder, width: 1)),
                          child: Row(children: [
                            // WALLET ICON (2026-11-22): 14 -> 18 — Sameer:
                            // header chip ka wallet icon thora chhota
                            // dikh raha tha; sirf size bara, baaki waisa hi.
                            Icon(Icons.account_balance_wallet,
                                color: kGold, size: 18),
                            const SizedBox(width: 3),
                            Text(loaded ? 'Rs ${total.floor()}' : '—',
                                style: TextStyle(
                                    color: kGold,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12)),
                          ]),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 4),
                  // Bell with unread badge, capped at 9+.
                  StreamBuilder<int>(
                    stream: _unreadStream,
                    builder: (context, snap) {
                      final unread = snap.data ?? 0;
                      // MESSAGE SOUNDS: unread count ROSE -> a new
                      // general notification arrived -> the bell
                      // (notif_02). First emission / drops never
                      // beep (see MessageSounds).
                      if (MessageSounds.shouldPlayNotificationSound(
                          previousUnread: _lastUnread,
                          currentUnread: unread)) {
                        MessageSounds.play(MessageSound.notification);
                      }
                      _lastUnread = unread;
                      final label = unread > 9 ? '9+' : '$unread';
                      return Stack(
                        children: [
                          IconButton(
                            icon: Icon(Icons.notifications, color: kGold),
                            onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) =>
                                        NotificationsPage(uid: uid))),
                          ),
                          if (unread > 0)
                            Positioned(
                              right: 6,
                              top: 6,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                    color: Colors.redAccent,
                                    borderRadius: BorderRadius.circular(10)),
                                child: Text(label,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold)),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
        body: Column(
          children: [
            // PHASE E (E22): the red offline banner is GONE — the
            // full-screen overlay (see _setOffline) covers the
            // same moment, so the banner would be redundant.
            // WAVE 4 FIX 5: IndexedStack keeps all six tab States
            // alive across switches — no dispose/re-initState, no
            // per-switch refetch. The pages list itself is built once
            // (see above), so a switch only changes the visible index.
            Expanded(child: IndexedStack(index: _index, children: _pages!)),
          ],
        ),
        // HOME #37 FIX — gold underline bar under the ACTIVE tab
        // (mockup #37: a gold bar under "Home", measured ~52dp wide
        // x ~4dp tall). BottomNavigationBar has no indicator slot, so
        // the bar is an AnimatedPositioned overlay that slides to the
        // active sixth of the width.
        // J-detail-fix1: mockups #3 (My Team) and #35/#36 also show a
        // gold segment at the TOP EDGE of the nav bar above the active
        // tab — a second AnimatedPositioned at top: 0. The bottom
        // underline is kept; navigation behaviour is unchanged.
        bottomNavigationBar: ArenaBottomNav(currentIndex: _index, onTap: _onTap),
      ),
    );
  }
}
