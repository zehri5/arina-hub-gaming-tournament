// MY TEAM — TOURNAMENT CHAT REMOVAL (2026-11-22 user order) —
// source-invariant regression tests. No network, no Supabase init,
// no Firebase init: they read the R-copy sources and assert the
// shapes the user ordered. If any of these fail, the removed
// section has come back — do NOT ship.
//
// Covered:
//   1. No "TOURNAMENT CHAT" heading + per-tournament chat buttons
//      on My Team (TeamDetailPage).
//   2. The dead tournaments fetch/field went with the section.
//   3. "Open Team Chat" (the kept chat entry) is still there, as
//      are the Invite Code card and the ROSTER.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  late String pro;

  setUpAll(() {
    pro = _read('lib/screens/pro_features.dart');
  });

  String teamDetailPage() {
    final start = pro.indexOf('class _TeamDetailPageState');
    expect(start, isNot(-1), reason: 'missing _TeamDetailPageState');
    final end = pro.indexOf('class TeamHistoryPage', start);
    expect(end, isNot(-1), reason: 'missing TeamHistoryPage end marker');
    return pro.substring(start, end);
  }

  // Code only: full-line // comments are stripped because the
  // removal notes mention the section by name — the assertions
  // must check code, not prose.
  String teamDetailPageCode() {
    return teamDetailPage()
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
  }

  group('My Team — TOURNAMENT CHAT removed (2026-11-22)', () {
    test('no TOURNAMENT CHAT heading or per-tournament buttons', () {
      final page = teamDetailPageCode();
      expect(page, isNot(contains("'TOURNAMENT CHAT'")));
      expect(page, isNot(contains('TOURNAMENT CHAT')));
      expect(page, isNot(contains("} CHAT'")));
    });

    test('dead tournaments fetch + field are gone', () {
      final page = teamDetailPageCode();
      expect(page,
          isNot(contains('List<Map<String, dynamic>> _tournaments')));
      expect(page, isNot(contains('_tournaments.isNotEmpty')));
      expect(page, isNot(contains("from('tournament_registrations')")));
    });

    test('Open Team Chat + Invite Code + ROSTER still there', () {
      final page = teamDetailPage();
      expect(page, contains("label: 'Open Team Chat'"));
      expect(page, contains("'INVITE CODE'"));
      expect(page, contains('rosterHeaderLabel('));
    });
  });
}
