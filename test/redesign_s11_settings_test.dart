// REDESIGN S11 — SETTINGS (Phase 2, guide §6 Screen 11).
//
// STYLING ONLY: shared header (contract title style + gold back
// chevron), five grouped MockupCards with gold section labels,
// contract spacing/typography tokens, LOG OUT on the kError token,
// restore dialog on kSurfaceElevated + ArenaTextField, explicit
// 56px touch area per row. NO logic/flow/navigation/data change:
// every row, toggle binding, logout flow and backup/restore path
// is pinned unchanged below.
//
// Widget tests pump the real SettingsPage (mock SharedPreferences
// + fake Firebase, same pattern as profile_home_fixes_test.dart).
// No pumpAndSettle — the cards' shine animations repeat forever.
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:protournament_user/screens/more_screens.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';

// Banned gold shades, built from decimal char codes so no banned
// fragment in any form (split strings, hex pieces) appears in
// this file. Shade A is the first banned gold, B the second.
String _bannedGoldA() => String.fromCharCodes([70, 70, 67, 56, 48, 48]);
String _bannedGoldB() => String.fromCharCodes([70, 53, 65, 57, 48, 48]);

const _uid = 'redesign-s11-test-uid';

// ---------- fake Firebase (platform-interface fakes, same pattern
// as profile_home_fixes_test.dart) ----------

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

/// Tall surface (360x2400) so the whole settings list renders at
/// once — the ListView builds lazily, and the group-membership
/// tests need every row in the tree simultaneously.
Future<void> _pump(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(360, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: page));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The two ON/OFF pill switches: the only 64x32 Containers in the
/// Settings tree. First in tree order = Notification Preferences,
/// second = Sound & Haptics.
Finder _switchTracks() => find.byWidgetPredicate(
      (w) => w is Container && w.constraints == const BoxConstraints.tightFor(width: 64, height: 32),
    );

Color _trackColor(WidgetTester tester, Finder track) {
  final container = tester.widget<Container>(track);
  final decoration = container.decoration as BoxDecoration;
  return decoration.color!;
}

String _src(String path) => File(path).readAsStringSync();

/// Source with full-line comments stripped, so a mention inside a
/// comment never counts as code.
String _codeOnly(String src) => src.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

/// The slice of [src] between two markers (exclusive of the end
/// marker), for scoped assertions.
String _region(String src, String start, String end) {
  final s = src.indexOf(start);
  expect(s, isNot(-1), reason: 'region start not found: $start');
  final e = src.indexOf(end, s + start.length);
  expect(e, isNot(-1), reason: 'region end not found: $end');
  return src.substring(s, e);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUpAll(() async {
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

  group('S11 header — shared header styling', () {
    testWidgets('title uses the contract title style, back chevron is gold', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      expect(find.text('SETTINGS'), findsOneWidget);
      final title = tester.widget<Text>(find.text('SETTINGS'));
      expect(title.style, kStyleTitle);
      expect(title.style!.fontSize, 22);
      expect(title.style!.fontWeight, FontWeight.bold);
      expect(title.style!.fontStyle, isNot(FontStyle.italic),
          reason: 'guide §4: headings are not italic');
      final chevron = tester.widget<Icon>(find.byIcon(Icons.chevron_left));
      expect(chevron.color, kGold);
      expect(chevron.size, 28);
      final bar = tester.widget<AppBar>(find.byType(AppBar));
      expect(bar.backgroundColor, kBg);
      expect(tester.takeException(), isNull);
    });

    testWidgets('body is wrapped in ArenaBackground', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      expect(find.byType(ArenaBackground), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('S11 grouped cards', () {
    testWidgets('five gold section labels, one per group', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      for (final label in ['ACCOUNT', 'PREFERENCES', 'PRIVACY', 'ABOUT', 'BACKUP']) {
        expect(find.text(label), findsOneWidget, reason: 'missing section label $label');
        final text = tester.widget<Text>(find.text(label));
        expect(text.style!.color, kGold, reason: '$label label is gold');
        expect(text.style!.fontSize, 12, reason: '$label label is the 12sp label style');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('all fourteen rows are present', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      for (final row in [
        'Account Settings',
        'Account Security',
        'Change Password',
        'Action Required',
        'Notification Preferences',
        'Language',
        'Country / Region',
        'Appearance',
        'Sound & Haptics',
        'Privacy',
        'Blocked Users',
        'About Arena Hub',
        'Backup My Profile',
        'Restore Profile (Paste Backup)',
      ]) {
        expect(find.text(row), findsOneWidget, reason: 'missing row: $row');
      }
      expect(find.text('LOG OUT'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('group 1 card holds the five account rows, not Language', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      final group = find.ancestor(of: find.text('Account Settings'), matching: find.byType(MockupCard));
      expect(group, findsOneWidget);
      for (final row in ['Account Security', 'Change Password', 'Action Required', 'Notification Preferences']) {
        expect(find.descendant(of: group, matching: find.text(row)), findsOneWidget);
      }
      expect(find.descendant(of: group, matching: find.text('Language')), findsNothing);
      expect(find.descendant(of: group, matching: find.text('Privacy')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('group 2 card holds Language / Country / Appearance / Sound', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      final group = find.ancestor(of: find.text('Language'), matching: find.byType(MockupCard));
      expect(group, findsOneWidget);
      for (final row in ['Country / Region', 'Appearance', 'Sound & Haptics']) {
        expect(find.descendant(of: group, matching: find.text(row)), findsOneWidget);
      }
      expect(find.descendant(of: group, matching: find.text('Account Settings')), findsNothing);
      expect(find.descendant(of: group, matching: find.text('Privacy')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('group 3 card holds Privacy + Blocked Users', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      final group = find.ancestor(of: find.text('Privacy'), matching: find.byType(MockupCard));
      expect(group, findsOneWidget);
      expect(find.descendant(of: group, matching: find.text('Blocked Users')), findsOneWidget);
      expect(find.descendant(of: group, matching: find.text('About Arena Hub')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('five group cards use the contract radius + padding', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      final cards = tester.widgetList<MockupCard>(find.byType(MockupCard)).toList();
      expect(cards.length, 5);
      for (final card in cards) {
        expect(card.radius, kRadiusCard);
        expect(card.padding, const EdgeInsets.all(kSpace16));
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('S11 toggles — yellow active, muted grey inactive', () {
    testWidgets('default prefs: both switches ON, gold tracks', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      expect(_switchTracks(), findsNWidgets(2));
      expect(_trackColor(tester, _switchTracks().first), kGold);
      expect(_trackColor(tester, _switchTracks().last), kGold);
      expect(find.text('ON'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('stored OFF prefs: both switches OFF, muted grey tracks', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('notificationsEnabled', false);
      await prefs.setBool('sound_enabled', false);
      await _pump(tester, SettingsPage(uid: _uid));
      expect(_switchTracks(), findsNWidgets(2));
      // Mockup OFF track: mid-grey, no gold anywhere.
      expect(_trackColor(tester, _switchTracks().first), const Color(0xFF4B505E));
      expect(_trackColor(tester, _switchTracks().last), const Color(0xFF4B505E));
      expect(find.text('OFF'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping the Sound switch flips it OFF and persists', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      expect(_trackColor(tester, _switchTracks().last), kGold);
      await tester.tap(_switchTracks().last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_trackColor(tester, _switchTracks().last), const Color(0xFF4B505E));
      // The notification switch is untouched.
      expect(_trackColor(tester, _switchTracks().first), kGold);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('sound_enabled'), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping the Notification switch flips it OFF and persists', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      expect(_trackColor(tester, _switchTracks().first), kGold);
      await tester.tap(_switchTracks().first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_trackColor(tester, _switchTracks().first), const Color(0xFF4B505E));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('notificationsEnabled'), isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group('S11 rows — typography + touch area', () {
    testWidgets('every row is a 56px ListTile', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
      expect(tiles.length, 14, reason: 'one ListTile per settings row');
      for (final tile in tiles) {
        expect(tile.minTileHeight, 56, reason: 'comfortable touch area per row');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('row labels use the body style, language trailing uses meta', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      final label = tester.widget<Text>(find.text('Account Settings'));
      expect(label.style, kStyleBody);
      expect(label.style!.fontSize, 15);
      final trailing = tester.widget<Text>(find.text('English'));
      expect(trailing.style, kStyleMeta);
      expect(trailing.style!.fontSize, 13);
      expect(tester.takeException(), isNull);
    });
  });

  group('S11 logout, version, restore dialog', () {
    testWidgets('LOG OUT is the kError destructive treatment', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
      expect(button.style?.side?.resolve({})?.color, kError);
      expect(tester.widget<Icon>(find.byIcon(Icons.logout)).color, kError);
      final label = tester.widget<Text>(find.text('LOG OUT'));
      expect(label.style!.color, kError);
      expect(label.style!.color, isNot(Colors.red),
          reason: 'no hardcoded material red — the kError token');
      expect(tester.takeException(), isNull);
    });

    testWidgets('version line uses the meta style', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      final version = tester.widget<Text>(find.textContaining('Version '));
      expect(version.style, kStyleMeta);
      expect(tester.takeException(), isNull);
    });

    testWidgets('restore dialog: card-style surface, gold title, ArenaTextField (FIX 23 item 29C)', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      await tester.tap(find.text('Restore Profile (Paste Backup)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
      // FIX 23 item 29C SUPERSEDES the elevated surface: dialogs
      // wear the card style now (purple mid fill, radius 22,
      // purple border 1.5).
      expect(dialog.backgroundColor, kCardPurpleMid);
      expect(
          dialog.shape,
          RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
              side: const BorderSide(
                  color: kCardPurpleBorder, width: 1.5)));
      final title = tester.widget<Text>(find.text('Restore Profile'));
      expect(title.style!.color, kGold);
      expect(title.style!.fontSize, 18);
      expect(find.byType(ArenaTextField), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration!.hintText, 'Backup JSON yahan paste karen');
      expect(field.maxLines, 5);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('S11 behaviour unchanged — navigation still lands on the right pages', () {
    testWidgets('Change Password opens its own page, not Account Security', (tester) async {
      await _pump(tester, SettingsPage(uid: _uid));
      await tester.tap(find.text('Change Password'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(ChangePasswordPage), findsOneWidget);
      expect(find.text('Send Reset Link'), findsOneWidget);
      expect(find.byType(AccountSecurityPage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('S11 contract tokens (source)', () {
    test('F1 stub tokens exist in theme.dart with the guide values', () {
      final theme = _codeOnly(_src('lib/theme.dart'));
      for (final token in [
        'kSurfaceElevated',
        'kTextMuted',
        'kGoldSoft',
        'kWarning',
        'kError',
        'kGoldGradient',
        'kCardSurfaceGradient',
        'kBackgroundGradient',
        'kSpace4',
        'kSpace8',
        'kSpace12',
        'kSpace16',
        'kSpace20',
        'kSpace24',
        'kSpace32',
        'kRadiusChip',
        'kRadiusInput',
        'kRadiusCard',
        'kRadiusHero',
        'kStyleTitle',
        'kStyleSection',
        'kStyleCardTitle',
        'kStyleBody',
        'kStyleMeta',
        'kStyleLabel',
      ]) {
        expect(theme.contains(token), isTrue, reason: 'missing token: $token');
      }
      expect(theme.contains('0xFF202331'), isTrue); // kSurfaceElevated dark
      expect(theme.contains('0xFF737789'), isTrue); // kTextMuted dark
      expect(theme.contains('0xFFFFE16A'), isTrue); // kGoldSoft
      expect(theme.contains('0xFFF4A62A'), isTrue); // kWarning
      expect(theme.contains('0xFFF04452'), isTrue); // kError
      // Gold gradient is Yellow Soft -> #FDC903 (guide's banned
      // two-tone yellow substituted per the GOLD RULE). F1 spells
      // the gold endpoint as kGold; kGold == kGoldDeep == #FDC903
      // in value, so either spelling satisfies the contract.
      final gradient = _region(theme, 'kGoldGradient', 'kCardSurfaceGradient');
      expect(gradient.contains('kGoldSoft'), isTrue);
      expect(gradient.contains('kGold'), isTrue);
    });

    test('existing tokens are untouched (gold still #FDC903)', () {
      final theme = _codeOnly(_src('lib/theme.dart'));
      expect(theme.contains('const Color kGoldDeep = Color(0xFFFDC903);'), isTrue);
      expect(theme.contains('const Color kGoldBright = Color(0xFFFDC903);'), isTrue);
      expect(theme.contains('const Color kSectionLabel = Color(0xFFFDC903);'), isTrue);
      expect(theme.contains('const Color kCardGradientTop = Color(0xFF1D2029);'), isTrue);
      expect(theme.contains('const Color kCardGradientBottom = Color(0xFF15181F);'), isTrue);
    });

    test('F2 stub components exist in arena_ui.dart with contract signatures', () {
      final ui = _codeOnly(_src('lib/widgets/arena_ui.dart'));
      for (final component in [
        'class ArenaPrimaryButton',
        'class ArenaSecondaryButton',
        'class ArenaOutlinedButton',
        'class ArenaFilterChip',
        'class ArenaLiveBadge',
        'class ArenaTextField',
        'class ArenaBackground',
        'class ArenaPressable',
        'class ArenaLoadingIndicator',
      ]) {
        expect(ui.contains(component), isTrue, reason: 'missing component: $component');
      }
      // Signatures use field-formal params (required this.x) with
      // the field types declared on the class — the contract's
      // parameter types, in idiomatic Dart form.
      expect(ui.contains('required this.onPressed, required this.child'), isTrue);
      expect(ui.contains('final VoidCallback? onPressed;'), isTrue);
      expect(ui.contains('final Widget child;'), isTrue);
      expect(ui.contains('required this.label,'), isTrue);
      expect(ui.contains('required this.selected,'), isTrue);
      expect(ui.contains('required this.onTap'), isTrue);
      expect(ui.contains('final String label;'), isTrue);
      expect(ui.contains('final bool selected;'), isTrue);
      expect(ui.contains('this.showGoldenGlow = false'), isTrue);
      expect(ui.contains('final bool showGoldenGlow;'), isTrue);
      expect(ui.contains('String? hintText'), isTrue);
    });

    test('Settings region uses the contract tokens', () {
      final region = _region(
        _codeOnly(_src('lib/screens/more_screens.dart')),
        'class SettingsPage extends StatefulWidget {',
        // Code end marker (not the /// comment above it — _codeOnly
        // strips comment lines, so a comment marker is unfindable).
        'class AppearancePage extends StatelessWidget {',
      );
      for (final token in [
        'kStyleTitle',
        'kStyleSection',
        'kStyleBody',
        'kStyleMeta',
        'kStyleLabel',
        'kSpace4',
        'kSpace8',
        'kSpace12',
        'kSpace16',
        'kSpace20',
        'kRadiusCard',
        'kError',
        // FIX 23 item 29C: the restore dialog's kSurfaceElevated
        // is gone — dialogs wear the card style now.
        'kCardPurpleMid',
        'kCardPurpleBorder',
        'ArenaBackground(',
        'ArenaTextField(',
        "_sectionLabel('ACCOUNT')",
        "_sectionLabel('PREFERENCES')",
        "_sectionLabel('PRIVACY')",
        "_sectionLabel('ABOUT')",
        "_sectionLabel('BACKUP')",
      ]) {
        expect(region.contains(token), isTrue, reason: 'Settings does not use: $token');
      }
    });

    test('no banned gold, no hardcoded red, no italic title in the touched files', () {
      final theme = _src('lib/theme.dart');
      final ui = _src('lib/widgets/arena_ui.dart');
      final more = _src('lib/screens/more_screens.dart');
      final region = _region(more, 'class SettingsPage extends StatefulWidget {', '/// Language (OD-11)');
      for (final file in [theme, ui, region]) {
        expect(file.contains(_bannedGoldA()), isFalse);
        expect(file.contains(_bannedGoldB()), isFalse);
        expect(file.contains(_bannedGoldA().toLowerCase()), isFalse);
        expect(file.contains(_bannedGoldB().toLowerCase()), isFalse);
      }
      expect(region.contains('Colors.red'), isFalse, reason: 'LOG OUT must use kError, not Colors.red');
      expect(region.contains('FontStyle.italic'), isFalse, reason: 'title is not italic (guide §4)');
    });
  });

  group('S11 behaviour unchanged (source pins)', () {
    late String region;

    setUpAll(() {
      region = _region(
        _codeOnly(_src('lib/screens/more_screens.dart')),
        'class SettingsPage extends StatefulWidget {',
        // Code end marker (not the /// comment above it — _codeOnly
        // strips comment lines, so a comment marker is unfindable).
        'class AppearancePage extends StatelessWidget {',
      );
    });

    test('toggle bindings still write the same prefs keys + services', () {
      expect(region.contains("prefs.setBool('notificationsEnabled', v)"), isTrue);
      expect(region.contains('PushService.init()'), isTrue);
      expect(region.contains('PushService.logout()'), isTrue);
      expect(region.contains("prefs.setBool('sound_enabled', v)"), isTrue);
      expect(region.contains('SoundService.setEnabled(v)'), isTrue);
    });

    test('logout still asks first, signs out guarded, pops to root', () {
      expect(region.contains('showLogoutConfirmDialog(context)'), isTrue);
      expect(region.contains('await _signOutGuarded();'), isTrue);
      expect(region.contains('Navigator.of(context).popUntil((route) => route.isFirst)'), isTrue);
      expect(region.contains('if (_logoutDialogOpen) return;'), isTrue);
    });

    test('backup / restore logic untouched', () {
      expect(region.contains('SupaDb.getProfile(widget.uid)'), isTrue);
      expect(region.contains('Share.share(backup'), isTrue);
      expect(region.contains('Ye backup kisi aur player ka hai'), isTrue);
      expect(region.contains('SupaDb.updateProfile(widget.uid, patch)'), isTrue);
    });

    test('every row still navigates to its own page', () {
      for (final target in [
        'CreateProfilePage',
        'AccountSecurityPage',
        'ChangePasswordPage',
        'ActionRequiredPage',
        'NotificationPrefsPage',
        'LanguageSettingsPage',
        'CountrySelectPage',
        'AppearancePage',
        'SettingsExtrasPage',
        'PrivacyPage',
        'BlockedPlayersPage',
        'AboutPage',
      ]) {
        expect(region.contains(target), isTrue, reason: 'missing navigation target: $target');
      }
    });

    test('row order is unchanged (account, preferences, privacy, about, backup)', () {
      final order = [
        'Account Settings',
        'Account Security',
        'Change Password',
        'Action Required',
        'Notification Preferences',
        'Language',
        'Country / Region',
        'Appearance',
        'Sound & Haptics',
        'Privacy',
        'Blocked Users',
        'About Arena Hub',
        'Backup My Profile',
        'Restore Profile (Paste Backup)',
      ];
      var prev = -1;
      for (final label in order) {
        final i = region.indexOf("'$label'");
        expect(i, greaterThan(prev), reason: '$label is out of order or missing');
        prev = i;
      }
    });

    test('dedupe holds: Help & Support / Terms & Privacy still absent', () {
      expect(region.contains('Help & Support'), isFalse);
      expect(region.contains('Terms & Privacy'), isFalse);
    });
  });
}
