// TEAM-INVITE NOTIFICATION FIX (2026-11-21, user report ~22:00 PKT):
// a team leader sends an invite by username, the invite SENDS fine,
// but the invitee logs in and sees NO notification anywhere to
// Accept/Reject — and never joins.
//
// Root causes (verified in code + 027/039/040 migration records):
//   RC1 — the invitee's inbox never read `team_invitations`. The only
//     discovery path was the single `user_notifications` row, so a
//     missing / swiped-away notification row left a pending invite
//     undiscoverable forever (My Team only ever listed teams the
//     user had ALREADY joined). Fix: Notifications AND My Team now
//     also read pending invites directly from `team_invitations`
//     (SupaDb.getPendingTeamInvites + mergeInviteNotifications).
//   RC2 — Accept/Decline called the 027 RPC `respond_team_invite`,
//     which is GRANT EXECUTE TO authenticated only and derives the
//     caller from firebase_uid() (auth.jwt) — but the app never signs
//     into Supabase Auth (anon key only), so the RPC always raises
//     'not authenticated'. Fix: SupaDb.respondTeamInvite now does the
//     same state change with direct writes (team_members insert +
//     team_invitations status update, verified by re-read).
//
// These tests pin both halves against the SupaDb.testFixtures seam:
// the merge/dedupe/stale-drop rules, the direct respond path, and
// the REAL NotificationsPage + TeamsPage widgets showing
// Accept/Decline — including the synthesized card when the
// notification row is MISSING entirely (the reported bug).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/more_screens.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _uid = 'invitee-uid';
const _captainUid = 'captain-uid';

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

Map<String, dynamic> _inviteRow({String status = 'pending', String id = 'invite-1', String invitedUid = _uid}) => {
      'id': id,
      'team_id': 'team-1',
      'invited_firebase_uid': invitedUid,
      'inviter_firebase_uid': _captainUid,
      'status': status,
      'created_at': '2026-11-21T10:00:00Z',
    };

Map<String, List<Map<String, dynamic>>> _fixtures({bool withNotificationRow = true, String inviteStatus = 'pending'}) => {
      'notifications': [],
      'user_notifications': withNotificationRow ? [_notifRow()] : [],
      'team_invitations': [_inviteRow(status: inviteStatus)],
      'teams': [
        {'id': 'team-1', 'name': 'Falcons', 'captain_uid': _captainUid, 'invite_code': 'ABC123'},
      ],
      'profiles': [
        {'firebase_uid': _uid, 'display_name': 'Invited Player', 'username': 'invited1'},
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

Future<void> _pumpTeams(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: TeamsPage(uid: _uid)));
  await tester.pump();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUp(() {
    // NotificationsPage._load awaits Connectivity().checkConnectivity()
    // first; with no platform handler in tests that call never
    // resolves, so _load never finishes. Mock it online.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async {
        if (call.method == 'check') return ['wifi'];
        return null;
      },
    );
    SupaDb.testFixtures = _fixtures();
  });
  tearDown(() {
    SupaDb.testFixtures = null;
  });

  group('mergeInviteNotifications (pure)', () {
    test('pending invite WITH a notification row shows exactly once', () {
      final merged = SupaDb.mergeInviteNotifications(
        [SupaDb.normNotification(_notifRow())],
        [
          {'invite_id': 'invite-1', 'team_id': 'team-1', 'team_name': 'Falcons', 'inviter_name': 'sameer', 'invited_firebase_uid': _uid, 'created_at': 0}
        ],
      );
      expect(merged.length, 1);
      expect(merged.first['invite_id'], 'invite-1');
      expect(merged.first['_synthetic_invite'], isNot(true));
    });

    test('pending invite WITHOUT a notification row gets a synthesized card', () {
      final merged = SupaDb.mergeInviteNotifications(
        [],
        [
          {'invite_id': 'invite-1', 'team_id': 'team-1', 'team_name': 'Falcons', 'inviter_name': 'sameer', 'invited_firebase_uid': _uid, 'created_at': 0}
        ],
      );
      expect(merged.length, 1);
      expect(merged.first['type'], 'team_invite');
      expect(merged.first['invite_id'], 'invite-1');
      expect(merged.first['_synthetic_invite'], true);
      expect(merged.first['message'], contains('Falcons'));
    });

    test('team_invite row whose invite is no longer pending is dropped', () {
      final merged = SupaDb.mergeInviteNotifications(
        [SupaDb.normNotification(_notifRow())],
        [],
      );
      expect(merged, isEmpty);
    });

    test('unknown pending list (failed read) leaves the inbox unchanged', () {
      final rows = [SupaDb.normNotification(_notifRow())];
      final merged = SupaDb.mergeInviteNotifications(rows, null);
      expect(merged.length, 1);
      expect(merged.first['invite_id'], 'invite-1');
    });

    test('non-invite rows pass through untouched', () {
      final other = {'id': 'n2', 'title': 'Result', 'message': 'You won!', 'timestamp': 5};
      final merged = SupaDb.mergeInviteNotifications(
        [other],
        [
          {'invite_id': 'invite-1', 'team_id': 'team-1', 'team_name': 'Falcons', 'inviter_name': '', 'invited_firebase_uid': _uid, 'created_at': 9}
        ],
      );
      expect(merged.length, 2);
      expect(merged.any((n) => n['id'] == 'n2'), true);
      expect(merged.any((n) => n['_synthetic_invite'] == true), true);
    });
  });

  group('getPendingTeamInvites', () {
    test('returns only MY pending invites', () async {
      SupaDb.testFixtures = _fixtures()
        ..['team_invitations'] = [
          _inviteRow(status: 'pending'),
          _inviteRow(status: 'declined', id: 'invite-2'),
          _inviteRow(status: 'pending', id: 'invite-3', invitedUid: 'someone-else'),
        ];
      final pending = await SupaDb.getPendingTeamInvites(_uid);
      expect(pending.map((r) => r['id']).toList(), ['invite-1']);
    });
  });

  group('respondTeamInvite (direct-write path)', () {
    test('Accept joins the team, flips the invite, clears the notification', () async {
      final res = await SupaDb.respondTeamInvite('invite-1', 'accepted', uid: _uid, userName: 'Invited Player');
      expect(res['ok'], true);
      expect(res['status'], 'accepted');
      expect(res['already_member'], false);
      final members = SupaDb.testFixtures!['team_members']!;
      expect(members.any((m) => m['firebase_uid'] == _uid && m['team_id'] == 'team-1' && m['role'] == 'member'), true);
      expect(SupaDb.testFixtures!['team_invitations']!.first['status'], 'accepted');
      expect(SupaDb.testFixtures!['user_notifications'], isEmpty);
    });

    test('Decline flips the invite without joining', () async {
      final res = await SupaDb.respondTeamInvite('invite-1', 'declined', uid: _uid);
      expect(res['ok'], true);
      expect(res['status'], 'declined');
      expect(SupaDb.testFixtures!['team_members']!.any((m) => m['firebase_uid'] == _uid), false);
      expect(SupaDb.testFixtures!['team_invitations']!.first['status'], 'declined');
    });

    test('second respond fails as already-responded', () async {
      await SupaDb.respondTeamInvite('invite-1', 'accepted', uid: _uid);
      final res = await SupaDb.respondTeamInvite('invite-1', 'accepted', uid: _uid);
      expect(res['ok'], false);
      expect(res['error'], contains('pehle hi respond'));
    });

    test('another user cannot respond to my invite', () async {
      final res = await SupaDb.respondTeamInvite('invite-1', 'accepted', uid: 'someone-else');
      expect(res['ok'], false);
      expect(res['error'], contains('aap ki nahi'));
    });

    test('Accept when already a member still marks accepted (no double join)', () async {
      SupaDb.testFixtures!['team_members']!.add({'team_id': 'team-1', 'firebase_uid': _uid, 'user_name': 'Invited Player', 'role': 'member'});
      final res = await SupaDb.respondTeamInvite('invite-1', 'accepted', uid: _uid);
      expect(res['ok'], true);
      expect(res['already_member'], true);
      expect(SupaDb.testFixtures!['team_members']!.where((m) => m['firebase_uid'] == _uid).length, 1);
    });
  });

  group('NotificationsPage (widget)', () {
    testWidgets('shows Accept/Decline from the real notification row', (tester) async {
      await _pumpNotifications(tester);
      expect(find.text('Team Invitation'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);
    });

    testWidgets('shows Accept/Decline from the SYNTHESIZED card when the notification row is missing', (tester) async {
      SupaDb.testFixtures = _fixtures(withNotificationRow: false);
      await _pumpNotifications(tester);
      // The reported bug: no notification row -> no card at all.
      // The direct team_invitations read must still surface it.
      expect(find.text('Team Invitation'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);
    });

    testWidgets('drops a stale team_invite row whose invite is no longer pending', (tester) async {
      SupaDb.testFixtures = _fixtures(inviteStatus: 'accepted');
      await _pumpNotifications(tester);
      expect(find.text('Accept'), findsNothing);
      expect(find.text('No notifications.'), findsOneWidget);
    });

    testWidgets('tapping Accept joins the team and removes the card', (tester) async {
      SupaDb.testFixtures = _fixtures(withNotificationRow: false);
      await _pumpNotifications(tester);
      await tester.tap(find.text('Accept'));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('Accept'), findsNothing);
      expect(SupaDb.testFixtures!['team_members']!.any((m) => m['firebase_uid'] == _uid && m['role'] == 'member'), true);
      expect(SupaDb.testFixtures!['team_invitations']!.first['status'], 'accepted');
    });
  });

  group('TeamsPage (widget)', () {
    testWidgets('shows the TEAM INVITATIONS section with Accept/Decline', (tester) async {
      await _pumpTeams(tester);
      expect(find.text('TEAM INVITATIONS'), findsOneWidget);
      expect(find.text('Falcons'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);
    });

    testWidgets('tapping Accept joins the team and clears the section', (tester) async {
      await _pumpTeams(tester);
      await tester.tap(find.text('Accept'));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('TEAM INVITATIONS'), findsNothing);
      // The joined team now appears in the team list below.
      expect(find.text('Falcons'), findsOneWidget);
      expect(SupaDb.testFixtures!['team_members']!.any((m) => m['firebase_uid'] == _uid && m['role'] == 'member'), true);
    });
  });

  group('inviteRespondErrorMessage (2026-11-22 report)', () {
    test('maps the exact live P0001 toast to friendly Urdu text', () {
      const raw =
          'PostgrestException(message: not authenticated, code: P0001, details: Bad Request, hint: null)';
      final msg = SupaDb.inviteRespondErrorMessage(raw);
      expect(msg.contains('PostgrestException'), false);
      expect(msg.contains('P0001'), false);
      expect(msg.contains('purani build'), true);
    });

    test('keeps the permission mapping for RLS failures', () {
      expect(
        SupaDb.inviteRespondErrorMessage('new row violates row-level security policy'),
        'Invite respond nahi ho saki (permission).',
      );
    });

    test('passes unknown errors through unchanged', () {
      const raw = 'SocketException: Failed host lookup';
      expect(SupaDb.inviteRespondErrorMessage(raw), raw);
    });
  });
}
