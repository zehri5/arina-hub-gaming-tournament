// FIX 12 GROUP G5 (user order 2026-11-23 01:09) — CLAN REMOVED.
//
// The clan type is completely gone from UI and logic: no CLAN
// pill/label anywhere, no is_clan distinction — every teams-table
// row is just a TEAM. The app IGNORES is_clan: no subscript read,
// no branch, no flag parameter. Server untouched (no migration,
// no data deleted).
//
// KEPT on purpose (pinned here so a future sweep does not nuke them):
//   * 'Clan War' — a named tournament feature, not the clan type
//     distinction (team-card button + CreateTournamentPage toggle).
//   * The create form's is_clan writes — group G13 MERGED 2026-11-23:
//     the _createTeam dialog (with its 'is_clan': true x2) is
//     DELETED; the unified CreateCommunityPage + createSquad write
//     NO is_clan at all. The dialog's Team-wording pins moved to
//     the unified form (see the 'unified create form' test below).
//   * ensureTeamForJoin's constant 'is_clan': false write
//     (supabase_db.dart) — a server-column write, not a branch.
//   * Tournament Solo/Duo/Squad formats — they describe tournament
//     formats, not team types.
//   * The community-chat sender pill stays 'TEAM N'.
//   * Voice-room ids stay squad_<teamId> (existing rooms keep working).
//
// Source-invariant tests read the sources (no backend); widget
// tests pump TeamsPage with SupaDb.testFixtures.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/services/squad.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _read(String path) => File(path).readAsStringSync();

// Full-line // comments are stripped: the FIX 12 G5 removal notes
// mention Clan by name, so the assertions must check code, not prose.
String _code(String src) =>
    src.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

String _region(String src, String from, String to) {
  final start = src.indexOf(from);
  final end = src.indexOf(to, start);
  return src.substring(start, end);
}

// Every lib file that ever mentioned the clan type (code + prose).
const _clanFiles = [
  'lib/screens/pro_features.dart',
  'lib/screens/communities_screens.dart',
  'lib/screens/community_screens.dart',
  'lib/screens/room_screen.dart',
  'lib/screens/home_screens.dart',
  'lib/screens/more_screens.dart',
  'lib/components/arena_components.dart',
  'lib/community_service.dart',
  'lib/services/squad.dart',
  'lib/services/supabase_db.dart',
  'lib/main.dart',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late String proFeatures;
  late String communityScreens;
  late String squadService;

  setUpAll(() {
    proFeatures = _read('lib/screens/pro_features.dart');
    communityScreens = _read('lib/screens/communities_screens.dart');
    squadService = _read('lib/services/squad.dart');
  });

  group('G5 — no CLAN text in team/community screens (source)', () {
    test('no CLAN string in code anywhere in lib (except Clan War)', () {
      for (final path in _clanFiles) {
        final code = _code(_read(path));
        // 'Clan War' is mixed case and kept; uppercase CLAN must be gone.
        expect(code, isNot(contains('CLAN')), reason: path);
      }
    });

    test('no CLAN pill in the team list card or the detail header', () {
      final teamsPage = _code(_region(
          proFeatures, 'class _TeamsPageState', 'class TeamDetailPage'));
      final detailPage = _code(_region(proFeatures, 'class TeamDetailPage',
          'class TeamHistoryPage'));
      expect(teamsPage, isNot(contains("Text('CLAN'")));
      expect(detailPage, isNot(contains("Text('CLAN'")));
      expect(teamsPage, isNot(contains("'CLAN'")));
      expect(detailPage, isNot(contains("'CLAN'")));
    });

    test('three-button top row — no Clan label (G11 supersedes toggle)', () {
      final teamsPage = _region(
          proFeatures, 'class _TeamsPageState', 'class TeamDetailPage');
      // Merge lane (G11): the two-pill toggle is gone — the top row is
      // [Community] [Squad] [Create] from named constants. The intent
      // is unchanged: no Clan label anywhere on the row.
      expect(teamsPage, contains('label: kCommunityTabLabel'));
      expect(teamsPage, contains('label: kSquadTabLabel'));
      expect(teamsPage, contains('label: kCreateTabLabel'));
      expect(teamsPage, isNot(contains("_toggleBtn(label: 'Clan'")));
    });

    test('Create lives in the top row; Pro Hub tile is Teams', () {
      final teamsPage = _region(
          proFeatures, 'class _TeamsPageState', 'class TeamDetailPage');
      // Merge lane (G11): no separate Create Team button — the top
      // row's Create dispatches through the single _openCreate site.
      expect(teamsPage, contains('onTap: _openCreate'));
      expect(teamsPage, isNot(contains("goldButton(label: 'Create Team'")));
      expect(teamsPage, isNot(contains("goldButton(label: 'Create Clan'")));
      expect(proFeatures, contains("'label': 'Teams'"));
      expect(proFeatures, isNot(contains('Teams & Clans')));
    });

    test('empty state is team language, not clan language', () {
      final teamsPage = _region(
          proFeatures, 'class _TeamsPageState', 'class TeamDetailPage');
      expect(teamsPage, contains("title: 'No team yet'"));
      expect(teamsPage,
          contains('Aap kisi team me nahi hain. Team banayen ya invite code se join karen.'));
      expect(teamsPage, isNot(contains("'No clan yet'")));
      expect(teamsPage, isNot(contains('kisi clan me nahi hain')));
    });

    test('unified create form says Squad/Team, not Clan (G13 supersedes the dialog pins)', () {
      // FIX 12 G13 (merged): the _createTeam dialog is DELETED —
      // its Team-wording pins move to the unified form + the
      // Squad path, which must say Squad/Team, never Clan.
      final form = _code(_region(
          _read('lib/screens/communities_screens.dart'),
          'class _CreateCommunityPageState',
          'class _CreateTypeBox'));
      final squad = _code(_region(
          _read('lib/community_service.dart'),
          'static Future<Map<String, dynamic>> createSquad({',
          'static Future<Map<String, dynamic>> deleteCommunity({'));
      expect(form, contains("label: 'Squad'"));
      expect(squad, contains("'Squad ka naam likhen.'"));
      for (final region in [form, squad]) {
        expect(region, isNot(contains('Clan')));
        expect(region, isNot(contains("Text('Create Clan'")));
        expect(region, isNot(contains("'Clan name'")));
      }
    });
  });

  group('G5 — no is_clan branching in UI/logic (source)', () {
    test('no is_clan subscript read anywhere in lib code', () {
      for (final path in _clanFiles) {
        final code = _code(_read(path));
        expect(code, isNot(contains("['is_clan']")), reason: path);
        expect(code, isNot(contains('isClan')), reason: path);
      }
    });

    test('the only is_clan occurrences in code are constant writes', () {
      // FIX 12 G13 (merged): the create form's 'is_clan': true x2
      // are GONE with the deleted _createTeam dialog — the Squad
      // path (createSquad) writes NO is_clan at all.
      // ensureTeamForJoin: 'is_clan': false x1. Nothing else.
      var writes = 0;
      for (final path in _clanFiles) {
        final code = _code(_read(path));
        writes += "'is_clan':".allMatches(code).length;
        // Every is_clan mention in code must be one of those writes.
        final mentions = 'is_clan'.allMatches(code).length;
        expect(mentions, "'is_clan':".allMatches(code).length,
            reason: '$path has a non-write is_clan mention');
      }
      expect(writes, 1);
    });

    test('voice panel reads no is_clan flag', () {
      final panel = _region(proFeatures, 'Widget _buildVoicePanel() {',
          'void _onLockedVoiceTap()');
      expect(panel, contains('micCount: teamMicCount(),'));
      expect(panel, isNot(contains('is_clan')));
      expect(panel, isNot(contains('isClan')));
    });

    test('teamMicCount returns 6 and takes no flag', () {
      expect(teamMicCount(), 6);
      expect(squadService, contains('int teamMicCount() => 6;'));
      expect(squadService, isNot(contains('teamMicCount(bool')));
    });

    test('teamRosterSize ignores is_clan', () {
      expect(teamRosterSize({'is_clan': true}), isNull);
      expect(teamRosterSize({'is_clan': false}), isNull);
      expect(teamRosterSize({'max_members': 6, 'is_clan': true}), 6);
      expect(teamRosterSize({'max_members': 6, 'is_clan': false}), 6);
      expect(teamRosterSize({'max_members': 4, 'is_clan': true}), 4);
    });
  });

  group('G5 — kept on purpose (must NOT be removed)', () {
    test('Clan War feature button + tournament toggle stay', () {
      final teamsPage = _region(
          proFeatures, 'class _TeamsPageState', 'class TeamDetailPage');
      expect(teamsPage, contains("label: 'Clan War'"));
      expect(proFeatures, contains("title: Text('Clan War tournament'"));
      expect(proFeatures, contains('clanWarTeam'));
    });

    test('sender pill stays TEAM N', () {
      final code = _code(communityScreens);
      expect(code, contains("'TEAM \${_teamOf[senderUid]}'"));
    });

    test('tournament Solo/Duo/Squad formats untouched', () {
      expect(proFeatures, contains("for (final m in ['Solo', 'Duo', 'Squad'])"));
    });

    test('voice-room ids unchanged (existing rooms keep working)', () {
      expect(squadService,
          contains("String squadRoomId(String squadId) => 'squad_\$squadId';"));
    });
  });

  group('G5 — TeamsPage widget (no CLAN on screen)', () {
    setUp(() {
      SupaDb.testFixtures = {
        'teams': [
          {
            'id': 'team-1',
            'name': 'Falcons',
            'tag': 'FLC',
            'game': 'PUBG Mobile',
            // Old clan row: renders as a plain team now.
            'is_clan': true,
            'captain_uid': 'test-uid',
            'captain_name': 'Tester',
            'invite_code': 'ABC123'
          },
          {
            'id': 'team-2',
            'name': 'Wolves',
            'tag': 'WLF',
            'game': 'PUBG Mobile',
            'is_clan': false,
            'captain_uid': 'test-uid',
            'captain_name': 'Tester',
            'invite_code': 'XYZ789'
          },
        ],
        'team_members': [
          {
            'team_id': 'team-1',
            'firebase_uid': 'test-uid',
            'user_name': 'Tester',
            'role': 'captain'
          },
          {
            'team_id': 'team-2',
            'firebase_uid': 'test-uid',
            'user_name': 'Tester',
            'role': 'captain'
          },
        ],
        'team_invitations': [],
        'communities': [],
        'community_members': [],
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
      await tester.pumpWidget(const MaterialApp(
          home: TeamsPage(uid: 'test-uid', embedded: true)));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    testWidgets('both teams render with no CLAN pill or Clan label',
        (tester) async {
      await pumpTeams(tester);
      // Merge lane (G11): top row is [Community] [Squad] [Create] now.
      expect(find.text('Squad'), findsOneWidget);
      expect(find.text('Community'), findsOneWidget);
      expect(find.text('Create'), findsOneWidget);
      expect(find.text('Join by Code'), findsOneWidget);
      expect(find.text('Falcons'), findsOneWidget);
      expect(find.text('Wolves'), findsOneWidget);
      // No type pill/label on either card, whatever the old flag said.
      expect(find.text('CLAN'), findsNothing);
      expect(find.text('Clan'), findsNothing);
      expect(find.text('SQUAD'), findsNothing);
      // ...but the Clan War feature button is still on every card.
      expect(find.text('Clan War'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty state is team language', (tester) async {
      SupaDb.testFixtures = {
        ...SupaDb.testFixtures!,
        'teams': <Map<String, dynamic>>[],
        'team_members': <Map<String, dynamic>>[],
      };
      await pumpTeams(tester);
      expect(find.text('No team yet'), findsOneWidget);
      expect(
          find.text(
              'Aap kisi team me nahi hain. Team banayen ya invite code se join karen.'),
          findsOneWidget);
      expect(find.text('No clan yet'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
