// v2016 FIX 13 (2026-11-22, user order) — 'Members & Chat' opens the
// CHAT DIRECTLY now; the team detail page (edit/history/roster/
// invite) moved inside the chat behind the More menu's
// 'Team settings' option. The navigation was implemented without
// tests; these tests verify it (widget flow + source invariants).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late String proFeatures;

  setUpAll(() {
    proFeatures = _read('lib/screens/pro_features.dart');
  });

  group('v2016 FIX 13 — source invariants', () {
    test("'Members & Chat' pushes TeamChatPage (not the detail page)", () {
      final start = proFeatures.indexOf("label: 'Members & Chat'");
      expect(start, isNot(-1));
      final button = proFeatures.substring(start, start + 400);
      expect(button, contains('TeamChatPage(team: t, uid: widget.uid'));
      expect(button, isNot(contains('TeamDetailPage')));
    });

    test('TeamDetailPage is only pushed from the chat (_openMembers)', () {
      // Constructor + the single push inside _openMembers: no other
      // entry point opens the detail page directly any more.
      expect('TeamDetailPage('.allMatches(proFeatures).length, 2);
      final openStart = proFeatures.indexOf('void _openMembers()');
      expect(openStart, isNot(-1));
      final open = proFeatures.substring(openStart, openStart + 300);
      expect(open, contains('TeamDetailPage(team: widget.team'));
    });

    test("chat More menu (team mode) has 'Team settings'", () {
      expect(proFeatures,
          contains("ArenaChatMenuItem('team', 'Team settings')"));
      // Selecting it opens the detail page via _openMembers.
      final sel = proFeatures.indexOf("} else if (v == 'team') {");
      expect(sel, isNot(-1));
      expect(
          proFeatures.substring(sel, sel + 120), contains('_openMembers();'));
    });
  });

  group('v2016 FIX 13 — widget tests', () {
    setUp(() {
      SupaDb.testFixtures = {
        'teams': [
          {
            'id': 'team-1',
            'name': 'Falcons',
            'tag': 'FLC',
            'game': 'PUBG Mobile',
            'is_clan': false,
            'captain_uid': 'test-uid',
            'captain_name': 'Tester',
            'invite_code': 'ABC123'
          },
        ],
        'team_members': [
          {
            'team_id': 'team-1',
            'firebase_uid': 'test-uid',
            'user_name': 'Tester',
            'role': 'captain'
          },
        ],
        'team_invitations': [],
        'profiles': [
          {
            'firebase_uid': 'test-uid',
            'display_name': 'Tester',
            'username': 'tester'
          },
        ],
        'chat_messages': [],
      };
    });
    tearDown(() {
      SupaDb.testFixtures = null;
    });

    Future<void> openChat(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
          home: TeamsPage(uid: 'test-uid', embedded: true)));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('Members & Chat'), findsOneWidget);
      await tester.tap(find.text('Members & Chat'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets(
        "'Members & Chat' opens the chat directly, not the detail page",
        (tester) async {
      await openChat(tester);
      expect(find.byType(TeamChatPage), findsOneWidget);
      expect(find.byType(TeamDetailPage), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets("'Team settings' in the chat menu opens the detail page",
        (tester) async {
      await openChat(tester);
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Team settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(TeamDetailPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
