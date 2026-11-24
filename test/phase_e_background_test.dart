// PHASE E — v2023 phone-feedback visual fixes (E1–E27, v2024 re-gate).
// Sameer's phone verdicts, 2026-11-24 06:15–06:52 PKT:
//  E1  background loads late — precache the bundled asset at the splash.
//  E2  cards hide the poster design — shared fill 0.48 -> 0.30, blur 12 -> 6.
//  E3  background too dim — scrim 0.55 -> 0.35.
//  E4  transparent headers app-wide — theme + every explicit AppBar.
//  E5  Home's opaque hBg wrapper — gone.
//  E6  Profile's opaque black layer — gone.
//  E7  Community pills truncate — ONE translucent strip, full names.
//  E8  Rankings — covered by E2+E4, no separate change.
//  E9  My Matches title under the status bar — SafeArea + 28dp floor.
//  E10 Watch Live black — transparent header + comments surface + composer.
//  E11 room host card under the status bar — SafeArea.
//  E12 room background half black — double background layer removed.
//  E13 chat bubbles too fat — compact density everywhere.
//  E14 stale "chat history cleared" notice still shows — filter extended.
//  E15 sidebar overlaps the chat box — rail ends above the panel edge.
//  E16 seats 4-6 cut off — seat compaction (~28dp headroom).
//  E17 Music + RJ Panel taps dead — wiring verified, error visibility added.
//  E18 Home header: two round icons — full logo badge, no ClipOval.
//  E19 Login "Player" Y: white sliver — height 1.1 + gold base color.
//  E20 Check-in button text too big — short label 'Close check-in'.
//  E21 Offline screen old design — poster + new badge.
//  E22 Offline page must appear at once — root overlay on loss, auto-dismiss.
//  E23 old-design audit — maintenance gate + About wordmark fixed.
//  E24 buttons like cards (CORRECTED 06:52): REST = card fill (never
//      black), SELECTED = solid gold fill ("click pe yellow hona chahiye").
//  E25 invites stats card yellow — gold border + gold glow removed.
//  E26 background foggy patches + seam — Lottie matte edges; procedural.
//  E27 smoke realistic — procedural FBM smoke replaces the Lottie.
// Update 6/11 (Sameer, pakka hukm): ONE transparency number everywhere —
// every card surface reads the shared kCardFillOpacity token.
// No APK built; the real verdict is Sameer's phone on v2024.

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:protournament_user/community_service.dart';
import 'package:protournament_user/components/arena_chat.dart';
import 'package:protournament_user/components/arena_components.dart';
import 'package:protournament_user/main.dart';
import 'package:protournament_user/models/voice_room_models.dart';
import 'package:protournament_user/platform/competition/checkin_page.dart'
    as checkin;
import 'package:protournament_user/platform/core/roles.dart';
import 'package:protournament_user/screens/arena_voice_room_screen.dart';
import 'package:protournament_user/screens/communities_screens.dart';
import 'package:protournament_user/screens/home_screens.dart';
import 'package:protournament_user/screens/offline_screen.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/screens/room_screen.dart';
import 'package:protournament_user/screens/watch_live_screen.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';
import 'package:protournament_user/widgets/smoke_canvas_painter.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'audio_test_helpers.dart';

// ---------- fake Firebase (copied pattern from watch_live_test.dart) ----------

class _FakeAppPlatform extends FirebaseAppPlatform {
  _FakeAppPlatform(super.name, super.options);
}

class _FakeCorePlatform extends FirebasePlatform {
  FirebaseAppPlatform? _app;

  @override
  Future<FirebaseAppPlatform> initializeApp(
      {String? name, FirebaseOptions? options}) async {
    _app = _FakeAppPlatform(
      name ?? defaultFirebaseAppName,
      options ??
          const FirebaseOptions(
              apiKey: 'test',
              appId: '1:1:android:1',
              messagingSenderId: '1',
              projectId: 'test'),
    );
    return _app!;
  }

  @override
  FirebaseAppPlatform app([String name = defaultFirebaseAppName]) {
    final a = _app;
    if (a == null) throw StateError('Firebase.initializeApp() was not called');
    return a;
  }
}

class _FakeMultiFactor extends MultiFactorPlatform {
  _FakeMultiFactor(super.auth);
}

class _FakeUser extends UserPlatform {
  _FakeUser(super.auth, super.multiFactor, super.user);
}

class _FakeAuthPlatform extends FirebaseAuthPlatform {
  _FakeAuthPlatform({super.appInstance});

  UserPlatform? _user;

  @override
  FirebaseAuthPlatform delegateFor({required FirebaseApp app}) =>
      _FakeAuthPlatform(appInstance: app);

  @override
  FirebaseAuthPlatform setInitialValues(
      {PigeonUserDetails? currentUser, String? languageCode}) {
    final uid = currentUser?.userInfo.uid ?? 'test-uid';
    _user = _FakeUser(
      this,
      _FakeMultiFactor(this),
      PigeonUserDetails(
          userInfo: PigeonUserInfo(
              uid: uid, isAnonymous: false, isEmailVerified: true),
          providerData: []),
    );
    return this;
  }

  @override
  UserPlatform? get currentUser => _user;

  @override
  set currentUser(UserPlatform? user) => _user = user;
}

// ---------- fake WebView platform (copied pattern from watch_live_test.dart) ----------

class _FakeWebViewPlatform extends WebViewPlatform {
  static String? lastLoadedUrl;
  static String? lastLoadedHtml;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) =>
      _FakeWebViewController.implementation(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) =>
      _FakeNavigationDelegate.implementation(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) =>
      _FakeWebViewWidget.implementation(params);
}

class _FakeWebViewController extends PlatformWebViewController {
  _FakeWebViewController.implementation(super.params)
      : super.implementation();

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    _FakeWebViewPlatform.lastLoadedUrl = params.uri.toString();
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    _FakeWebViewPlatform.lastLoadedHtml = html;
  }

  @override
  Future<void> setUserAgent(String? userAgent) async {}

  @override
  Future<void> addJavaScriptChannel(
      JavaScriptChannelParams params) async {}

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate.implementation(super.params)
      : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget.implementation(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Colors.black);
}

// Real Roboto so 360px fit tests measure what a real phone measures —
// the fallback test font is ~2x wider and fakes overflows (same
// approach as watch_live_test.dart / fix22_watch_engagement_test.dart).
Future<void> _loadRoboto() async {
  final home = Platform.environment['HOME'] ?? '';
  final dir = '$home/flutter/bin/cache/artifacts/material_fonts';
  final loader = FontLoader('Roboto');
  for (final file in [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Black.ttf',
  ]) {
    final bytes = await File('$dir/$file').readAsBytes();
    loader.addFont(Future.value(bytes.buffer.asByteData()));
  }
  await loader.load();
}

String _region(String src, String start, String end) {
  final s = src.indexOf(start);
  if (s < 0) return '';
  final e = src.indexOf(end, s + start.length);
  if (e < 0) return '';
  return src.substring(s, e);
}

/// Every AppBar( block in [code] (full-line comments already stripped)
/// that sets a backgroundColor other than Colors.transparent, as
/// "line: value" entries. AppBarTheme is excluded (checked separately).
List<String> _opaqueAppBars(String code) {
  final lines = code.split('\n');
  final bad = <String>[];
  final appBar = RegExp(r'\bAppBar\(');
  for (var i = 0; i < lines.length; i++) {
    if (!appBar.hasMatch(lines[i])) continue;
    if (lines[i].contains('AppBarTheme')) continue;
    var depth = 0;
    for (var j = i; j < i + 15 && j < lines.length; j++) {
      final bg = lines[j].indexOf('backgroundColor:');
      if (bg >= 0) {
        final value = lines[j].substring(bg).trim();
        if (!value.startsWith('backgroundColor: Colors.transparent')) {
          bad.add('${j + 1}: $value');
        }
        break;
      }
      depth += '('.allMatches(lines[j]).length;
      depth -= ')'.allMatches(lines[j]).length;
      if (j > i && depth <= 0) break;
    }
  }
  return bad;
}

// ---------- room mount helpers (E11–E17, E28, E29) ----------
// Fix72 mount pattern: CommunityDetailPage unlocked at 360x800,
// real Roboto, fake Firebase (current user switched per test via
// the fake auth platform), SupaDb.testFixtures.

Map<String, dynamic> _roomCommunity({String creatorUid = 'test-uid'}) => {
      'id': 'comm-1',
      'name': 'TEST COMMUNITY',
      'description': 'Test community',
      'created_by_uid': creatorUid,
      'voice_enabled': true,
      'isMember': true,
      'myRole': 'creator',
      'memberCount': 1,
    };

Map<String, List<Map<String, dynamic>>> _roomFixtures({
  required Map<String, dynamic> community,
  String adminUid = 'test-uid',
  String memberUid = 'test-uid',
  String memberRole = 'creator',
  List<Map<String, dynamic>> chatMessages = const [],
}) =>
    {
      'communities': [community],
      'community_members': [
        {
          'community_id': community['id'],
          'firebase_uid': memberUid,
          'role': memberRole,
        }
      ],
      'community_voice_requests': [],
      'profiles': [
        {
          'firebase_uid': memberUid,
          'display_name': 'Tester',
          'level': 1,
        }
      ],
      'admin_config': [
        {'id': 1, 'admin_firebase_uid': adminUid}
      ],
      'chat_messages': chatMessages,
      'presence': [],
    };

Future<void> _settleRoom(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

/// Mounts the embedded community room as [uid] (switches the fake
/// auth current user, so the E28 role gates read the right uid).
Future<void> _mountRoom(
  WidgetTester tester, {
  Map<String, dynamic>? community,
  String adminUid = 'test-uid',
  String uid = 'test-uid',
  String memberRole = 'creator',
  List<Map<String, dynamic>> chatMessages = const [],
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final platform = FirebaseAuthPlatform.instance as _FakeAuthPlatform;
  platform.currentUser = _FakeUser(
    platform,
    _FakeMultiFactor(platform),
    PigeonUserDetails(
      userInfo: PigeonUserInfo(
          uid: uid, isAnonymous: false, isEmailVerified: true),
      providerData: [],
    ),
  );
  final comm = community ?? _roomCommunity();
  SupaDb.testFixtures = _roomFixtures(
    community: comm,
    adminUid: adminUid,
    memberUid: uid,
    memberRole: memberRole,
    chatMessages: chatMessages,
  );
  await tester.pumpWidget(MaterialApp(
    home: CommunityDetailPage(
      uid: uid,
      communityId: 'comm-1',
      community: comm,
    ),
  ));
  await _settleRoom(tester);
}

/// Drains the test exception, allowing ONLY the known pre-existing
/// 17px RJ-console-sheet overflow (untouched by Phase E, seen in
/// the E17 probe) — anything else fails the test.
void _expectNoExceptionExceptKnownRjOverflow(WidgetTester tester) {
  final e = tester.takeException();
  if (e == null) return;
  expect(
    e.toString(),
    contains('overflowed by 17 pixels on the right'),
    reason: 'unexpected exception: $e',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('E2+E3 — shared tokens are the NEW values (unit)', () {
    test('card fill 0.30, blur 6.0, scrim 0.35', () {
      expect(kCardFillOpacity, 0.30);
      expect(kCardBlurSigma, 6.0);
      expect(AppBackgroundLayer.scrimOpacity, 0.35);
    });

    test('card fill + frame decorations read the shared tokens', () {
      final fill = cardFillDecoration();
      final gradient = fill.gradient as LinearGradient;
      expect(
          gradient.colors,
          [
            kCardPurpleTop.withValues(alpha: kCardFillOpacity),
            kCardPurpleMid.withValues(alpha: kCardFillOpacity),
            kCardPurpleBottom.withValues(alpha: kCardFillOpacity),
          ]);
      final full = cardDecoration();
      final fullGradient = full.gradient as LinearGradient;
      expect(fullGradient.colors, gradient.colors);
      // The nav shell shares the same fill (update 6: nav + cards equal).
      final shell = navBarShell(child: const SizedBox());
      expect(shell, isA<Container>());
      final shellDeco = (shell as Container).decoration as BoxDecoration;
      expect((shellDeco.gradient as LinearGradient).colors, gradient.colors);
    });
  });

  group('E1 — bundled asset precached before Home builds', () {
    test('precache helper exists + is called at the splash gate', () {
      final ui = codeOnly(requireProjectFile('lib/widgets/arena_ui.dart'));
      expect(ui, contains('precacheDefaultBackground'));
      expect(ui, contains('precacheImage(const AssetImage(defaultAsset)'));
      expect(ui, contains('AppBackgroundLayer.precacheDefaultBackground(context)'));
      final main = codeOnly(requireProjectFile('lib/main.dart'));
      final gate = _region(main, 'class _SplashGateState', 'Future<void> _boot()');
      expect(gate, isNotEmpty);
      expect(gate, contains('precacheDefaultBackground(context)'));
    });

    testWidgets('bundled asset lands in the image cache on first mount',
        (tester) async {
      SupaDb.appBackgroundUrl.value = '';
      themeLightNotifier.value = false;
      addTearDown(() {
        SupaDb.appBackgroundUrl.value = '';
        themeLightNotifier.value = false;
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                AppBackgroundLayer(),
                Center(child: Text('content')),
              ],
            ),
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      // The bundled poster is cached (first paint after the splash
      // shows the artwork, not the near-black base).
      final key = await const AssetImage(AppBackgroundLayer.defaultAsset)
          .obtainKey(const ImageConfiguration());
      expect(imageCache.containsKey(key), isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('E4 — transparent headers app-wide (source scan)', () {
    test('AppBarTheme background is transparent', () {
      final main = codeOnly(requireProjectFile('lib/main.dart'));
      final theme = _region(main, 'appBarTheme:', 'bottomNavigationBarTheme:');
      expect(theme, isNotEmpty);
      expect(theme, contains('backgroundColor: Colors.transparent'));
      expect(theme, contains('scrolledUnderElevation: 0'));
    });

    test('no explicit opaque AppBar backgroundColor remains in lib/', () {
      final lib = Directory('${findProjectRoot().path}/lib');
      final offenders = <String>[];
      for (final entity in lib.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final code = codeOnly(entity.readAsStringSync());
        for (final bad in _opaqueAppBars(code)) {
          offenders.add('${entity.path.split('/lib/').last} — $bad');
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });

  group('E5+E6 — Home/Profile bodies have no opaque background (source)', () {
    test('E5: Home skeleton + main branch have no hBg fill', () {
      final home = codeOnly(requireProjectFile('lib/screens/home_screens.dart'));
      final build = _region(
          home, 'if (!_firstLoadDone) {', 'child: RefreshIndicator(');
      expect(build, isNotEmpty);
      expect(build, isNot(contains('color: hBg')));
    });

    test('E6: Profile has no opaque black layer; ember dots stay', () {
      final more = codeOnly(requireProjectFile('lib/screens/more_screens.dart'));
      expect(more,
          isNot(contains('Positioned.fill(child: Container(color: Colors.black))')));
      // The ProfilePage state class (its build holds the Stack):
      // dots + SafeArea still there, no black fill anywhere in it.
      final start = more.indexOf('class _ProfilePageState');
      expect(start, isNot(-1));
      final end = more.indexOf('\nclass ', start + 10);
      final profile = more.substring(start, end < 0 ? more.length : end);
      expect(profile, contains('ArenaEmberDots'));
      expect(profile, contains('SafeArea('));
      expect(profile, isNot(contains('Container(color: Colors.black)')));
    });
  });

  group('update 6 — ONE card-fill number everywhere (source)', () {
    test('every card surface reads kCardFillOpacity, no own alpha', () {
      final theme = codeOnly(requireProjectFile('lib/theme.dart'));
      final fill = _region(theme, 'cardFillDecoration(', 'cardFrameDecoration(');
      expect(fill, isNotEmpty);
      expect('alpha: kCardFillOpacity'.allMatches(fill).length, 3);
      expect(fill, isNot(contains('alpha: 0.')));
      // Gradient only (the frame's glow shadow below it keeps its
      // own 0.25 — a shadow, not a fill — so the region ends at the
      // border line).
      final deco = _region(theme, 'BoxDecoration cardDecoration(',
          'border: Border.all(color: kCardPurpleBorder');
      expect(deco, isNotEmpty);
      expect('alpha: kCardFillOpacity'.allMatches(deco).length, 3);
      expect(deco, isNot(contains('alpha: 0.')));
      // MockupCard + nav shell route through the shared decorations.
      expect(theme, contains('decoration: cardFillDecoration(radius: radius)'));
      expect(theme, contains('decoration: cardDecoration(radius: 24)'));
      expect(theme, contains('sigmaX: kCardBlurSigma'));
      // CardFieldShell is the shared cardDecoration too.
      final shell = _region(theme, 'class _CardFieldShellState', 'Color get kSurfaceElevated');
      expect(shell, contains('cardDecoration(radius: widget.radius)'));

      final home = codeOnly(requireProjectFile('lib/screens/home_screens.dart'));
      final dark = _region(home, 'class _DarkMockupCard', 'Widget _homeDot(bool active)');
      expect(dark, isNotEmpty);
      expect(dark, contains('cardFillDecoration(radius: radius)'));
      expect(dark, contains('sigmaX: kCardBlurSigma'));
      expect(dark, isNot(contains('alpha: 0.')));

      final more = codeOnly(requireProjectFile('lib/screens/more_screens.dart'));
      // Profile card + invite card read the token (no own alpha).
      expect(more, contains('decoration: cardFillDecoration(radius: 16)'));
      // (E25 moved the invite card's border to purple — the region
      // ends at the border line itself now, not a gold border.)
      final invite = _region(more, 'kCardPurpleTop.withValues(', 'border: Border.all(');
      expect(invite, isNotEmpty);
      expect('alpha: kCardFillOpacity'.allMatches(invite).length, 3);
    });
  });

  group('E7 — Community one-strip at 360px (widget)', () {
    setUpAll(() async {
      await _loadRoboto();
    });

    setUp(() {
      SupaDb.testFixtures = {
        'teams': [],
        'team_members': [],
        'team_invitations': [],
        'profiles': [
          {
            'firebase_uid': 'test-uid',
            'display_name': 'Tester',
            'username': 'tester'
          },
        ],
      };
    });

    tearDown(() {
      SupaDb.testFixtures = null;
    });

    Future<void> pumpTeams(WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(
          home: TeamsPage(uid: 'test-uid', embedded: true)));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    testWidgets('all three labels render FULLY, no ellipsis, no overflow',
        (tester) async {
      await pumpTeams(tester);
      final strip = find.byKey(const ValueKey('communityTabStrip'));
      expect(strip, findsOneWidget);
      final stripWidth = tester.getSize(strip).width;
      final segmentWidth = stripWidth / 3;
      for (final label in ['Community', 'Squad', 'Create']) {
        expect(find.text(label), findsOneWidget, reason: label);
        final text = tester.widget<Text>(find.text(label));
        expect(text.style?.fontSize, 14.0, reason: label);
        expect(text.overflow, isNot(TextOverflow.ellipsis), reason: label);
        // Full name fits inside its third of the strip (real Roboto).
        expect(tester.getSize(find.text(label)).width, lessThan(segmentWidth),
            reason: '$label wider than its segment');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('tap switches lists; Create opens the form',
        (tester) async {
      await pumpTeams(tester);
      // Default side is Squad.
      expect(find.text('No team yet'), findsOneWidget);
      expect(find.text('Join by Code'), findsOneWidget);

      await tester.tap(find.text('Community'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('Abhi koi community nahi'), findsOneWidget);
      expect(find.text('No team yet'), findsNothing);

      await tester.tap(find.text('Squad'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('No team yet'), findsOneWidget);
      expect(find.text('Abhi koi community nahi'), findsNothing);

      await tester.tap(find.text('Create'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.byType(CreateCommunityPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('E9 — My Matches title clears the status bar (widget)', () {
    setUpAll(() async {
      await _loadRoboto();
      FirebasePlatform.instance = _FakeCorePlatform();
      FirebaseAuthPlatform.instance = _FakeAuthPlatform();
      await Firebase.initializeApp(
        options: const FirebaseOptions(
            apiKey: 'test',
            appId: '1:1:android:1',
            messagingSenderId: '1',
            projectId: 'test'),
      );
      // ignore: unnecessary_statements
      FirebaseAuth.instance;
    });

    setUp(() {
      SupaDb.testFixtures = {
        'tournament_registrations': [],
        'tournaments': [],
      };
    });

    tearDown(() {
      SupaDb.testFixtures = null;
    });

    Future<void> pumpMyMatches(WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: MyMatchesPage())),
      );
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    testWidgets('title top edge is below the status-bar padding (0 inset)',
        (tester) async {
      await pumpMyMatches(tester);
      expect(find.text('MY MATCHES'), findsOneWidget);
      // The 28dp floor applies even when the reported padding reads 0
      // (the Home topShortfall pattern): title top >= 28.
      expect(tester.getTopLeft(find.text('MY MATCHES')).dy,
          greaterThanOrEqualTo(28));
      final safe = find.ancestor(
        of: find.text('MY MATCHES'),
        matching: find.byType(SafeArea),
      );
      expect(safe, findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('title clears a 24dp status bar', (tester) async {
      tester.view.padding = const FakeViewPadding(top: 24);
      addTearDown(tester.view.resetPadding);
      await pumpMyMatches(tester);
      expect(find.text('MY MATCHES'), findsOneWidget);
      expect(tester.getTopLeft(find.text('MY MATCHES')).dy,
          greaterThanOrEqualTo(24));
      expect(tester.takeException(), isNull);
    });
  });

  group('E10 — Watch Live transparent (widget + source)', () {
    setUpAll(() async {
      await _loadRoboto();
      WebViewPlatform.instance = _FakeWebViewPlatform();
      FirebasePlatform.instance = _FakeCorePlatform();
      FirebaseAuthPlatform.instance = _FakeAuthPlatform();
      await Firebase.initializeApp(
        options: const FirebaseOptions(
            apiKey: 'test',
            appId: '1:1:android:1',
            messagingSenderId: '1',
            projectId: 'test'),
      );
    });

    setUp(() {
      _FakeWebViewPlatform.lastLoadedUrl = null;
      _FakeWebViewPlatform.lastLoadedHtml = null;
      SupaDb.testFixtures = {
        'chat_messages': [
          {
            'id': 'c1',
            'scope': 'watch_live',
            'tournament_id': 't1',
            'firebase_uid': 'u1',
            'display_name': 'Areeba',
            'message': 'GG! Final dekh rahe ho?',
            'created_at': '2026-11-21T10:00:00Z',
          },
        ],
      };
    });

    tearDown(() {
      SupaDb.testFixtures = null;
    });

    testWidgets('header transparent, comments surface transparent, player untouched',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: WatchLiveScreen(
            tournamentId: 't1',
            tournamentName: 'Grand Final',
            watchUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('WATCH LIVE'), findsOneWidget);
      final appBar = tester.widget<AppBar>(find.byType(AppBar));
      expect(appBar.backgroundColor, Colors.transparent);
      // Comments surface: no opaque color, no decoration at all.
      final surface = tester.widget<Container>(
          find.byKey(const ValueKey('watchLiveCommentsSurface')));
      expect(surface.color, isNull);
      expect(surface.decoration, isNull);
      // Composer field still there (CardFieldShell untouched).
      expect(find.byType(CardFieldShell), findsOneWidget);
      // PLAYER UNTOUCHED: black container + embed still load.
      final player = tester.widget<Container>(
          find.byKey(const ValueKey('watchLivePlayerContainer')));
      final playerDeco = player.decoration as BoxDecoration;
      expect(playerDeco.color, Colors.black);
      expect(_FakeWebViewPlatform.lastLoadedUrl, isNull);
      expect(_FakeWebViewPlatform.lastLoadedHtml, contains('dQw4w9WgXcQ'));
      expect(tester.takeException(), isNull);
    });

    test('source: no kSurface fill left in Watch Live', () {
      final wl = codeOnly(requireProjectFile('lib/screens/watch_live_screen.dart'));
      expect(wl, isNot(contains('color: kSurface')));
    });
  });

  group('E11+E12+E15+E16 — room geometry at 360x800 (widget + source)', () {
    setUpAll(() async {
      await _loadRoboto();
      SharedPreferences.setMockInitialValues({});
      FirebasePlatform.instance = _FakeCorePlatform();
      FirebaseAuthPlatform.instance = _FakeAuthPlatform();
      await Firebase.initializeApp(
        options: const FirebaseOptions(
            apiKey: 'test',
            appId: '1:1:android:1',
            messagingSenderId: '1',
            projectId: 'test'),
      );
      // ignore: unnecessary_statements
      FirebaseAuth.instance;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('arena_hub_dsp_mic'),
              (MethodCall call) async {
                if (call.method == 'isAvailable') return false;
                return null;
              });
    });

    tearDown(() {
      SupaDb.testFixtures = null;
    });

    testWidgets('E11: host card clears a 24dp status bar',
        (tester) async {
      tester.view.padding = const FakeViewPadding(top: 24);
      addTearDown(tester.view.resetPadding);
      await _mountRoom(tester);
      final panel = find.byType(UnifiedRoomPage);
      expect(panel, findsOneWidget);
      // The host card sits under a SafeArea (E11 fix).
      expect(
        find.ancestor(of: panel, matching: find.byType(SafeArea)),
        findsWidgets,
      );
      final host = find.descendant(
          of: panel, matching: find.text('Host')).first;
      expect(host, findsWidgets);
      expect(tester.getTopLeft(host).dy, greaterThanOrEqualTo(24));
      expect(tester.takeException(), isNull);
    });

    test('E12: embedded room has NO inner background layer (source)', () {
      final room = codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
      final embedded = _region(
          room, 'Widget _buildEmbeddedVoice(', 'Widget _buildEmbeddedSidebar(');
      expect(embedded, isNotEmpty);
      // The double scrim is gone — the panel shows the app-wide
      // layer (main.dart) instead of mounting its own.
      expect(embedded, isNot(contains('AppBackgroundLayer(')));
      final main = codeOnly(requireProjectFile('lib/main.dart'));
      expect(main, contains('AppBackgroundLayer('));
    });

    testWidgets('E15: sidebar rail ends above the panel edge; chat is clear',
        (tester) async {
      await _mountRoom(tester);
      final panel = find.byType(UnifiedRoomPage);
      expect(panel, findsOneWidget);
      final panelBottom = tester.getBottomLeft(panel).dy;
      // The composer sits BELOW the panel — the rail (inside the
      // panel) cannot overlap it.
      final composer = find.byType(ArenaChatInputBar);
      expect(composer, findsOneWidget);
      expect(tester.getTopLeft(composer).dy,
          greaterThanOrEqualTo(panelBottom));
      expect(tester.takeException(), isNull);
    });

    test('E15: capped sidebar has bottom breathing room (source)', () {
      final room = codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
      final capped = _region(
          room, 'Widget _buildCappedSidebar(', 'Widget _buildEmbeddedSidebar(');
      expect(capped, isNotEmpty);
      expect(capped, contains('bottom: 8'));
    });

    testWidgets('E16: all 6 seats fully visible + composer visible together',
        (tester) async {
      await _mountRoom(tester);
      final panel = find.byType(UnifiedRoomPage);
      expect(panel, findsOneWidget);
      final grid = find.descendant(
          of: panel, matching: find.byType(GridView));
      expect(grid, findsOneWidget);
      // Podium card = the ClipRRect ancestor of the grid.
      final card = find
          .ancestor(of: grid, matching: find.byType(ClipRRect))
          .first;
      final cardTop = tester.getTopLeft(card).dy;
      final cardBottom = tester.getBottomLeft(card).dy;
      for (final n in ['1', '2', '3', '4', '5', '6']) {
        final seat = find.descendant(of: grid, matching: find.text(n));
        expect(seat, findsOneWidget, reason: 'seat $n');
        expect(tester.getTopLeft(seat).dy, greaterThanOrEqualTo(cardTop),
            reason: 'seat $n top');
        expect(tester.getBottomLeft(seat).dy, lessThanOrEqualTo(cardBottom),
            reason: 'seat $n bottom');
      }
      // ...and the composer is on screen at the same time.
      final composer = find.byType(ArenaChatInputBar);
      expect(composer, findsOneWidget);
      expect(tester.getBottomRight(composer).dy, lessThanOrEqualTo(800));
      expect(tester.takeException(), isNull);
    });
  });

  group('E13 — compact chat density (unit + source)', () {
    test('density constants are the NEW compact values', () {
      expect(kChatRowBottomGap, 6);
      expect(kChatRowBottomGapNeon, 3);
      expect(kChatNameBubbleGap, 2);
      expect(kChatAvatarGap, 5);
      expect(kChatBubblePaddingV, 5);
      expect(kChatBubblePaddingVPolished, 6);
    });

    test('bubble + pill sizes are compact (source)', () {
      final chat = codeOnly(requireProjectFile('lib/components/arena_chat.dart'));
      // Bubble text 13 (was 15), radius 14 (was 16), border 1.0
      // (was 1.5) — pinned on the polished bubble decoration.
      expect(chat, contains('fontSize: 13'));
      expect(chat, contains('BorderRadius.circular(14)'));
      // Organizer role pill: label 10 (was 11), padding H8/V2,
      // crown 11x8.25 (was 13x9.75).
      final pill = _region(
          chat, 'class ArenaRolePill', 'const Color _neonBubblePink');
      expect(pill, isNotEmpty);
      expect(pill, contains('fontSize: 10'));
      expect(pill, contains('horizontal: 8, vertical: 2'));
      expect(pill, contains('Size(11, 8.25)'));
    });
  });

  group('E14 — clear-notice filter (source + widget)', () {
    test('all four filter sites match the plain-text notice (source)', () {
      const needle = "msg.contains('Chat history clear kar di gayi')";
      final room = codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
      expect(room, contains(needle));
      final comm = codeOnly(
          requireProjectFile('lib/screens/communities_screens.dart'));
      expect(comm, contains(needle));
      final pro =
          codeOnly(requireProjectFile('lib/screens/pro_features.dart'));
      expect(pro, contains("contains('Chat history clear kar di gayi')"));
      // The prefix filter still exists alongside it.
      expect(room, contains('_chatClearedPrefix'));
    });

    testWidgets('legacy plain-text notice row never renders',
        (tester) async {
      await _loadRoboto();
      SharedPreferences.setMockInitialValues({});
      FirebasePlatform.instance = _FakeCorePlatform();
      FirebaseAuthPlatform.instance = _FakeAuthPlatform();
      await Firebase.initializeApp(
        options: const FirebaseOptions(
            apiKey: 'test',
            appId: '1:1:android:1',
            messagingSenderId: '1',
            projectId: 'test'),
      );
      // ignore: unnecessary_statements
      FirebaseAuth.instance;
      addTearDown(() => SupaDb.testFixtures = null);
      await _mountRoom(tester, chatMessages: [
        {
          'id': 'legacy-1',
          'scope': 'community',
          'community_id': 'comm-1',
          'firebase_uid': 'u1',
          'display_name': 'ORGANIZER',
          'message': '— Chat history clear kar di gayi —',
          'created_at': '2026-11-24T00:58:00Z',
        },
        {
          'id': 'normal-1',
          'scope': 'community',
          'community_id': 'comm-1',
          'firebase_uid': 'u1',
          'display_name': 'Tester',
          'message': 'Hello room',
          'created_at': '2026-11-24T00:59:00Z',
        },
      ]);
      // The legacy notice is filtered; the real message renders.
      expect(find.textContaining('Chat history clear kar di gayi'),
          findsNothing);
      expect(find.text('Hello room'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('E17 — every sidebar button opens its function (widget)', () {
    setUpAll(() async {
      await _loadRoboto();
      SharedPreferences.setMockInitialValues({});
      FirebasePlatform.instance = _FakeCorePlatform();
      FirebaseAuthPlatform.instance = _FakeAuthPlatform();
      await Firebase.initializeApp(
        options: const FirebaseOptions(
            apiKey: 'test',
            appId: '1:1:android:1',
            messagingSenderId: '1',
            projectId: 'test'),
      );
      // ignore: unnecessary_statements
      FirebaseAuth.instance;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('arena_hub_dsp_mic'),
              (MethodCall call) async {
                if (call.method == 'isAvailable') return false;
                return null;
              });
    });

    tearDown(() {
      SupaDb.testFixtures = null;
    });

    Finder _sidebarButton(String label) => find.descendant(
          of: find.byType(UnifiedRoomPage),
          matching: find.text(label),
        );

    testWidgets('Followers shows its toast', (tester) async {
      await _mountRoom(tester);
      await tester.tap(_sidebarButton('Followers'));
      await _settleRoom(tester);
      expect(find.text('Followers list abhi available nahi hai.'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Music opens the player console', (tester) async {
      await _mountRoom(tester);
      await tester.tap(_sidebarButton('Music'));
      await _settleRoom(tester);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('MUSIC'), findsOneWidget);
      _expectNoExceptionExceptKnownRjOverflow(tester);
    });

    testWidgets('RJ Panel opens the console', (tester) async {
      await _mountRoom(tester);
      await tester.tap(_sidebarButton('RJ Panel'));
      await _settleRoom(tester);
      expect(find.byType(BottomSheet), findsOneWidget);
      _expectNoExceptionExceptKnownRjOverflow(tester);
    });

    testWidgets('Settings opens the settings sheet', (tester) async {
      await _mountRoom(tester);
      await tester.tap(_sidebarButton('Settings'));
      await _settleRoom(tester);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Power opens the player console (music not playing)',
        (tester) async {
      await _mountRoom(tester);
      await tester.tap(_sidebarButton('Power'));
      await _settleRoom(tester);
      expect(find.byType(BottomSheet), findsOneWidget);
      _expectNoExceptionExceptKnownRjOverflow(tester);
    });

    testWidgets('Leave Room completes without error', (tester) async {
      await _mountRoom(tester);
      await tester.tap(_sidebarButton('Leave Room'));
      await _settleRoom(tester);
      // The host card is sticky (no onCloseVoice) — the room stays
      // mounted; the tap must simply not throw.
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('E28 — Music + RJ host-only (widget)', () {
    setUpAll(() async {
      await _loadRoboto();
      SharedPreferences.setMockInitialValues({});
      FirebasePlatform.instance = _FakeCorePlatform();
      FirebaseAuthPlatform.instance = _FakeAuthPlatform();
      await Firebase.initializeApp(
        options: const FirebaseOptions(
            apiKey: 'test',
            appId: '1:1:android:1',
            messagingSenderId: '1',
            projectId: 'test'),
      );
      // ignore: unnecessary_statements
      FirebaseAuth.instance;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('arena_hub_dsp_mic'),
              (MethodCall call) async {
                if (call.method == 'isAvailable') return false;
                return null;
              });
    });

    tearDown(() {
      SupaDb.testFixtures = null;
    });

    Finder _sidebarButton(String label) => find.descendant(
          of: find.byType(UnifiedRoomPage),
          matching: find.text(label),
        );

    testWidgets('(a) organizer sees Music + RJ Panel', (tester) async {
      await _mountRoom(tester); // uid test-uid = creator + admin
      expect(_sidebarButton('Music'), findsOneWidget);
      expect(_sidebarButton('RJ Panel'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('(b) regular member sees NEITHER (others stay visible)',
        (tester) async {
      await _mountRoom(
        tester,
        uid: 'member-uid',
        memberRole: 'member',
        // Created + administered by someone else.
        community: _roomCommunity(creatorUid: 'test-uid'),
        adminUid: 'test-uid',
      );
      expect(_sidebarButton('Music'), findsNothing);
      expect(_sidebarButton('RJ Panel'), findsNothing);
      // No over-gating: the rest of the sidebar is untouched.
      expect(_sidebarButton('Followers'), findsOneWidget);
      expect(_sidebarButton('Settings'), findsOneWidget);
      expect(_sidebarButton('Power'), findsOneWidget);
      expect(_sidebarButton('Leave Room'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('(c) designated admin sees both', (tester) async {
      await _mountRoom(
        tester,
        uid: 'member-uid',
        memberRole: 'member',
        community: _roomCommunity(creatorUid: 'test-uid'),
        adminUid: 'member-uid', // the designated admin is this user
      );
      expect(_sidebarButton('Music'), findsOneWidget);
      expect(_sidebarButton('RJ Panel'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('(d) team captain (team scope) sees both', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SupaDb.testFixtures = {
        'teams': [
          {'id': 'team-1', 'name': 'TEST CH', 'captain_uid': 'test-uid'}
        ],
        'team_members': [
          {'team_id': 'team-1', 'firebase_uid': 'test-uid'}
        ],
        'profiles': [
          {'firebase_uid': 'test-uid', 'display_name': 'Tester', 'level': 1}
        ],
        'admin_config': [
          {'id': 1, 'admin_firebase_uid': 'someone-else'}
        ],
        'chat_messages': [],
      };
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: UnifiedRoomPage(
            scope: 'team',
            teamId: 'team-1',
            teamName: 'TEST CH',
            captainUid: 'test-uid',
            embedded: true,
          ),
        ),
      ));
      await _settleRoom(tester);
      expect(_sidebarButton('Music'), findsOneWidget);
      expect(_sidebarButton('RJ Panel'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('source: RJ Panel was already gated; Music gate matches it', () {
      final room = codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
      final sidebar = _region(room, 'Widget _buildEmbeddedSidebar(',
          'Widget _buildEmbeddedVoice(');
      expect(sidebar, isNotEmpty);
      // Both buttons sit behind the SAME three-part rule.
      expect(
          '_isAdminForBroadcast ||\n            _isTeamCaptainForBroadcast ||\n            _isCommunityOrganizerForBroadcast'
              .allMatches(sidebar)
              .length,
          greaterThanOrEqualTo(2));
      // ...and the music-approved shortcut is NOT the gate.
      expect(sidebar, isNot(contains('_canBroadcastMusic')));
    });

    testWidgets('full-page menu: showMusic=false hides the Music row',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: ArenaVoiceRoomScreen(
          roomTitle: 'Test Room',
          hostName: 'Host',
          hostAvatar: '',
          hostVerified: true,
          initialSeats: const [
            VoiceSeatMember(seatNumber: 1),
            VoiceSeatMember(seatNumber: 2),
            VoiceSeatMember(seatNumber: 3),
            VoiceSeatMember(seatNumber: 4),
            VoiceSeatMember(seatNumber: 5),
            VoiceSeatMember(seatNumber: 6),
          ],
          initialMessages: const [],
          showMusic: false,
          showRjPanel: false,
        ),
      ));
      await _settleRoom(tester);
      await tester.tap(find.byIcon(LucideIcons.menu));
      await _settleRoom(tester);
      expect(find.text('Room Menu'), findsOneWidget);
      expect(find.text('Music'), findsNothing);
      expect(find.text('RJ Panel'), findsNothing);
      expect(find.text('Followers'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Leave Room'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('full-page menu: host sees Music + RJ rows',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: ArenaVoiceRoomScreen(
          roomTitle: 'Test Room',
          hostName: 'Host',
          hostAvatar: '',
          hostVerified: true,
          initialSeats: const [
            VoiceSeatMember(seatNumber: 1),
            VoiceSeatMember(seatNumber: 2),
            VoiceSeatMember(seatNumber: 3),
            VoiceSeatMember(seatNumber: 4),
            VoiceSeatMember(seatNumber: 5),
            VoiceSeatMember(seatNumber: 6),
          ],
          initialMessages: const [],
          showMusic: true,
          showRjPanel: true,
        ),
      ));
      await _settleRoom(tester);
      await tester.tap(find.byIcon(LucideIcons.menu));
      await _settleRoom(tester);
      expect(find.text('Music'), findsOneWidget);
      expect(find.text('RJ Panel'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('E29 — voice click-gated, no auto-join (widget + source)', () {
    setUpAll(() async {
      await _loadRoboto();
      SharedPreferences.setMockInitialValues({});
      FirebasePlatform.instance = _FakeCorePlatform();
      FirebaseAuthPlatform.instance = _FakeAuthPlatform();
      await Firebase.initializeApp(
        options: const FirebaseOptions(
            apiKey: 'test',
            appId: '1:1:android:1',
            messagingSenderId: '1',
            projectId: 'test'),
      );
      // ignore: unnecessary_statements
      FirebaseAuth.instance;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('arena_hub_dsp_mic'),
              (MethodCall call) async {
                if (call.method == 'isAvailable') return false;
                return null;
              });
    });

    tearDown(() {
      SupaDb.testFixtures = null;
    });

    test('source: no automatic _joinVoiceOpen call remains', () {
      final room = codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
      final init = _region(room, 'void initState()', 'void _bindVoiceController()');
      expect(init, isNotEmpty);
      expect(init, isNot(contains('_joinVoiceOpen')));
      final update = _region(
          room, 'void didUpdateWidget(', 'void dispose()');
      expect(update, isNotEmpty);
      expect(update, isNot(contains('_joinVoiceOpen')));
      // The tap paths still exist (mic button, rail Voice, seat tap,
      // Voice menu entry, admin take-mic).
      expect('_joinVoiceOpen()'.allMatches(room).length,
          greaterThanOrEqualTo(5));
      // Full page never had a mount-time join.
      final full = codeOnly(
          requireProjectFile('lib/screens/arena_voice_room_screen.dart'));
      expect(full, isNot(contains('_joinVoiceOpen')));
      expect(full, isNot(contains('joinVoice')));
    });

    testWidgets('mount: voice OFF, no Connecting pill', (tester) async {
      await _mountRoom(tester);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      // Idle pill reads 'Not connected' — no join was attempted.
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.text('Connecting…'), findsNothing);
      // The mic shows its OFF state.
      expect(
          find.descendant(
              of: find.byType(UnifiedRoomPage),
              matching: find.text('OFF')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('mic tap starts the join (Connecting or Voice Failed)',
        (tester) async {
      await _mountRoom(tester);
      expect(find.text('Not connected'), findsOneWidget);
      // The 24px host mic button (fix16's locator — the Live
      // pill's mic icon is 12px, so this matches exactly one).
      final micIcon = find.descendant(
        of: find.byType(UnifiedRoomPage),
        matching: find.byWidgetPredicate((w) =>
            w is Icon &&
            (w.icon == Icons.mic || w.icon == Icons.mic_off) &&
            w.size == 24),
      );
      expect(micIcon, findsOneWidget);
      await tester.tap(micIcon);
      await _settleRoom(tester);
      // A join was attempted on the tap: the pill left the idle
      // state (in the test sandbox LiveKit cannot connect, so it
      // lands on Connecting… or Voice Failed — either proves the
      // tap-to-join path ran).
      expect(find.text('Not connected'), findsNothing);
      expect(
        find.text('Connecting…').evaluate().isNotEmpty ||
            find.text('Voice Failed').evaluate().isNotEmpty,
        isTrue,
        reason: 'no join attempt observed after the mic tap',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('E18 — Home header full logo badge (widget + source)', () {
    setUpAll(() async {
      await _loadRoboto();
      FirebasePlatform.instance = _FakeCorePlatform();
      FirebaseAuthPlatform.instance = _FakeAuthPlatform();
      await Firebase.initializeApp(
        options: const FirebaseOptions(
            apiKey: 'test',
            appId: '1:1:android:1',
            messagingSenderId: '1',
            projectId: 'test'),
      );
      // ignore: unnecessary_statements
      FirebaseAuth.instance;
    });

    setUp(() {
      SupaDb.testFixtures = {
        'profiles': [
          {
            'firebase_uid': 'test-uid',
            'display_name': 'Test Player',
            'level': 5,
            'photo_url': '',
            'last_checked_notifications': 0,
          },
        ],
        'tournaments': <Map<String, dynamic>>[],
        'tournament_registrations': <Map<String, dynamic>>[],
        'sliders': <Map<String, dynamic>>[],
        'promotions': <Map<String, dynamic>>[],
        'ads': <Map<String, dynamic>>[],
        'notifications': <Map<String, dynamic>>[],
        'user_notifications': <Map<String, dynamic>>[],
      };
    });

    tearDown(() {
      SupaDb.testFixtures = null;
    });

    testWidgets('header shows the full badge, no ClipOval logo widget',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            bottomNavigationBar:
                SizedBox(height: 64, child: Center(child: Text('NAV'))),
            body: HomePage(),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The header logo is the raw badge asset (no ClipOval widget
      // around it, no ArenaHubLogoImage anywhere in the header).
      final logo = find.byWidgetPredicate((w) =>
          w is Image &&
          w.image is AssetImage &&
          (w.image as AssetImage).assetName ==
              'assets/images/arena_hub_logo.png');
      expect(logo, findsWidgets);
      // At least one badge sits in the header band (top 120px).
      expect(
        logo.evaluate().any((e) =>
            (e.renderObject as RenderBox).localToGlobal(Offset.zero).dy <
            120),
        isTrue,
      );
      expect(find.byType(ArenaHubLogoImage), findsNothing);
      // The right profile circle is still the one round photo.
      expect(find.byType(CircleAvatar), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    test('source: Home header uses Image.asset, other usages untouched',
        () {
      final home =
          codeOnly(requireProjectFile('lib/screens/home_screens.dart'));
      expect(home,
          contains("Image.asset('assets/images/arena_hub_logo.png'"));
      expect(home, isNot(contains('ArenaHubLogoImage(')));
      // Splash / login / signup still use the component.
      for (final f in [
        'lib/screens/arena_hub_splash_screen.dart',
        'lib/screens/login_screen.dart',
        'lib/screens/signup_screen.dart',
      ]) {
        expect(codeOnly(requireProjectFile(f)),
            contains('ArenaHubLogoImage('),
            reason: f);
      }
    });
  });

  group('E19 — Login Player white sliver (source)', () {
    test('Player text: height >= 1.0 + gold base color + 6px gap', () {
      final login =
          codeOnly(requireProjectFile('lib/screens/login_screen.dart'));
      final header = _region(login, "Text('Player'", 'Container(');
      expect(header, isNotEmpty);
      // Prime fix: the descender stays inside the shader bounds
      // (height 1.1) and any overflow paints gold, not white.
      expect(header, contains('height: 1.1'));
      expect(header, contains('ArenaTheme.goldPrimary'));
      expect(header, isNot(contains('height: 0.94')));
      // Secondary: the hairline gap grew 3 -> 6.
      final gap = _region(login, "Text('Player'", 'height: 2');
      expect(gap, contains('SizedBox(height: 6)'));
      // Text, font, size, gradient unchanged.
      expect(login, contains("Text('Player'"));
      expect(login, contains('fontSize: 48'));
    });
  });

  group('E20 — Check-in short label (widget + source)', () {
    setUpAll(() async {
      await _loadRoboto();
      FirebasePlatform.instance = _FakeCorePlatform();
      FirebaseAuthPlatform.instance = _FakeAuthPlatform();
      await Firebase.initializeApp(
        options: const FirebaseOptions(
            apiKey: 'test',
            appId: '1:1:android:1',
            messagingSenderId: '1',
            projectId: 'test'),
      );
      // ignore: unnecessary_statements
      FirebaseAuth.instance;
    });

    setUp(() {
      SupaDb.testFixtures = {
        'tournaments': [
          {'id': 't1', 'title': 'Test Cup'}
        ],
        'match_checkins': [],
        'profiles': [
          {'firebase_uid': 'test-uid', 'display_name': 'Tester'}
        ],
      };
    });

    tearDown(() {
      SupaDb.testFixtures = null;
    });

    testWidgets('Close button is short, one line, tappable at 360px',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: checkin.CheckInPage(
          tournamentId: 't1',
          teamId: 'team-1',
          captainUid: 'test-uid',
          viewerRole: AppRole.organizer,
        ),
      ));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('Close check-in'), findsOneWidget);
      expect(find.textContaining('mark absent'), findsNothing);
      final button = tester.widget<ElevatedButton>(
          find.ancestor(of: find.text('Close check-in'),
              matching: find.byType(ElevatedButton)));
      expect(button.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });

    test('source: both tr() strings shortened', () {
      final page = codeOnly(
          requireProjectFile('lib/platform/competition/checkin_page.dart'));
      expect(page, contains("tr('Close check-in', 'Check-in band karen')"));
      expect(page,
          isNot(contains('Close check-in (mark absent + promote waitlist)')));
    });
  });

  group('E21 — Offline screen new design (widget + source)', () {
    testWidgets('poster background + new logo badge, no ember',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: OfflineScreen(onRetry: () {}, onGoBack: () {})),
      );
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.byType(AppBackgroundLayer), findsOneWidget);
      // The new full badge (E18 style) — not the old crown logo.
      final badge = find.byWidgetPredicate((w) =>
          w is Image &&
          w.image is AssetImage &&
          (w.image as AssetImage).assetName ==
              'assets/images/arena_hub_logo.png');
      expect(badge, findsOneWidget);
      expect(find.byType(ArenaLogo), findsNothing);
      // No ember texture anywhere.
      final ember = find.byWidgetPredicate((w) =>
          w is Image &&
          w.image is AssetImage &&
          (w.image as AssetImage).assetName.contains('ember_bg'));
      expect(ember, findsNothing);
      expect(find.text('RETRY CONNECTION'), findsOneWidget);
      expect(find.text('GO BACK'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('source: no ember_bg in the offline screen', () {
      final off =
          codeOnly(requireProjectFile('lib/screens/offline_screen.dart'));
      expect(off, isNot(contains('ember_bg')));
      expect(off, contains('AppBackgroundLayer('));
      expect(off, contains('useNewLogo: true'));
    });
  });

  group('E22 — offline overlay (widget)', () {
    late StreamController<List<ConnectivityResult>> connCtrl;

    setUpAll(() async {
      await _loadRoboto();
      SharedPreferences.setMockInitialValues({});
      FirebasePlatform.instance = _FakeCorePlatform();
      FirebaseAuthPlatform.instance = _FakeAuthPlatform();
      await Firebase.initializeApp(
        options: const FirebaseOptions(
            apiKey: 'test',
            appId: '1:1:android:1',
            messagingSenderId: '1',
            projectId: 'test'),
      );
      // ignore: unnecessary_statements
      FirebaseAuth.instance;
    });

    setUp(() {
      connCtrl = StreamController<List<ConnectivityResult>>();
      addTearDown(connCtrl.close);
      // RETRY's checkConnectivity() resolves online.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'),
        (call) async {
          if (call.method == 'check') return ['wifi'];
          return null;
        },
      );
      SupaDb.testFixtures = {
        'profiles': [
          {
            'firebase_uid': 'test-uid',
            'display_name': 'Test Player',
            'username': 'testplayer',
            'photo_url': '',
            'created_at': '2026-10-15T12:00:00Z',
            'level': 1,
            'xp': 0,
            'rank_tier': 'Bronze',
            'total_matches': 0,
            'won_matches': 0,
            'total_earnings': 0,
          },
        ],
        'tournaments': [],
        'sliders': [],
        'promotions': [],
        'ads': [],
        'match_history': [],
        'notifications': [],
        'user_notifications': [],
      };
    });

    tearDown(() {
      SupaDb.testFixtures = null;
    });

    Future<void> pumpShell(WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: HomeShell(connectivityStream: connCtrl.stream)),
      );
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    testWidgets('loss shows the overlay; restore dismisses it, state intact',
        (tester) async {
      await pumpShell(tester);
      expect(find.byType(OfflineScreen), findsNothing);
      expect(find.byType(BottomNavigationBar), findsOneWidget);

      // Network lost -> full offline page AT ONCE, above content.
      connCtrl.add([ConnectivityResult.none]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(OfflineScreen), findsOneWidget);
      expect(find.text('RETRY CONNECTION'), findsOneWidget);
      // Overlay mode: no GO BACK (nothing to pop to).
      expect(find.text('GO BACK'), findsNothing);

      // Network back -> the overlay dismisses ITSELF; the shell
      // (same tab, same state) is underneath, untouched.
      connCtrl.add([ConnectivityResult.wifi]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(OfflineScreen), findsNothing);
      expect(find.byType(BottomNavigationBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('RETRY with connectivity back dismisses the overlay',
        (tester) async {
      await pumpShell(tester);
      connCtrl.add([ConnectivityResult.none]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(OfflineScreen), findsOneWidget);

      await tester.tap(find.text('RETRY CONNECTION'));
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.byType(OfflineScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('E23 — old-design audit (source)', () {
    test('no ember_bg / splash_crest in live screens', () {
      for (final f in [
        'lib/screens/offline_screen.dart',
        'lib/screens/maintenance_screen.dart',
        'lib/main.dart',
      ]) {
        final code = codeOnly(requireProjectFile(f));
        expect(code, isNot(contains('ember_bg')), reason: f);
        expect(code, isNot(contains('splash_crest')), reason: f);
      }
    });

    test('gate + maintenance use the poster + new badge', () {
      final main = codeOnly(requireProjectFile('lib/main.dart'));
      final gate = _region(main, 'Widget _gateScreen(', 'Widget build(');
      expect(gate, isNotEmpty);
      expect(gate, contains('AppBackgroundLayer('));
      expect(gate, contains('arena_hub_logo.png'));
      final maint =
          codeOnly(requireProjectFile('lib/screens/maintenance_screen.dart'));
      expect(maint, contains('AppBackgroundLayer('));
      expect(maint, contains('arena_hub_logo.png'));
    });

    test('About page shows the badge, not the old wordmark', () {
      final more =
          codeOnly(requireProjectFile('lib/screens/more_screens.dart'));
      final about = _region(more, 'class AboutPage', 'class _');
      expect(about, isNotEmpty);
      expect(about, contains('arena_hub_logo.png'));
      expect(about, isNot(contains("Text('ARENA HUB'")));
    });
  });

  group('E24 — buttons like cards, CORRECTED rule (widget + source)', () {
    setUpAll(() async {
      await _loadRoboto();
    });

    setUp(() {
      SupaDb.testFixtures = {
        'teams': [],
        'team_members': [],
        'team_invitations': [],
        'profiles': [
          {
            'firebase_uid': 'test-uid',
            'display_name': 'Tester',
            'username': 'tester'
          },
        ],
      };
    });

    tearDown(() {
      SupaDb.testFixtures = null;
    });

    testWidgets('strip: selected = gold gradient, rest = transparent',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(
          home: TeamsPage(uid: 'test-uid', embedded: true)));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      // Default side is Squad (selected).
      Container segment(String label) => tester.widget<Container>(
            find.ancestor(
                of: find.text(label), matching: find.byType(Container)).first,
          );
      final selected = segment('Squad').decoration as BoxDecoration;
      expect(selected.gradient, kGoldGradient);
      final rest = segment('Community').decoration as BoxDecoration;
      // Rest segments are transparent — the strip's card fill
      // shows through (never black).
      expect(rest.gradient, isNull);
      expect(rest.color, isNull);
      // The strip itself is the card (shared token).
      final strip = tester.widget<Container>(
          find.byKey(const ValueKey('communityTabStrip')));
      final stripDeco = strip.decoration as BoxDecoration;
      expect((stripDeco.gradient as LinearGradient).colors,
          (cardDecoration().gradient as LinearGradient).colors);
      expect(tester.takeException(), isNull);
    });

    test('source: selected = gold fill, rest = card fill (all pills)', () {
      // FilterTabs: active kGold + dark text; rest card fill.
      final comp =
          codeOnly(requireProjectFile('lib/components/arena_components.dart'));
      final pill = _region(comp, 'Widget _pill(int i)', 'Widget build(');
      expect(pill, contains('color: active ? kGold : null'));
      expect(pill, contains('const Color(0xFF0A0A0F)'));
      expect(pill, contains('cardFillDecoration(radius: 20)'));
      // Community filter pills: same rule.
      final cs =
          codeOnly(requireProjectFile('lib/screens/community_screens.dart'));
      expect(cs, contains('color: kGold,'));
      expect(cs, contains('cardFillDecoration(radius: 20)'));
      // ArenaFilterChip: selected gold, rest card.
      final ui = codeOnly(requireProjectFile('lib/widgets/arena_ui.dart'));
      final chip = _region(ui, 'class ArenaFilterChip', 'class ArenaLiveBadge');
      expect(chip, contains('color: kGold,'));
      expect(chip, contains('cardFillDecoration(radius: kRadiusChip)'));
      // Wallet action: active gold fill, inactive card fill.
      final wallet =
          codeOnly(requireProjectFile('lib/screens/wallet_screens.dart'));
      expect(wallet, contains('color: kGold,'));
      expect(wallet, contains('cardFillDecoration(radius: 30)'));
      // Frames + rewards tabs: active gold fill.
      final frames =
          codeOnly(requireProjectFile('lib/screens/frames_screen.dart'));
      expect(frames, contains('color: kGold,'));
      final rewards =
          codeOnly(requireProjectFile('lib/screens/rewards_screens.dart'));
      expect(rewards, contains('color: kGold,'));
    });

    test('primary CTAs still gold (no regression)', () {
      final ui = codeOnly(requireProjectFile('lib/widgets/arena_ui.dart'));
      // ArenaPrimaryButton keeps its gold gradient fill.
      expect(ui, contains('kGoldGradient'));
      // The goldButton helper keeps the gold fill.
      expect(ui, contains('backgroundColor: kGold'));
    });
  });

  group('E25 — invites card standard (source)', () {
    test('purple border, no gold glow, standard fill + radius', () {
      final more =
          codeOnly(requireProjectFile('lib/screens/more_screens.dart'));
      final card = _region(more, 'kCardPurpleTop.withValues(',
          'border: Border.all(\n                                color: kCardPurpleBorder');
      expect(card, isNotEmpty);
      // Fill was already standard (3 stops at the token).
      expect('alpha: kCardFillOpacity'.allMatches(card).length, 3);
      final border = _region(more, 'border: Border.all(',
          'child: Column(');
      // The card's own border + shadow (first border after the
      // gradient): purple border, ONE purple shadow, radius 22.
      expect(more, contains('color: kCardPurpleBorder, width: 1.5'));
      expect(more, contains('kCardPurpleGlow'));
      expect(border, isNot(contains('kGold')));
      // Content untouched: gold 0s, INVITE FRIENDS CTA, sparks.
      expect(more, contains('INVITE FRIENDS'));
      expect(more, contains('_EmberDots'));
    });
  });

  group('update 19 — Leaderboards (source)', () {
    test('header transparent + tabs scrollable, 5 scopes', () {
      final page = codeOnly(
          requireProjectFile('lib/platform/scoring/leaderboard_page.dart'));
      final appBar = _region(page, 'AppBar(', 'TabBar(');
      expect(appBar, contains('backgroundColor: Colors.transparent'));
      final tabs = _region(page, 'TabBar(', 'TabBarView(');
      expect(tabs, contains('isScrollable: true'));
      expect(tabs, contains('LeaderboardScope.values'));
      final scoring =
          codeOnly(requireProjectFile('lib/platform/scoring/scoring.dart'));
      final scopes = _region(scoring, 'enum LeaderboardScope', '}');
      for (final scope in ['match', 'tournament', 'season', 'country', 'global']) {
        expect(scopes, contains(scope), reason: scope);
      }
    });
  });

  group('E26+E27 — procedural smoke (widget + unit)', () {
    test('SmokeLayer constants kept: enabled, 20% opacity', () {
      expect(SmokeLayer.enabled, isTrue);
      expect(SmokeLayer.smokeOpacity, 0.20);
    });

    test('source: no Lottie in the render path anymore', () {
      final ui = codeOnly(requireProjectFile('lib/widgets/arena_ui.dart'));
      final layer = ui.substring(ui.indexOf('class SmokeLayer'));
      expect(layer, isNot(contains('Lottie.asset')));
      expect(layer, contains('SmokeBackgroundPainter('));
      expect(layer, contains('Timer.periodic'));
      expect(layer, contains('if (!SmokeLayer.enabled)'));
    });

    testWidgets('SmokeLayer paints the procedural layer at 0.20 opacity',
        (tester) async {
      SupaDb.appBackgroundUrl.value = '';
      themeLightNotifier.value = false;
      addTearDown(() {
        SupaDb.appBackgroundUrl.value = '';
        themeLightNotifier.value = false;
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                AppBackgroundLayer(),
                Center(child: Text('content')),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.byType(SmokeLayer), findsOneWidget);
      final paint = find.descendant(
          of: find.byType(SmokeLayer), matching: find.byType(CustomPaint));
      expect(paint, findsOneWidget);
      expect(tester.widget<CustomPaint>(paint).painter,
          isA<SmokeBackgroundPainter>());
      final opacity = tester.widget<Opacity>(find.ancestor(
          of: paint, matching: find.byType(Opacity)));
      expect(opacity.opacity, 0.20);
      expect(tester.takeException(), isNull);
    });

    testWidgets('painter renders with real FBM textures, no error',
        (tester) async {
      final textures = await ProceduralSmokeTextures.generate();
      addTearDown(textures.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: CustomPaint(
            painter: SmokeBackgroundPainter(
                textures: textures, elapsedSeconds: 3.0),
            size: const Size(360, 800),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    });
  });

  group('E30 — community invite (widget + unit)', () {
    setUpAll(() async {
      await _loadRoboto();
      SharedPreferences.setMockInitialValues({});
      FirebasePlatform.instance = _FakeCorePlatform();
      FirebaseAuthPlatform.instance = _FakeAuthPlatform();
      await Firebase.initializeApp(
        options: const FirebaseOptions(
            apiKey: 'test',
            appId: '1:1:android:1',
            messagingSenderId: '1',
            projectId: 'test'),
      );
      // ignore: unnecessary_statements
      FirebaseAuth.instance;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('arena_hub_dsp_mic'),
              (MethodCall call) async {
                if (call.method == 'isAvailable') return false;
                return null;
              });
    });

    tearDown(() {
      SupaDb.testFixtures = null;
    });

    test('send: creates a community_invite row (unit, fixtures)', () async {
      SupaDb.testFixtures = {
        'community_members': [],
        'user_notifications': [],
        'profiles': [
          {'firebase_uid': 'friend-1', 'display_name': 'Areeba', 'username': 'areeba'}
        ],
      };
      final res = await SupaDb.sendCommunityInvite(
        communityId: 'comm-1',
        communityName: 'TEST COMMUNITY',
        invitedUid: 'friend-1',
        inviterUid: 'test-uid',
        inviterName: 'Tester',
      );
      expect(res['ok'], isTrue);
      final rows = SupaDb.testFixtures!['user_notifications']!;
      expect(rows, hasLength(1));
      expect(rows.first['type'], 'community_invite');
      expect(rows.first['community_id'], 'comm-1');
      expect(rows.first['firebase_uid'], 'friend-1');
      expect(rows.first['title'], 'Community Invitation');
      // Duplicate blocked.
      final dup = await SupaDb.sendCommunityInvite(
        communityId: 'comm-1',
        communityName: 'TEST COMMUNITY',
        invitedUid: 'friend-1',
        inviterUid: 'test-uid',
      );
      expect(dup['ok'], isFalse);
      expect(SupaDb.testFixtures!['user_notifications'], hasLength(1));
      // Self-invite blocked.
      final self = await SupaDb.sendCommunityInvite(
        communityId: 'comm-1',
        communityName: 'TEST COMMUNITY',
        invitedUid: 'test-uid',
        inviterUid: 'test-uid',
      );
      expect(self['ok'], isFalse);
    });

    test('respond: Join adds membership + removes the row (unit)', () async {
      SupaDb.testFixtures = {
        'community_members': [],
        'user_notifications': [
          {
            'id': 'notif-1',
            'firebase_uid': 'friend-1',
            'type': 'community_invite',
            'community_id': 'comm-1',
          },
        ],
      };
      final res = await CommunityGroups.respondCommunityInvite(
        notificationId: 'notif-1',
        communityId: 'comm-1',
        response: 'accepted',
        uid: 'friend-1',
      );
      expect(res['ok'], isTrue);
      expect(
        SupaDb.testFixtures!['community_members'],
        hasLength(1),
      );
      expect(
        SupaDb.testFixtures!['community_members']!.first['firebase_uid'],
        'friend-1',
      );
      expect(SupaDb.testFixtures!['user_notifications'], isEmpty);
    });

    test('respond: Decline removes the row, no membership (unit)', () async {
      SupaDb.testFixtures = {
        'community_members': [],
        'user_notifications': [
          {
            'id': 'notif-1',
            'firebase_uid': 'friend-1',
            'type': 'community_invite',
            'community_id': 'comm-1',
          },
        ],
      };
      final res = await CommunityGroups.respondCommunityInvite(
        notificationId: 'notif-1',
        communityId: 'comm-1',
        response: 'declined',
        uid: 'friend-1',
      );
      expect(res['ok'], isTrue);
      expect(SupaDb.testFixtures!['community_members'], isEmpty);
      expect(SupaDb.testFixtures!['user_notifications'], isEmpty);
    });

    testWidgets('(a) no team -> INVITE still opens the picker, no toast',
        (tester) async {
      // No teams fixture at all — the old gate would toast.
      await _mountRoom(tester);
      // Settings sheet -> Invite row.
      await tester.tap(find.descendant(
          of: find.byType(UnifiedRoomPage),
          matching: find.text('Settings')));
      await _settleRoom(tester);
      expect(find.text('Invite'), findsOneWidget);
      await tester.tap(find.text('Invite'));
      await _settleRoom(tester);
      expect(find.byKey(const ValueKey('communityInvitePicker')),
          findsOneWidget);
      expect(find.text('Invite to TEST COMMUNITY'), findsOneWidget);
      // No team toast anywhere.
      expect(find.textContaining('Pehle team banayen'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('(b)+(c)+(d) friends list + username search + send',
        (tester) async {
      await _mountRoom(tester);
      // Seed friends + profiles AFTER mount (the picker loads on open).
      SupaDb.testFixtures!['friends'] = [
        {'user_uid': 'test-uid', 'friend_uid': 'friend-1'},
      ];
      SupaDb.testFixtures!['profiles'] = [
        {'firebase_uid': 'test-uid', 'display_name': 'Tester', 'username': 'tester', 'level': 1},
        {'firebase_uid': 'friend-1', 'display_name': 'Areeba', 'username': 'areeba', 'level': 2},
        {'firebase_uid': 'friend-2', 'display_name': 'Bilal', 'username': 'bilal', 'level': 3},
      ];
      SupaDb.testFixtures!['user_notifications'] = [];
      await tester.tap(find.descendant(
          of: find.byType(UnifiedRoomPage),
          matching: find.text('Settings')));
      await _settleRoom(tester);
      await tester.tap(find.text('Invite'));
      await _settleRoom(tester);
      expect(find.byKey(const ValueKey('communityInvitePicker')),
          findsOneWidget);
      // (b) the friends list renders.
      expect(find.text('Areeba'), findsOneWidget);
      expect(find.text('@areeba'), findsOneWidget);
      // (c) username search finds Bilal (not a friend).
      await tester.enterText(
          find.byWidgetPredicate((w) =>
              w is TextField &&
              (w.decoration?.hintText == 'Username se dhoondhen...')),
          'bilal');
      await tester.tap(find.text('Search'));
      await _settleRoom(tester);
      expect(find.text('Bilal'), findsOneWidget);
      // (d) Invite sends a real community_invite row.
      final inviteButtons = find.text('Invite');
      // Two Invite buttons now (Areeba + Bilal); tap Bilal's.
      final bilalRow = find.ancestor(
          of: find.text('Bilal'), matching: find.byType(Padding)).first;
      await tester.tap(find.descendant(
          of: bilalRow, matching: find.text('Invite')));
      await _settleRoom(tester);
      final rows = SupaDb.testFixtures!['user_notifications']!;
      expect(rows, hasLength(1));
      expect(rows.first['type'], 'community_invite');
      expect(rows.first['firebase_uid'], 'friend-2');
      expect(find.text('Invitation bhej di!'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('E4 enumeration — full-constructor scan (source)', () {
    test('every AppBar in lib/ is transparent (depth-aware scan)', () {
      final lib = Directory('${findProjectRoot().path}/lib');
      var total = 0;
      final offenders = <String>[];
      for (final entity in lib.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final code = codeOnly(entity.readAsStringSync());
        final lines = code.split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (!RegExp(r'\bAppBar\(').hasMatch(lines[i])) continue;
          if (lines[i].contains('AppBarTheme')) continue;
          total++;
          // Walk the FULL constructor (paren depth), not a fixed
          // window — backgroundColor can sit anywhere in it.
          // Only direct args count (depth 1); nested widgets'
          // colors (e.g. an AlertDialog in actions) do not.
          var depth = 0;
          var started = false;
          for (var j = i; j < lines.length; j++) {
            for (var k = 0; k < lines[j].length; k++) {
              final ch = lines[j][k];
              if (ch == '(') {
                depth++;
                started = true;
              } else if (ch == ')') {
                depth--;
              }
            }
            if (started && depth == 1 && j > i) {
              final bg = lines[j].indexOf('backgroundColor:');
              if (bg >= 0) {
                final value = lines[j].substring(bg).trim();
                if (!value
                    .startsWith('backgroundColor: Colors.transparent')) {
                  offenders.add(
                      '${entity.path.split('/lib/').last}:${j + 1}: $value');
                }
                break;
              }
            }
            if (started && depth <= 0) break;
          }
        }
      }
      expect(total, greaterThan(100),
          reason: 'enumeration sanity: expected 100+ AppBars, got $total');
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });
}
