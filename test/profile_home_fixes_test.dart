// PROFILE + SETTINGS + HOME + BADGE + PRESENCE FIXES (2026-11-22,
// Sameer's voice-call rounds 05:08-05:24, fixes round, build HOLD).
//
// Covers: Profile header gear overlap fix, XP track visibility, rank
// size/colour, tab cut-off, card-size tightening, Profile/Settings
// dedupe (final 05:18 placement map), wrong-screen fixes
// (ChangePasswordPage / PrivacyPage + shared PrivacyControlsCard),
// notification badge refresh (dismissed globals + notify signal),
// presence (PresenceDot label + empty guard, roster last seen +
// 30s refresh, friends/profile presence), Home spacing (welcome ->
// hero gap).
//
// Source-invariant tests read the lib files (fast, no pump); widget
// tests pump the real pages against SupaDb.testFixtures + the
// fake-Firebase pattern from profile_page_mockup18_test.dart (no
// network). No pumpAndSettle — ember/spark animations repeat forever.
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:protournament_user/components/arena_components.dart';
import 'package:protournament_user/screens/more_screens.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/screens/wallet_screens.dart';
import 'package:protournament_user/services/presence_service.dart';
import 'package:protournament_user/services/supabase_db.dart';

const _uid = 'profile-home-test-uid';

// ---------- fake Firebase (platform-interface fakes, same pattern as
// profile_page_mockup18_test.dart) ----------

class _FakeAppPlatform extends FirebaseAppPlatform {
  _FakeAppPlatform(super.name, super.options);
}

class _FakeCorePlatform extends FirebasePlatform {
  FirebaseAppPlatform? _app;

  @override
  Future<FirebaseAppPlatform> initializeApp({String? name, FirebaseOptions? options}) async {
    _app = _FakeAppPlatform(
      name ?? defaultFirebaseAppName,
      options ?? const FirebaseOptions(apiKey: 'test', appId: '1:1:android:1', messagingSenderId: '1', projectId: 'test'),
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
  FirebaseAuthPlatform delegateFor({required FirebaseApp app}) => _FakeAuthPlatform(appInstance: app);

  @override
  FirebaseAuthPlatform setInitialValues({PigeonUserDetails? currentUser, String? languageCode}) {
    final uid = currentUser?.userInfo.uid ?? _uid;
    _user = _FakeUser(
      this,
      _FakeMultiFactor(this),
      PigeonUserDetails(userInfo: PigeonUserInfo(uid: uid, isAnonymous: false, isEmailVerified: true), providerData: []),
    );
    return this;
  }

  @override
  UserPlatform? get currentUser => _user;

  @override
  set currentUser(UserPlatform? user) => _user = user;
}

// ---------- fixtures ----------

Map<String, List<Map<String, dynamic>>> _profileFixtures() => {
      'profiles': [
        {
          'firebase_uid': _uid,
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
      'match_history': [],
      'admin_config': [],
      'blocked_users': [],
      'presence': [],
    };

Future<void> _pump(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: page));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _src(String path) => File(path).readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUpAll(() async {
    // FIX 17: load the real Roboto so the 360px fit tests
    // measure what a real phone measures — the fallback
    // test font is ~2x wider and fakes an overflow
    // (same approach as fix22_watch_engagement_test.dart).
    await _loadRoboto();
    FirebasePlatform.instance = _FakeCorePlatform();
    FirebaseAuthPlatform.instance = _FakeAuthPlatform();
    await Firebase.initializeApp(
      options: const FirebaseOptions(apiKey: 'test', appId: '1:1:android:1', messagingSenderId: '1', projectId: 'test'),
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    SupaDb.testFixtures = _profileFixtures();
  });

  tearDown(() {
    SupaDb.testFixtures = null;
  });

  group('profile header gear overlap (source)', () {
    test('header SizedBox is full-width so the gear cannot sit on the title', () {
      final src = _src('lib/screens/more_screens.dart');
      // v2014: the SafeArea wrap re-indented this block by 2 (16 -> 18).
      expect(src.contains('height: 48,\n                  width: double.infinity,'), isTrue);
    });
  });

  group('XP bar + rank + tabs + card size (source)', () {
    test('XP track is a visible grey, 10px tall (not kCard)', () {
      final src = _src('lib/screens/more_screens.dart');
      expect(src.contains('Container(height: 10, decoration: BoxDecoration(color: const Color(0xFF2E323F)'), isTrue);
    });

    test('rank tier is white 24px with a 22px icon (mockup, not gold 36px)', () {
      final src = _src('lib/screens/more_screens.dart');
      // REDESIGN S9 (merged): the tier text now uses the contract
      // title style (white kText, 22 base) with a 24px override —
      // same white 24px, not the old inline TextStyle and never
      // gold 36px.
      expect(src.contains('Text(tier.toUpperCase(), style: kStyleTitle.copyWith(fontSize: 24'), isTrue);
      expect(src.contains('Icon(_rankTierIcon(tier), color: kGold, size: 22)'), isTrue);
    });

    test('tabs use FittedBox scaleDown so all three fit whole', () {
      final src = _src('lib/screens/more_screens.dart');
      expect(src.contains("Tab(child: FittedBox(fit: BoxFit.scaleDown, child: Text('Match History')))"), isTrue);
      expect(src.contains("Tab(child: FittedBox(fit: BoxFit.scaleDown, child: Text('Achievements')))"), isTrue);
    });

    test('stats grid tightened (value 32, label 13, cell padding 10)', () {
      final src = _src('lib/screens/more_screens.dart');
      expect(src.contains('padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4)'), isTrue);
      // REDESIGN S9 (merged): value + label now use the contract
      // text styles — same sizes (value gold 32 via kStyleTitle,
      // label 13 via kStyleMeta, which IS 13px), not inline
      // TextStyles any more.
      expect(src.contains('Text(value, style: kStyleTitle.copyWith(color: kGold, fontSize: 32'), isTrue);
      expect(src.contains('Text(label, style: kStyleMeta.copyWith(color: kText)'), isTrue);
    });
  });

  group('profile list dedupe (source)', () {
    test('moved-out tiles are gone from Profile', () {
      final src = _src('lib/screens/more_screens.dart');
      expect(src.contains("_tile(context, Icons.security, 'Account Security'"), isFalse);
      expect(src.contains("_tile(context, Icons.settings, 'Settings'"), isFalse);
      expect(src.contains("_tile(context, Icons.logout, 'Logout'"), isFalse);
      expect(src.contains("_tile(context, Icons.backup, 'Backup My Profile'"), isFalse);
      expect(src.contains("_tile(context, Icons.restore, 'Restore Profile"), isFalse);
      expect(src.contains("tr('Action Required', 'Action Required'), () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ActionRequiredPage()))),"), isFalse);
      expect(src.contains("_tile(context, Icons.public, tr('Country / Region'"), isFalse);
      expect(src.contains("_tile(context, Icons.language, tr('Language'"), isFalse);
      expect(src.contains("title: Text('Push Notifications'"), isFalse);
      expect(src.contains("_tile(context, Icons.description, 'Terms & Conditions'"), isFalse);
      expect(src.contains("_tile(context, Icons.privacy_tip, 'Privacy Policy'"), isFalse);
    });

    test('Rules & Policies tile lives on Profile (one entry, full page)', () {
      final src = _src('lib/screens/more_screens.dart');
      expect(src.contains("_tile(context, Icons.description, 'Rules & Policies', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RulesPoliciesPage())))"), isTrue);
    });

    test('Help & Support stays on Profile', () {
      final src = _src('lib/screens/more_screens.dart');
      expect(src.contains("_tile(context, Icons.headset_mic, 'Help & Support'"), isTrue);
    });
  });

  group('settings placement (source)', () {
    test('Settings gained Account Security / Action Required / Country / Backup / Restore rows', () {
      final src = _src('lib/screens/more_screens.dart');
      expect(src.contains("_row(context, Icons.security, 'Account Security'"), isTrue);
      expect(src.contains("_row(context, Icons.warning_amber_rounded, 'Action Required'"), isTrue);
      expect(src.contains("_row(context, Icons.public, 'Country / Region'"), isTrue);
      expect(src.contains("_row(context, Icons.backup, 'Backup My Profile', _backupProfile)"), isTrue);
      expect(src.contains("_row(context, Icons.restore, 'Restore Profile (Paste Backup)', _restoreProfile)"), isTrue);
    });

    test('Settings lost Help & Support + Terms & Privacy rows', () {
      final src = _src('lib/screens/more_screens.dart');
      expect(src.contains("_row(context, Icons.help, 'Help & Support'"), isFalse);
      expect(src.contains("_row(context, Icons.description, 'Terms & Privacy'"), isFalse);
    });

    test('Language row opens the REAL language page; the stub is deleted', () {
      final src = _src('lib/screens/more_screens.dart');
      expect(src.contains('const LanguageSettingsPage()'), isTrue);
      expect(src.contains('class LanguagePage'), isFalse);
    });
  });

  group('wrong-screen fixes (source)', () {
    test('Change Password + Privacy open their OWN pages, not Account Security', () {
      final src = _src('lib/screens/more_screens.dart');
      expect(src.contains("'Change Password', () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChangePasswordPage(uid: uid)))"), isTrue);
      expect(src.contains("'Privacy', () => Navigator.push(context, MaterialPageRoute(builder: (_) => PrivacyPage(uid: uid)))"), isTrue);
      expect(src.contains("'Change Password', () => Navigator.push(context, MaterialPageRoute(builder: (_) => AccountSecurityPage(uid: uid)))"), isFalse);
      expect(src.contains("'Privacy', () => Navigator.push(context, MaterialPageRoute(builder: (_) => AccountSecurityPage(uid: uid)))"), isFalse);
    });

    test('dedicated pages + shared privacy card exist and the card is used twice', () {
      final src = _src('lib/screens/more_screens.dart');
      expect(src.contains('class PrivacyPage extends StatelessWidget'), isTrue);
      expect(src.contains('class ChangePasswordPage extends StatefulWidget'), isTrue);
      expect(src.contains('class PrivacyControlsCard extends StatefulWidget'), isTrue);
      expect('PrivacyControlsCard(uid: widget.uid)'.allMatches(src).length, 1);
      expect('PrivacyControlsCard(uid: uid)'.allMatches(src).length, 1);
    });
  });

  group('notification badge fix (source)', () {
    test('unreadCount excludes dismissed globals; notify signal exists + is wired', () {
      final src = _src('lib/services/supabase_db.dart');
      expect(src.contains("dismissed_global_notifs_"), isTrue);
      expect(src.contains('static void notifyUnreadChanged()'), isTrue);
      expect(src.contains('_unreadRefreshController.stream.listen((_) => recompute())'), isTrue);
      expect(src.contains('notifyUnreadChanged();'), isTrue); // markNotificationsRead
    });

    test('delete paths notify the badge (bulk + swipe)', () {
      final src = _src('lib/screens/more_screens.dart');
      expect('SupaDb.notifyUnreadChanged()'.allMatches(src).length, 2);
    });
  });

  group('presence wiring (source)', () {
    test('PresenceDot has a label mode + a never-seen guard', () {
      final src = _src('lib/services/presence_service.dart');
      expect(src.contains('final bool showLabel;'), isTrue);
      expect(src.contains("last == 0 ? 'Last seen —'"), isTrue);
    });

    test('roster card carries lastSeenMs; detail + chat pages refresh presence on a timer', () {
      final src = _src('lib/screens/pro_features.dart');
      expect(src.contains('final int lastSeenMs;'), isTrue);
      expect(src.contains('lastSeenMs: SupaDb.parseTs(pres['), isTrue);
      expect(src.contains('_presenceTimer = Timer.periodic(const Duration(seconds: 30), (_) => _refreshPresence())'), isTrue);
      expect(src.contains('_presenceTimer = Timer.periodic(const Duration(seconds: 30), (_) => _refreshOnlineCount())'), isTrue);
    });

    test('friends rows + public profiles show presence', () {
      final src = _src('lib/screens/community_screens.dart');
      expect(src.contains('PresenceDot(uid: SupaDb.strOf(profile['), isTrue);
      expect(src.contains('PresenceDot(uid: widget.targetUid, showLastSeen: true, showLabel: true)'), isTrue);
    });
  });

  group('home spacing (source)', () {
    test('welcome -> hero gap is 2 and header -> greeting gap is 10', () {
      final src = _src('lib/screens/home_screens.dart');
      expect(src.contains('const SizedBox(height: 2),\n                          // Wave 4 design-match (#37) hero'), isTrue);
    });

    test('v2014: hero lifts 18dp via Transform (never a negative margin); box 204 without a character', () {
      final src = _src('lib/screens/home_screens.dart');
      // Container asserts margin.isNonNegative — a negative-margin tuck
      // crashes the build (proven 2026-11-22: 7 test failures). The lift
      // must be a Transform, and no negative margin may exist.
      expect(src.contains('EdgeInsets.only(top: -'), isFalse);
      expect(src.contains('offset: const Offset(0, -18),'), isTrue);
      expect(src.contains("sliders.any((s) => strVal(s['character_image_url']).isNotEmpty)"), isTrue);
      expect(src.contains('height: _kHeroBannerHeight,'), isTrue);
    });

    test('2026-11-23: TOURNAMENTS gaps shrink WITHOUT moving the hero', () {
      final src = _src('lib/screens/home_screens.dart');
      // User order: hero→header visual 12dp, header→chips visual 10dp,
      // hero untouched (lift stays -18, empty-card padding stays 18).
      // The header translates up 8dp into the dead space below the
      // painted hero; the header→chips SizedBox is 2dp (8 + 2 = 10).
      // (An earlier attempt changed the lift to -10 and grew the black
      // band above the slider; the user rejected it.)
      expect(src.contains('offset: const Offset(0, -18),'), isTrue);
      expect(src.contains('offset: const Offset(0, -8),'), isTrue);
      expect(src.contains('EdgeInsets.only(bottom: 18)'), isTrue);
      expect(src.contains('const SizedBox(height: 17),'), isFalse);
    });

    test('hero + tournament card + next-match structure is mockup-complete', () {
      final src = _src('lib/screens/home_screens.dart');
      expect(src.contains('_regOpenPill()'), isTrue);
      expect(src.contains("_heroMetaRow("), isTrue);
      expect(src.contains("Text('VIEW EVENT'"), isTrue);
      expect(src.contains('height: 142,'), isTrue);
      expect(src.contains("child: Text('Details'"), isTrue);
      expect(src.contains('_primaryButton('), isTrue);
      expect(src.contains("child: Text('Your Next Match'"), isTrue);
    });
  });

  group('TeamMemberCard last seen (widget)', () {
    Future<void> pumpCard(WidgetTester tester, {required bool online, int lastSeenMs = 0}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TeamMemberCard(name: 'Test Member', uidLine: 'UID: 123456', roleText: 'Member', isCaptain: false, online: online, lastSeenMs: lastSeenMs),
        ),
      ));
      await tester.pump();
    }

    testWidgets('offline + never seen shows Last seen — (never a 1970 date)', (tester) async {
      await pumpCard(tester, online: false, lastSeenMs: 0);
      expect(find.text('OFFLINE'), findsOneWidget);
      expect(find.text('Last seen —'), findsOneWidget);
      expect(find.textContaining('1970'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('offline + 5 min ago shows Last seen 5m ago', (tester) async {
      final fiveMinAgo = DateTime.now().millisecondsSinceEpoch - 5 * 60 * 1000;
      await pumpCard(tester, online: false, lastSeenMs: fiveMinAgo);
      expect(find.text('OFFLINE'), findsOneWidget);
      expect(find.text('Last seen 5m ago'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('online shows ONLINE with no last-seen line', (tester) async {
      await pumpCard(tester, online: true);
      expect(find.text('ONLINE'), findsOneWidget);
      expect(find.textContaining('Last seen'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('PresenceDot (widget)', () {
    Future<void> pumpDot(WidgetTester tester, String uid) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: PresenceDot(uid: uid, showLastSeen: true, showLabel: true)),
      ));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('no presence row reads Last seen —', (tester) async {
      SupaDb.testFixtures = {'presence': []};
      await pumpDot(tester, 'ghost-uid');
      expect(find.text('Last seen —'), findsOneWidget);
      expect(find.textContaining('1970'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fresh heartbeat reads Online', (tester) async {
      SupaDb.testFixtures = {
        'presence': [
          {'firebase_uid': 'online-uid', 'last_seen': DateTime.now().toIso8601String()},
        ],
      };
      await pumpDot(tester, 'online-uid');
      expect(find.text('Online'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('stale heartbeat reads last seen 5m ago', (tester) async {
      SupaDb.testFixtures = {
        'presence': [
          {'firebase_uid': 'stale-uid', 'last_seen': DateTime.now().subtract(const Duration(minutes: 5)).toIso8601String()},
        ],
      };
      await pumpDot(tester, 'stale-uid');
      expect(find.text('last seen 5m ago'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('notification badge count (unit)', () {
    test('unreadCount excludes dismissed globals', () async {
      final now = DateTime.now();
      SupaDb.testFixtures = {
        'profiles': [
          {'firebase_uid': _uid, 'display_name': 'T', 'last_checked_notifications': 0},
        ],
        'notifications': [
          {'id': 'g1', 'title': 'Global 1', 'created_at': now.toIso8601String()},
          {'id': 'g2', 'title': 'Global 2', 'created_at': now.toIso8601String()},
        ],
        'user_notifications': [],
      };
      expect(await SupaDb.unreadCount(_uid), 2);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('dismissed_global_notifs_$_uid', ['g1']);
      expect(await SupaDb.unreadCount(_uid), 1);
      await prefs.setStringList('dismissed_global_notifs_$_uid', ['g1', 'g2']);
      expect(await SupaDb.unreadCount(_uid), 0);
    });

    test('notifyUnreadChanged makes the badge stream re-emit the new count', () async {
      final now = DateTime.now();
      SupaDb.testFixtures = {
        'profiles': [
          {'firebase_uid': _uid, 'display_name': 'T', 'last_checked_notifications': 0},
        ],
        'notifications': [
          {'id': 'g1', 'title': 'Global 1', 'created_at': now.toIso8601String()},
        ],
        'user_notifications': [],
      };
      final seen = <int>[];
      final sub = SupaDb.streamUnreadCount(_uid).listen(seen.add);
      // Let the initial recompute land.
      await Future.delayed(const Duration(milliseconds: 300));
      expect(seen, contains(1));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('dismissed_global_notifs_$_uid', ['g1']);
      SupaDb.notifyUnreadChanged();
      await Future.delayed(const Duration(milliseconds: 300));
      await sub.cancel();
      expect(seen, contains(0));
    });
  });

  group('profile page at 360px (widget)', () {
    testWidgets('gear is top-right (not on the title) and all three tabs render', (tester) async {
      await _pump(tester, ProfilePage(uid: _uid));
      expect(find.text('PROFILE'), findsOneWidget);
      final titleCenter = tester.getCenter(find.text('PROFILE'));
      expect(titleCenter.dx, closeTo(180, 12));
      final gearCenter = tester.getCenter(find.byIcon(Icons.settings_outlined));
      expect(gearCenter.dx, greaterThan(300));
      expect(find.text('Overview'), findsOneWidget);
      expect(find.text('Match History'), findsWidgets);
      expect(find.text('Achievements'), findsWidgets);
      // XP text is two Text widgets ('0' + ' / 100 XP').
      expect(find.text(' / 100 XP'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('settings navigation (widget)', () {
    testWidgets('Change Password opens its own page', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      await tester.ensureVisible(find.text('Change Password'));
      await tester.tap(find.text('Change Password'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(ChangePasswordPage), findsOneWidget);
      expect(find.text('Send Reset Link'), findsOneWidget);
      expect(find.byType(AccountSecurityPage), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Privacy opens its own page with the three toggles', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      // Privacy sits in group 3, below the fold: the ListView builds
      // lazily, so drag until it exists, let the scroll settle, then
      // tap it. (Without the settle pump the tap lands mid-scroll
      // and the row never receives it.)
      await tester.scrollUntilVisible(find.text('Privacy'), 200);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Privacy'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(PrivacyPage), findsOneWidget);
      expect(find.text('Profile Visibility'), findsOneWidget);
      expect(find.text('Show Game ID'), findsOneWidget);
      expect(find.text('Show Match History'), findsOneWidget);
      expect(find.text('Blocked Players'), findsOneWidget);
      expect(find.byType(AccountSecurityPage), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Account Security row opens Account Security', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      await tester.ensureVisible(find.text('Account Security'));
      await tester.tap(find.text('Account Security'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(AccountSecurityPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Help & Support and Terms & Privacy are gone from Settings', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      expect(find.text('Help & Support'), findsNothing);
      expect(find.text('Terms & Privacy'), findsNothing);
      // Backup rows live in group 5, below the fold: scroll first.
      await tester.scrollUntilVisible(find.text('Backup My Profile'), 200);
      expect(find.text('Backup My Profile'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Restore Profile (Paste Backup)'), 200);
      expect(find.text('Restore Profile (Paste Backup)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('privacy + change-password pages (widget)', () {
    testWidgets('PrivacyPage renders the shared card standalone', (tester) async {
      await _pump(tester, PrivacyPage(uid: _uid));
      expect(find.text('PRIVACY'), findsOneWidget);
      expect(find.text('Profile Visibility'), findsOneWidget);
      expect(find.text('Blocked Players'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ChangePasswordPage renders title + send button', (tester) async {
      await _pump(tester, ChangePasswordPage(uid: _uid));
      expect(find.text('CHANGE PASSWORD'), findsOneWidget);
      expect(find.text('Send Reset Link'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('gold rule (source scan)', () {
    test('kGold and every gold token are #FDC903', () {
      final theme = _src('lib/theme.dart');
      expect(theme.contains('Color get kGold => appLightMode ? const Color(0xFFFDC903) : const Color(0xFFFDC903);'), isTrue);
      expect(theme.contains('const Color kGoldDeep = Color(0xFFFDC903);'), isTrue);
      expect(theme.contains('const Color kGoldBright = Color(0xFFFDC903);'), isTrue);
      expect(theme.contains('const Color kSectionLabel = Color(0xFFFDC903);'), isTrue);
    });

    test('no old yellow shade survives anywhere in lib/', () {
      // GOLD RULE (Sameer 2026-11-22 05:28): only #FDC903. This scans
      // every .dart file under lib/ for the retired shades (old app
      // gold, mockup gold, material amber/yellow, light yellows, the
      // glow yellow, the Google yellow) and fails naming the file.
      const forbidden = ['FFE20A', 'FFCC00', 'FFD700', 'FFC107', 'FFE066', 'FFD97A', 'FFD500', 'FBBC05', 'Colors.amber', 'Colors.yellow'];
      final offenders = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        // FBBC05 EXCLUSION (step-4 close): skip the Google "G" logo painter
        // in arena_gaming_widgets.dart — Google's trademark brand colors are
        // third-party brand assets, not app design colors; the painter must
        // use Google's exact brand colors (0xFFFBBC05 is the "G" yellow arc).
        if (e.path == 'lib/widgets/arena_gaming_widgets.dart') continue;
        var src = e.readAsStringSync();
        // FFD700 EXCLUSION (merge step 8): the royalGold design token in
        // arena_theme.dart (:68 definition + :58 comment) is item 31's
        // deliberate AI Studio design gold — it applies AS-IS ("same
        // lagao") inside the voice room screen, same precedent as the
        // FBBC05 exclusion above. Only the royalGold lines are dropped
        // from the scan; FFD700 stays forbidden everywhere else.
        if (e.path == 'lib/theme/arena_theme.dart') {
          src = src.split('\n').where((l) => !l.contains('royalGold')).join('\n');
        }
        for (final f in forbidden) {
          if (src.contains(f)) offenders.add('${e.path} contains $f');
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });

  group('wallet icon size (source)', () {
    test('home header wallet icon is 18 (was 14)', () {
      final src = _src('lib/main.dart');
      expect(src.contains('Icon(Icons.account_balance_wallet,'), isTrue);
      expect(src.contains('color: kGold, size: 18)'), isTrue);
      expect(src.contains('color: kGold, size: 14)'), isFalse);
    });
  });

  group('wallet add/withdraw toggle (source + widget)', () {
    test('the pair is a state-driven toggle, not two fixed styles', () {
      final src = _src('lib/screens/wallet_screens.dart');
      expect(src.contains('int _activeAction = 0;'), isTrue);
      expect(src.contains("Widget _actionButton({"), isTrue);
      expect(src.contains('final active = _activeAction == index;'), isTrue);
      expect(src.contains('setState(() => _activeAction = index);'), isTrue);
      expect(src.contains("label: 'Add Amount',\n                          onPressed: () => Navigator.push"), isTrue);
    });

    testWidgets('tapping Withdraw moves the gold fill from Add to Withdraw', (tester) async {
      await _pump(tester, Scaffold(body: WalletPage(uid: _uid)));
      // Initially Add Amount is the filled gold button, Withdraw the
      // outlined one.
      expect(find.ancestor(of: find.text('Add Amount'), matching: find.byType(GoldButton)), findsOneWidget);
      expect(find.ancestor(of: find.text('Withdraw'), matching: find.byType(OutlineButton)), findsOneWidget);
      await tester.tap(find.text('Withdraw'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The highlight moved: Withdraw is gold-filled now, Add Amount
      // is the outlined one. (The withdraw dialog may also be open —
      // it does not affect the buttons underneath.)
      expect(find.ancestor(of: find.text('Withdraw'), matching: find.byType(GoldButton)), findsOneWidget);
      expect(find.ancestor(of: find.text('Add Amount'), matching: find.byType(OutlineButton)), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('events filter rules (source)', () {
    test('fee group stays exactly-one single-select', () {
      final src = _src('lib/screens/home_screens.dart');
      expect(src.contains("String _feeFilter = 'any'; // any | free | paid"), isTrue);
      // REDESIGN S3 (merged): the fee chips are ArenaFilterChip now,
      // so the callback is onTap, not onSelected — the semantics are
      // identical (tap sets the filter directly, no toggle-to-null).
      expect(src.contains("onTap: () => setState(() => _feeFilter = f['k']!))"), isTrue);
      expect(src.contains("selected: _feeFilter == f['k'],"), isTrue);
    });

    test('sort group is optional: nullable, toggles, null on clear', () {
      final src = _src('lib/screens/home_screens.dart');
      expect(src.contains('String? _sort; // null | date | prize | fee'), isTrue);
      expect(src.contains("setState(() => _sort = _sort == s['k'] ? null : s['k']!)"), isTrue);
      expect(src.contains("} else if (_sort == 'date') {"), isTrue);
      expect("_sort = null;".allMatches(src).length, 2); // both clear-filters resets
      expect(src.contains("_sort = 'date';"), isFalse);
    });
  });
}

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
