// v2015 (2026-11-22) — Join dialog compact + Community sticky header
// + perspective read case-insensitive (save-bug follow-up).
//
// Bug 2: the "Join by invite code" AlertDialog filled the whole
// screen — ArenaFormField's Column was mainAxisSize.max, and a max
// Column inside a dialog's content expands the dialog to full
// height (field at top, actions pinned at the bottom, a huge empty
// gap between). The field is min-sized now; the dialog is compact.
// Bug 3: scrolling the Community teams list scrolled the Create /
// Join / Browse controls away with it. The controls are pinned in
// a fixed header now; only the team/clan cards scroll.
// Bug 1 (no code change): the tournament form's perspective READ
// was already case-insensitive (it lowercases before comparing),
// and Perspective.fromString normalises too — a stored 'FPP' reads
// as fpp. These tests pin that so nobody "fixes" the read by
// breaking it. (The save itself is fixed backend-side: the CHECK
// must allow lowercase 'tpp'/'fpp'.)
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/platform/core/tournament_enums.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('Bug 2 — Join by Code dialog is compact', () {
    testWidgets('AlertDialog with field() content stays compact',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final codeCtrl = TextEditingController();
      addTearDown(codeCtrl.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: kBg),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showDialog<String>(
                  context: context,
                  builder: (context) => AlertDialog(
                    backgroundColor: kCard,
                    title: const Text('Join by invite code'),
                    content: field(controller: codeCtrl, label: 'Invite code'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(context, codeCtrl.text.trim()),
                          child: const Text('Join')),
                    ],
                  ),
                ),
                child: const Text('Open dialog'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Open dialog'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Join by invite code'), findsOneWidget);
      expect(find.text('Invite code'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Join'), findsOneWidget);
      // Compact: title + one field + actions ≈ 250dp on a 360x800
      // phone. The old max-sized field pushed the actions to the
      // bottom of the screen (~700dp span, a huge empty gap).
      // (Measure the visible span, not the AlertDialog render box —
      // the dialog route's root padding fills the screen.)
      final span = tester.getBottomLeft(find.text('Join')).dy -
          tester.getTopLeft(find.text('Join by invite code')).dy;
      expect(span, lessThan(400));
      final fieldToActions = tester.getTopLeft(find.text('Join')).dy -
          tester.getBottomLeft(find.byType(TextField)).dy;
      expect(fieldToActions, lessThan(100));
      expect(tester.takeException(), isNull);
    });

    test('ArenaFormField sizes to its content (source pin)', () {
      final src = _read('lib/components/arena_components.dart');
      final start = src.indexOf('class ArenaFormField');
      expect(start, isNot(-1));
      final end = src.indexOf('class EmptyState', start);
      final fieldSrc = src.substring(start, end == -1 ? src.length : end);
      expect(fieldSrc, contains('mainAxisSize: MainAxisSize.min'));
    });
  });

  group('Bug 3 — Community header stays pinned while the list scrolls', () {
    List<Map<String, dynamic>> teams(int n) => List.generate(n, (i) => {
          'id': 'team-$i',
          'name': 'Falcons $i',
          'tag': 'FL$i',
          'game': 'PUBG Mobile',
          'is_clan': i.isOdd,
          'captain_uid': 'test-uid',
          'captain_name': 'Tester',
          'invite_code': 'CODE$i',
        });

    List<Map<String, dynamic>> members(int n) => List.generate(n, (i) => {
          'team_id': 'team-$i',
          'firebase_uid': 'test-uid',
          'user_name': 'Tester',
          'role': 'captain',
        });

    setUp(() {
      SupaDb.testFixtures = {
        'teams': teams(8),
        'team_members': members(8),
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

    testWidgets('controls do not move when the cards list scrolls',
        (tester) async {
      // Default 800x600 viewport: the team cards' action row
      // (Members & Chat + Clan War) overflows at 360px in the test
      // font — a test-only artifact (it fits on the real phone);
      // 8 cards still scroll plenty within 600px of height.
      await tester.pumpWidget(
          MaterialApp(home: TeamsPage(uid: 'test-uid', embedded: true)));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      // FIX 12 G11: the pinned header is the three-button top row
      // + Join by Code now (the old two-pill toggle and "Create
      // Clan" button are gone).
      expect(find.text('Squad'), findsOneWidget);
      expect(find.text('Join by Code'), findsOneWidget);
      expect(find.text('Falcons 0'), findsOneWidget);

      final toggleBefore = tester.getTopLeft(find.text('Squad')).dy;
      final createBefore = tester.getTopLeft(find.text('Join by Code')).dy;
      final cardBefore = tester.getTopLeft(find.text('Falcons 0')).dy;

      // Scroll the cards list a long way down.
      await tester.drag(
          find.byType(ListView).first, const Offset(0, -600));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The pinned controls have not moved at all.
      expect(tester.getTopLeft(find.text('Squad')).dy, toggleBefore);
      expect(tester.getTopLeft(find.text('Join by Code')).dy, createBefore);
      // ...while the cards did scroll (first card moved up).
      final cardAfterFinder = find.text('Falcons 0');
      if (cardAfterFinder.evaluate().isNotEmpty) {
        expect(tester.getTopLeft(cardAfterFinder).dy, lessThan(cardBefore));
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('Bug 1 — perspective read is case-insensitive (pinned)', () {
    test("Perspective.fromString reads stored 'TPP'/'FPP'", () {
      expect(Perspective.fromString('TPP'), Perspective.tpp);
      expect(Perspective.fromString('FPP'), Perspective.fpp);
      expect(Perspective.fromString('tpp'), Perspective.tpp);
      expect(Perspective.fromString('fpp'), Perspective.fpp);
      expect(Perspective.fromString(null), Perspective.tpp);
      expect(Perspective.fromString(''), Perspective.tpp);
    });

    // FIX 32 (2026-11-24): the admin edit form is gone with the
    // panel — its perspective-lowercasing pin went with it. The
    // user-side builder uses typed enums (Perspective.label), so
    // no case-folding pin is needed there.
  });
}
