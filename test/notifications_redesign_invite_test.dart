// NOTIFICATIONS REDESIGN + TEAM-INVITE FLOW (2026-11-21, mockup #21
// same-to-same, user voice call ~22:44 PKT):
//   * unread card = gold border + glow + gold dot at the top-right
//     corner; read card = plain border, no dot;
//   * filter pills share the full width (All / Matches / Events /
//     System), selected pill gold filled;
//   * Team Invitation card keeps Accept/Decline INSIDE the card;
//   * invite rows are NEVER deletable (swipe / Clear-all /
//     Delete-selected all skip them) — only Accept/Decline removes
//     a pending invite, because a deleted notification row just
//     re-synthesizes on the next load;
//   * sendTeamInvite writes invite row + invitee notification row
//     (+ best-effort OneSignal push with the REAL team name).
//
// Pinned against the SupaDb.testFixtures seam (no network): the
// REAL NotificationsPage widget + the send/push unit paths. The
// mock sample names in the task ("Squad Showdown", "Team Alpha",
// "10m/15m/2h") are NEVER used here — fixture data uses its own
// team name and real timestamps.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/arena_components.dart';
import 'package:protournament_user/screens/more_screens.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _uid = 'invitee-uid';
const _captainUid = 'captain-uid';
const _gold = Color(0xFFFDC903);

Map<String, dynamic> _notifRow() => {
      'id': 'notif-1',
      'firebase_uid': _uid,
      'type': 'team_invite',
      'invite_id': 'invite-1',
      'team_id': 'team-1',
      'title': 'Team Invitation',
      'message': 'Falcons has invited you to join their squad for the next event.',
      'created_at': '2026-11-21T10:00:00Z',
    };

Map<String, dynamic> _plainRow() => {
      'id': 'notif-plain',
      'firebase_uid': _uid,
      'title': 'Rule Update',
      'message': 'The tournament rules have been updated.',
      'created_at': '2026-11-21T09:00:00Z',
    };

Map<String, dynamic> _matchRow() => {
      'id': 'notif-match',
      'firebase_uid': _uid,
      'title': 'Match Result',
      'message': 'You won the match! See how you ranked.',
      'created_at': '2026-11-21T08:00:00Z',
    };

Map<String, dynamic> _inviteRow({String status = 'pending'}) => {
      'id': 'invite-1',
      'team_id': 'team-1',
      'invited_firebase_uid': _uid,
      'inviter_firebase_uid': _captainUid,
      'status': status,
      'created_at': '2026-11-21T10:00:00Z',
    };

Map<String, List<Map<String, dynamic>>> _fixtures({
  bool withNotificationRow = true,
  bool withPlainRow = false,
  bool withMatchRow = false,
  String inviteStatus = 'pending',
  int lastChecked = 0,
}) => {
      'notifications': [],
      'user_notifications': [
        if (withNotificationRow) _notifRow(),
        if (withPlainRow) _plainRow(),
        if (withMatchRow) _matchRow(),
      ],
      'team_invitations': [_inviteRow(status: inviteStatus)],
      'teams': [
        {'id': 'team-1', 'name': 'Falcons', 'captain_uid': _captainUid, 'invite_code': 'ABC123'},
      ],
      'profiles': [
        {'firebase_uid': _uid, 'display_name': 'Invited Player', 'username': 'invited1', 'last_checked_notifications': lastChecked},
        {'firebase_uid': _captainUid, 'display_name': 'sameer', 'username': 'sameer'},
      ],
      'team_members': [
        {'team_id': 'team-1', 'firebase_uid': _captainUid, 'user_name': 'sameer', 'role': 'captain'},
      ],
    };

/// Pumps [NotificationsPage] and lets its async _load finish. No
/// pumpAndSettle — MockupCard shine / ember animations repeat forever.
Future<void> _pumpNotifications(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: NotificationsPage(uid: _uid)));
  await tester.pump();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// The unread card's gold border wrapper: radius 16, gold border,
/// gold glow shadow. (The active filter pill is also gold-bordered
/// but radius 20 with no shadow, so this predicate cannot match it.)
Finder _goldBorderCard() => find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).borderRadius == BorderRadius.circular(16) &&
          (w.decoration as BoxDecoration).border is Border &&
          ((w.decoration as BoxDecoration).border as Border).top.color == _gold &&
          ((w.decoration as BoxDecoration).boxShadow?.isNotEmpty ?? false),
    );

/// The corner gold dot: a 10x10 gold circle.
Finder _goldDot() => find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle &&
          (w.decoration as BoxDecoration).color == _gold,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async {
        if (call.method == 'check') return ['wifi'];
        return null;
      },
    );
    SupaDb.testFixtures = _fixtures();
    SupaDb.lastInvitePushAttempt = null;
  });
  tearDown(() {
    SupaDb.testFixtures = null;
    SupaDb.lastInvitePushAttempt = null;
  });

  group('sendTeamInvite (fixture path)', () {
    test('writes the invite row + the invitee notification row with the real team name', () async {
      SupaDb.testFixtures = _fixtures()
        ..['team_invitations'] = []
        ..['user_notifications'] = [];
      final res = await SupaDb.sendTeamInvite(
        teamId: 'team-1',
        teamName: 'Falcons',
        invitedUid: _uid,
        inviterUid: _captainUid,
        inviterName: 'sameer',
      );
      expect(res['ok'], true);
      final inviteId = res['invite_id'] as String;
      expect(inviteId.isNotEmpty, true);
      final invites = SupaDb.testFixtures!['team_invitations']!;
      expect(invites.length, 1);
      expect(invites.first['status'], 'pending');
      expect(invites.first['invited_firebase_uid'], _uid);
      final notifs = SupaDb.testFixtures!['user_notifications']!;
      expect(notifs.length, 1);
      expect(notifs.first['type'], 'team_invite');
      expect(notifs.first['invite_id'], inviteId);
      expect(notifs.first['message'], contains('Falcons'));
    });

    test('duplicate pending invite is rejected, never double-written', () async {
      final res = await SupaDb.sendTeamInvite(
        teamId: 'team-1',
        teamName: 'Falcons',
        invitedUid: _uid,
        inviterUid: _captainUid,
      );
      expect(res['ok'], false);
      expect(res['error'], contains('pehle se pending'));
      expect(SupaDb.testFixtures!['team_invitations']!.length, 1);
      expect(SupaDb.testFixtures!['user_notifications']!.length, 1);
    });
  });

  group('sendTeamInvitePush', () {
    test('records the real invite (team name + invitee uid) without any network in tests', () async {
      final res = await SupaDb.sendTeamInvitePush(invitedUid: _uid, teamName: 'Falcons', inviterName: 'sameer');
      expect(res['configured'], false); // test mode: no network, no send.
      final attempt = SupaDb.lastInvitePushAttempt!;
      expect(attempt['invited_uid'], _uid);
      expect(attempt['title'], 'Team Invitation');
      expect(attempt['message'], contains('Falcons'));
      expect(attempt['message'], contains('sameer'));
    });

    test('sendTeamInvite attempts the push as part of the send', () async {
      SupaDb.testFixtures = _fixtures()
        ..['team_invitations'] = []
        ..['user_notifications'] = [];
      final res = await SupaDb.sendTeamInvite(
        teamId: 'team-1',
        teamName: 'Falcons',
        invitedUid: _uid,
        inviterUid: _captainUid,
        inviterName: 'sameer',
      );
      expect(res['ok'], true);
      expect(SupaDb.lastInvitePushAttempt?['invited_uid'], _uid);
      expect(SupaDb.lastInvitePushAttempt?['message'], contains('Falcons'));
    });
  });

  group('NotificationsPage redesign (mockup #21, widget)', () {
    testWidgets('header + Mark All Read pill + all four filter pills', (tester) async {
      await _pumpNotifications(tester);
      expect(find.text('NOTIFICATIONS'), findsOneWidget);
      expect(find.text('Mark All Read'), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Matches'), findsOneWidget);
      // v2011: 'Events' also labels a bottom-nav tab, so the filter
      // pill must be scoped to the FilterTabs row — both are
      // legitimate, neither is a duplicate bug.
      expect(
        find.descendant(of: find.byType(FilterTabs), matching: find.text('Events')),
        findsOneWidget,
      );
      expect(find.text('System'), findsOneWidget);
    });

    testWidgets('UNREAD invite card: gold border + glow + corner gold dot + Accept/Decline', (tester) async {
      await _pumpNotifications(tester);
      expect(find.text('Team Invitation'), findsOneWidget);
      expect(_goldBorderCard(), findsOneWidget);
      expect(_goldDot(), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);
      // Real team name + real time, never mock copy.
      expect(find.textContaining('Falcons'), findsOneWidget);
    });

    testWidgets('READ card: plain border, no gold border, no dot', (tester) async {
      SupaDb.testFixtures = _fixtures(lastChecked: DateTime.now().millisecondsSinceEpoch + 100000000);
      await _pumpNotifications(tester);
      expect(find.text('Team Invitation'), findsOneWidget);
      expect(_goldBorderCard(), findsNothing);
      expect(_goldDot(), findsNothing);
      // Buttons stay — read/unread never gates the invite actions.
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);
    });

    testWidgets('filter pills: invite shows under All + Events, not under Matches', (tester) async {
      SupaDb.testFixtures = _fixtures(withMatchRow: true);
      await _pumpNotifications(tester);
      expect(find.text('Team Invitation'), findsOneWidget);
      expect(find.text('Match Result'), findsOneWidget);
      await tester.tap(find.text('Matches'));
      await tester.pump();
      expect(find.text('Match Result'), findsOneWidget);
      expect(find.text('Team Invitation'), findsNothing);
      // v2011: tap the FILTER pill, not the bottom-nav 'Events' tab.
      await tester.tap(
        find.descendant(of: find.byType(FilterTabs), matching: find.text('Events')),
      );
      await tester.pump();
      expect(find.text('Team Invitation'), findsOneWidget);
      expect(find.text('Match Result'), findsNothing);
      await tester.tap(find.text('All'));
      await tester.pump();
      expect(find.text('Team Invitation'), findsOneWidget);
      expect(find.text('Match Result'), findsOneWidget);
    });

    testWidgets('empty inbox shows the honest empty state', (tester) async {
      SupaDb.testFixtures = _fixtures(withNotificationRow: false, inviteStatus: 'accepted');
      await _pumpNotifications(tester);
      expect(find.text('No notifications.'), findsOneWidget);
      expect(find.text('Accept'), findsNothing);
    });
  });

  group('NotificationsPage invite actions (widget)', () {
    testWidgets('tapping Decline declines the invite and removes the card without joining', (tester) async {
      await _pumpNotifications(tester);
      await tester.tap(find.text('Decline'));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('Accept'), findsNothing);
      expect(SupaDb.testFixtures!['team_invitations']!.first['status'], 'declined');
      expect(SupaDb.testFixtures!['team_members']!.any((m) => m['firebase_uid'] == _uid), false);
    });

    testWidgets('swiping an invite card does NOT delete it (only Accept/Decline removes it)', (tester) async {
      await _pumpNotifications(tester);
      expect(find.text('Accept'), findsOneWidget);
      await tester.drag(find.text('Team Invitation'), const Offset(-400, 0));
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('Team Invitation'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(SupaDb.testFixtures!['team_invitations']!.first['status'], 'pending');
    });

    testWidgets('Clear-all keeps the pending invite card', (tester) async {
      SupaDb.testFixtures = _fixtures(withPlainRow: true);
      await _pumpNotifications(tester);
      expect(find.text('Team Invitation'), findsOneWidget);
      await tester.tap(find.text('Clear all'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Delete All'), findsOneWidget);
      await tester.tap(find.text('Delete All'));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      // The invite is still pending, so its card must still be there.
      expect(find.text('Team Invitation'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
    });
  });
}
