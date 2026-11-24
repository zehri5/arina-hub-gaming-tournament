// Phase 2 redesign, GROUP S12 — Edit Profile (CreateProfilePage in
// lib/screens/pro_features.dart, guide §6 Screen 12).
//
// Pins the REDESIGN (styling only — no logic/flow change):
//  * all 7 fields preserved (Display Name, Username, In-game Name,
//    Game UID, Country/Region, Favorite Game, Bio)
//  * every text field is the shared ArenaTextField component, using
//    the contract tokens (kField fill, kBorder border, kGold focus
//    border, kError error border, kRadiusInput radius)
//  * dropdowns share the text fields' rendered height and metrics
//  * avatar + CHANGE PHOTO stay center-aligned
//  * username availability indicator: kGold spinner while checking,
//    kGreen Available, kError Taken (Taken is pinned by a source
//    check — it needs a live server row, unreachable in tests)
//  * SAVE CHANGES (ArenaPrimaryButton) + CANCEL (ArenaSecondaryButton)
//    behaviour unchanged: validation toasts, busy/disabled, pop
//  * keyboard + long-bio scrolling: no overflow, SAVE reachable
//  * no hardcoded old colours / banned golds in the S12 region
//
// Pumps the REAL page at 360x800 with a fixture profile via the
// SupaDb.testFixtures seam (same pattern as
// test/edit_profile_photo_test.dart). No pumpAndSettle anywhere —
// ArenaEmberDots repeats forever.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/cached_image.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';

const _uid = 's12-test-uid';

Map<String, dynamic> _profileRow({
  String displayName = 'Admin',
  String username = 'admin',
  String ign = 'AdminIGN',
  String gameUid = '5123456789',
  String country = 'Pakistan',
  String game = 'PUBG Mobile',
  String bio = 'I am the developer',
}) =>
    {
      'firebase_uid': _uid,
      'display_name': displayName,
      'username': username,
      'photo_url': '',
      'country': country,
      'favorite_game': game,
      'bio': bio,
      'game_uid': gameUid,
      'in_game_name': ign,
    };

/// Pumps the REAL CreateProfilePage at 360x800 with a fixture
/// profile. Bounded pumps only (EmberDots animates forever).
Future<void> _pumpPage(WidgetTester tester, {Map<String, dynamic>? profile}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  SupaDb.testFixtures = {
    'profiles': [profile ?? _profileRow()],
  };
  addTearDown(() => SupaDb.testFixtures = null);
  await tester.pumpWidget(
    const MaterialApp(home: CreateProfilePage(uid: _uid)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

/// Host page so CANCEL has somewhere to pop back to.
class _HostPage extends StatelessWidget {
  const _HostPage();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateProfilePage(uid: _uid))),
          child: const Text('OPEN EDIT'),
        ),
      ),
    );
  }
}

Future<void> _pumpHostThenOpen(WidgetTester tester) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  SupaDb.testFixtures = {
    'profiles': [_profileRow()],
  };
  addTearDown(() => SupaDb.testFixtures = null);
  await tester.pumpWidget(const MaterialApp(home: _HostPage()));
  await tester.tap(find.text('OPEN EDIT'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

/// Collects framework errors (overflow, etc.) instead of failing
/// the test at once, so the test can assert there were NONE.
/// Returns the list AND a restore callback: the caller MUST call
/// [restore] BEFORE its final expects — the framework asserts if a
/// test still has FlutterError.onError overridden when an expect
/// throws (binding.dart _pendingExceptionDetails assert). The
/// tearDown restore is only a backstop.
({List<FlutterErrorDetails> errors, void Function() restore}) _captureErrors() {
  final errors = <FlutterErrorDetails>[];
  final old = FlutterError.onError;
  FlutterError.onError = errors.add;
  addTearDown(() => FlutterError.onError = old);
  return (errors: errors, restore: () => FlutterError.onError = old);
}

/// The TextField whose controller currently holds [text].
Finder _fieldWithText(String text) => find.byWidgetPredicate(
      (w) => w is TextField && w.controller?.text == text,
    );

/// The dropdown's own Container (kField fill), found by walking up
/// from the DropdownButton.
Finder _dropdownBox(int index) => find.ancestor(
      of: find.byType(DropdownButton<String>).at(index),
      matching: find.byWidgetPredicate((w) =>
          w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).color == kField),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('S12 tokens (contract stub values)', () {
    test('gold / error / warning / soft tokens are the guide values', () {
      themeLightNotifier.value = false;
      addTearDown(() => themeLightNotifier.value = false);
      expect(kGold, const Color(0xFFFDC903));
      expect(kGoldSoft, const Color(0xFFFFE16A));
      expect(kWarning, const Color(0xFFF4A62A));
      expect(kError, const Color(0xFFF04452));
      expect(kSurfaceElevated, const Color(0xFF202331));
      expect(kTextMuted, const Color(0xFF737789));
      expect(kGoldGradient.colors, [kGoldSoft, const Color(0xFFFDC903)]);
      expect(kCardSurfaceGradient.colors, [const Color(0xFF202331), const Color(0xFF12141C)]);
      expect(kBackgroundGradient.colors, [const Color(0xFF10121A), const Color(0xFF08090D)]);
    });

    test('spacing / radii / text-style tokens', () {
      expect(kSpace4, 4);
      expect(kSpace8, 8);
      expect(kSpace12, 12);
      expect(kSpace16, 16);
      expect(kSpace20, 20);
      expect(kSpace24, 24);
      expect(kSpace32, 32);
      expect(kRadiusChip, 12);
      expect(kRadiusInput, 14);
      expect(kRadiusCard, 18);
      expect(kRadiusHero, 22);
      expect(kStyleTitle.fontSize, 22);
      expect(kStyleTitle.fontWeight, FontWeight.bold);
      expect(kStyleSection.fontSize, 18);
      expect(kStyleCardTitle.fontSize, 17);
      expect(kStyleCardTitle.fontWeight, FontWeight.w600);
      expect(kStyleBody.fontSize, 15);
      expect(kStyleMeta.fontSize, 13);
      expect(kStyleLabel.fontSize, 12);
      expect(kStyleLabel.fontWeight, FontWeight.w500);
      expect(kStyleLabel.color, kTextMuted);
    });
  });

  group('S12 fields preserved + shared input component', () {
    testWidgets('all 7 field labels present, values prefilled from the profile', (tester) async {
      await _pumpPage(tester);
      for (final label in ['DISPLAY NAME', 'USERNAME', 'IN-GAME NAME', 'GAME UID', 'COUNTRY/REGION', 'FAVORITE GAME', 'BIO']) {
        expect(find.text(label), findsOneWidget, reason: 'missing field label $label');
      }
      expect(find.byType(ArenaTextField), findsNWidgets(5));
      expect(find.byType(DropdownButton<String>), findsNWidgets(2));
      expect(_fieldWithText('Admin'), findsOneWidget);
      expect(_fieldWithText('admin'), findsOneWidget);
      expect(_fieldWithText('AdminIGN'), findsOneWidget);
      expect(_fieldWithText('5123456789'), findsOneWidget);
      expect(_fieldWithText('I am the developer'), findsOneWidget);
      expect(find.text('Pakistan'), findsOneWidget);
      expect(find.text('PUBG Mobile'), findsOneWidget);
    });

    testWidgets('text fields use the token input style (fill, borders, radius)', (tester) async {
      await _pumpPage(tester);
      final field = tester.widget<TextField>(find.byType(TextField).first);
      final decoration = field.decoration!;
      expect(decoration.filled, isTrue);
      expect(decoration.fillColor, kField);
      final enabled = decoration.enabledBorder as OutlineInputBorder;
      expect(enabled.borderRadius, BorderRadius.circular(kRadiusInput));
      expect(enabled.borderSide.color, kBorder);
      final focused = decoration.focusedBorder as OutlineInputBorder;
      expect(focused.borderRadius, BorderRadius.circular(kRadiusInput));
      expect(focused.borderSide.color, kGold);
      expect(focused.borderSide.width, 1.5);
      final error = decoration.errorBorder as OutlineInputBorder;
      expect(error.borderSide.color, kError);
      expect(field.style?.fontSize, 15);
      expect(field.style?.color, kText);
    });

    testWidgets('field labels use the label token', (tester) async {
      await _pumpPage(tester);
      final label = tester.widget<Text>(find.text('DISPLAY NAME'));
      expect(label.style?.color, kTextMuted);
      expect(label.style?.fontSize, 12);
      expect(label.style?.fontWeight, FontWeight.w500);
      expect(label.style?.letterSpacing, 0.5);
    });

    testWidgets('dropdowns use the token input style (fill, border, radius, elevated menu)', (tester) async {
      await _pumpPage(tester);
      final box = tester.widget<Container>(_dropdownBox(0));
      final decoration = box.decoration as BoxDecoration;
      expect(decoration.color, kField);
      expect(decoration.borderRadius, BorderRadius.circular(kRadiusInput));
      expect((decoration.border as Border).top.color, kBorder);
      final dropdown = tester.widget<DropdownButton<String>>(find.byType(DropdownButton<String>).first);
      expect(dropdown.dropdownColor, kSurfaceElevated);
      expect(dropdown.style?.color, kText);
      expect(dropdown.style?.fontSize, 15);
    });

    testWidgets('dropdown selection still works (behaviour unchanged)', (tester) async {
      await _pumpPage(tester);
      await tester.ensureVisible(find.byType(DropdownButton<String>).first);
      await tester.pump();
      await tester.tap(find.byType(DropdownButton<String>).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('India'));
      await tester.pump();
      // The menu closes with a ~200 ms reverse transition — pump
      // past it so the menu route is fully gone before asserting;
      // otherwise the menu item and the button both show 'India'.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.descendant(of: find.byType(DropdownButton<String>).first, matching: find.text('India')), findsOneWidget);
      expect(find.text('India'), findsOneWidget);
      expect(find.text('Pakistan'), findsNothing);
    });
  });

  group('S12 consistent heights', () {
    testWidgets('single-line text fields and dropdowns render at the same height', (tester) async {
      final cap = _captureErrors();
      await _pumpPage(tester);
      final nameH = tester.getSize(find.byType(TextField).first).height;
      final usernameH = tester.getSize(_fieldWithText('admin')).height;
      final ignH = tester.getSize(_fieldWithText('AdminIGN')).height;
      final uidH = tester.getSize(_fieldWithText('5123456789')).height;
      final countryH = tester.getSize(_dropdownBox(0)).height;
      final gameH = tester.getSize(_dropdownBox(1)).height;
      cap.restore();
      for (final h in [usernameH, ignH, uidH, countryH, gameH]) {
        expect((h - nameH).abs(), lessThanOrEqualTo(2),
            reason: 'field/dropdown heights differ: name=$nameH username=$usernameH ign=$ignH uid=$uidH country=$countryH game=$gameH');
      }
      expect(cap.errors, isEmpty, reason: cap.errors.map((e) => e.exceptionAsString()).join('\n'));
    });
  });

  group('S12 avatar + change-photo centred', () {
    testWidgets('avatar and CHANGE PHOTO are centred on the 360 px screen', (tester) async {
      await _pumpPage(tester);
      expect(tester.getCenter(find.byType(ArenaCachedAvatar)).dx, closeTo(180, 1));
      final changePhoto = tester.widget<Text>(find.text('CHANGE PHOTO'));
      expect(changePhoto.style?.color, kGold);
      expect(tester.getCenter(find.text('CHANGE PHOTO')).dx, closeTo(180, 1));
    });
  });

  group('S12 username availability indicator', () {
    testWidgets('checking state shows a gold spinner', (tester) async {
      await _pumpPage(tester);
      await tester.enterText(_fieldWithText('admin'), 'brandnewname');
      await tester.pump();
      final spinner = tester.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator));
      expect(spinner.color, kGold);
    });

    testWidgets('available state is readable in the success-green token', (tester) async {
      await _pumpPage(tester);
      await tester.enterText(_fieldWithText('admin'), 'brandnewname');
      await tester.pump();
      // Debounce (500 ms) fires; the live lookup cannot reach the
      // server in tests, so the service reports available.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Available'), findsOneWidget);
      final label = tester.widget<Text>(find.text('Available'));
      expect(label.style?.color, kGreen);
      final icon = tester.widget<Icon>(find.byIcon(Icons.check));
      expect(icon.color, kGreen);
    });

    test('taken state uses the error token (source pin — needs a live row)', () {
      final src = File('lib/screens/pro_features.dart').readAsStringSync();
      final start = src.indexOf('class CreateProfilePage');
      final end = src.indexOf('/// ---------------- REMAINING-ITEMS', start);
      final region = src.substring(start, end);
      final takenAt = region.indexOf("case 'taken':");
      expect(takenAt, greaterThanOrEqualTo(0), reason: 'taken branch missing');
      final takenBlock = region.substring(takenAt, region.indexOf('default:', takenAt));
      expect(takenBlock.contains('kError'), isTrue, reason: 'taken indicator must use kError');
      expect(takenBlock.contains('redAccent'), isFalse);
      expect(takenBlock.contains('Colors.red'), isFalse);
    });
  });

  group('S12 save / cancel behaviour unchanged', () {
    testWidgets('SAVE CHANGES is the shared primary button; CANCEL the shared secondary', (tester) async {
      await _pumpPage(tester);
      expect(find.byType(ArenaPrimaryButton), findsOneWidget);
      expect(find.byType(ArenaSecondaryButton), findsOneWidget);
      final saveLabel = tester.widget<Text>(find.text('SAVE CHANGES'));
      expect(saveLabel.style?.color, const Color(0xFF0A0A0F));
      expect(saveLabel.style?.fontWeight, FontWeight.w900);
      expect(saveLabel.style?.fontSize, 16);
      final cancelLabel = tester.widget<Text>(find.text('CANCEL'));
      expect(cancelLabel.style?.color, kText);
    });

    testWidgets('empty display name still blocks save with the same toast', (tester) async {
      // NOTE: an empty display name cannot be reached via fixtures —
      // normProfile falls back to 'User' for an empty display_name —
      // so clear the field after pumping instead.
      await _pumpPage(tester);
      expect(find.text('EDIT PROFILE'), findsOneWidget);
      await tester.enterText(_fieldWithText('Admin'), '');
      await tester.pump();
      await tester.ensureVisible(find.text('SAVE CHANGES'));
      await tester.pump();
      await tester.tap(find.text('SAVE CHANGES'));
      await tester.pump();
      expect(find.text('Name zaroori hai.'), findsOneWidget);
    });

    testWidgets('non-numeric Game UID still blocks save with the same toast', (tester) async {
      await _pumpPage(tester);
      await tester.enterText(_fieldWithText('5123456789'), 'abc');
      await tester.pump();
      await tester.ensureVisible(find.text('SAVE CHANGES'));
      await tester.pump();
      await tester.tap(find.text('SAVE CHANGES'));
      await tester.pump();
      expect(find.text('Game UID sirf number hoti hai (5-20 digits) — dobara check karke likhein.'), findsOneWidget);
    });

    testWidgets('CANCEL still pops back to the previous screen', (tester) async {
      await _pumpHostThenOpen(tester);
      expect(find.text('EDIT PROFILE'), findsOneWidget);
      await tester.ensureVisible(find.text('CANCEL'));
      await tester.pump();
      await tester.tap(find.text('CANCEL'));
      await tester.pump();
      // The pop transition runs ~300 ms — pump past it so the
      // pushed route is fully gone before asserting.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.text('OPEN EDIT'), findsOneWidget);
      expect(find.text('EDIT PROFILE'), findsNothing);
    });
  });

  group('S12 keyboard + long bio scrolling', () {
    testWidgets('long bio text + open keyboard: no overflow, SAVE stays reachable', (tester) async {
      // No _captureErrors() here: overriding FlutterError.onError
      // in this test trips the framework's _pendingExceptionDetails
      // assert (an async error surfaces while the override is
      // installed) and stalls the runner for 10 min. The framework
      // fails the test on ANY FlutterError by default, so "no
      // overflow" is already pinned without a collector.
      await _pumpPage(tester);
      final longBio = List.filled(60, 'Bio line. ').join();
      await tester.ensureVisible(_fieldWithText('I am the developer'));
      await tester.pump();
      await tester.enterText(_fieldWithText('I am the developer'), longBio);
      await tester.pump();
      // Simulate the open keyboard: 300 px of bottom inset.
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      // scrollUntilVisible defaults to find.byType(Scrollable) for
      // the scrollable — but this page has MANY Scrollables (the
      // page view + every TextField's internal one), so the default
      // throws "Too many elements". Pin the page's Scrollable: the
      // one Scrollable ancestor of the SAVE button.
      await tester.scrollUntilVisible(
        find.text('SAVE CHANGES'),
        200,
        scrollable: find.ancestor(
          of: find.text('SAVE CHANGES'),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pump();
      final saveRect = tester.getRect(find.text('SAVE CHANGES'));
      expect(saveRect.top, lessThan(800));
    });
  });

  group('S12 no hardcoded old colours / banned golds', () {
    test('Edit Profile region uses tokens, not hardcoded colours', () {
      final src = File('lib/screens/pro_features.dart').readAsStringSync();
      final start = src.indexOf('class CreateProfilePage');
      final end = src.indexOf('/// ---------------- REMAINING-ITEMS', start);
      final region = src.substring(start, end);
      expect(region.contains('Colors.green'), isFalse);
      expect(region.contains('redAccent'), isFalse);
      expect(region.contains('Color(0xFFFDC903)'), isFalse, reason: 'use kGold, not a hardcoded gold');
      // (Banned-shade negative checks removed: no banned-gold value
      // is written in this file — the merge-time gold grep guards it.)
      expect(region.contains('ArenaTextField'), isTrue);
      expect(region.contains('ArenaPrimaryButton'), isTrue);
      expect(region.contains('ArenaSecondaryButton'), isTrue);
      expect(region.contains('kSurfaceElevated'), isTrue);
      expect(region.contains('kRadiusInput'), isTrue);
      expect(region.contains('kStyleLabel'), isTrue);
      expect(region.contains('kTextMuted'), isTrue);
    });

    test('contract files define the gold token', () {
      // Positive check only (no banned-gold value is written in
      // this file): the contract files must define kGold as FDC903.
      final theme = File('lib/theme.dart').readAsStringSync();
      expect(theme.contains('0xFFFDC903'), isTrue);
      final ui = File('lib/widgets/arena_ui.dart').readAsStringSync();
      expect(ui.contains('kGold'), isTrue);
    });
  });
}
