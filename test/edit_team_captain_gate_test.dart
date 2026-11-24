// EDIT TEAM + TEAM PHOTO BUGS (2026-11-22, user order).
//
// Reported: (1) team name change does not save — "Edit Team"
// does not work; (2) photo change exists on the SQUAD team but
// NOT on the CLAN team.
//
// Root causes found in code (both are captain-gate issues, NOT a
// Squad-vs-Clan code difference — no code anywhere treats clans
// differently; `is_clan` only picks the roster cap and the
// SQUAD/CLAN pill):
//   1. `_isCaptain` is `captain_uid == uid`. Sameer's clan is
//      captained by his OTHER account (roster screenshot: captain
//      "Sameer Zehri", member "sameer" online) while his squad is
//      captained by the logged-in account — so on this login the
//      clan shows no camera icon and a dead disabled EDIT TEAM
//      button, with zero explanation. Fix: the gate is now
//      VISIBLE — a note under the buttons names the captain, and
//      tapping the photo as a member toasts why.
//   2. Even for the captain, `_editTeam`'s bare `.update()` never
//      verified the write: a blocked update returns success with 0
//      rows, and the old code then showed a FALSE "Team update ho
//      gayi!" with a local-only name that reverted on reload. Fix:
//      `.select('id')` + empty check — no write, no toast, no
//      local state change.
//
// Widget tests pump TeamDetailPage with no backend (every SupaDb
// getter swallows errors — same pattern as teams_fixes_test.dart).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _read(String path) => File(path).readAsStringSync();

Map<String, dynamic> _teamRow({bool isClan = false, String captainUid = 'captain-uid'}) => {
      'id': 'team-1',
      'name': isClan ? 'test communiy' : 'Team Ninja',
      'tag': 'TST',
      'game': 'PUBG Mobile',
      'is_clan': isClan,
      'captain_uid': captainUid,
      'captain_name': 'sameer',
      'invite_code': 'F7MYCH',
    };

Future<void> _pumpDetail(WidgetTester tester, {required String uid, required Map<String, dynamic> team}) async {
  await tester.pumpWidget(
    MaterialApp(home: TeamDetailPage(team: team, uid: uid)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('Captain gate — photo + edit work for BOTH types', () {
    testWidgets('clan captain: camera badge + EDIT TEAM opens the dialog',
        (tester) async {
      await _pumpDetail(tester,
          uid: 'captain-uid', team: _teamRow(isClan: true, captainUid: 'captain-uid'));
      // Photo-change affordance: the camera badge on the photo.
      expect(find.byIcon(Icons.camera_alt), findsOneWidget);
      // Edit affordance: EDIT TEAM opens the Edit Team dialog.
      await tester.tap(find.text('EDIT TEAM'));
      await tester.pump();
      expect(find.text('Edit Team'), findsOneWidget);
      expect(find.text('Team name'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('squad captain: same affordances (parity)', (tester) async {
      await _pumpDetail(tester,
          uid: 'captain-uid', team: _teamRow(isClan: false, captainUid: 'captain-uid'));
      expect(find.byIcon(Icons.camera_alt), findsOneWidget);
      await tester.tap(find.text('EDIT TEAM'));
      await tester.pump();
      expect(find.text('Edit Team'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Captain gate — members get an explanation, not silence', () {
    testWidgets('clan member: no camera, captain note names the captain',
        (tester) async {
      await _pumpDetail(tester,
          uid: 'member-uid', team: _teamRow(isClan: true, captainUid: 'captain-uid'));
      expect(find.byIcon(Icons.camera_alt), findsNothing);
      expect(find.text('Sirf captain team edit kar sakta hai — captain: sameer.'),
          findsOneWidget);
      // EDIT TEAM is disabled for a member — tapping opens nothing.
      await tester.tap(find.text('EDIT TEAM'));
      await tester.pump();
      expect(find.text('Edit Team'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('clan member: tapping the photo explains instead of nothing',
        (tester) async {
      await _pumpDetail(tester,
          uid: 'member-uid', team: _teamRow(isClan: true, captainUid: 'captain-uid'));
      await tester.tap(find.byType(TeamPhotoBadge));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Sirf captain team photo badal sakta hai — captain: sameer.'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Edit Team save is verified (source invariant)', () {
    test('_editTeam checks the write landed before claiming success', () {
      final src = _read('lib/screens/pro_features.dart');
      final start = src.indexOf('Future<void> _editTeam()');
      final end = src.indexOf('Future<void> _changeTeamPhoto()', start);
      final edit = src.substring(start, end);
      // The update selects back the written row id…
      expect(edit, contains(".select('id')"));
      // …and an empty result is an honest failure, not a fake
      // success: no local state change, no "update ho gayi" toast.
      expect(edit, contains('updated.isEmpty'));
      expect(edit, contains('Team update nahi ho saki'));
    });
  });
}
