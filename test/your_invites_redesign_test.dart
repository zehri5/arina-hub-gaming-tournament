// YOUR INVITES REDESIGN (2026-11-21, user order — reference
// 1000048236_36_2szc.jpg, element by element):
//   * stats card: strong gold glow border, sparkles inside, big
//     gold TOTAL / SUCCESSFUL numbers (REAL counts only);
//   * milestone row: "N more to Next Milestone" (number gold, rest
//     white) + successful/next (first number gold) + gold bar on a
//     grey track + treasure chest — thresholds ONLY from the
//     configured referral_milestones rows at runtime, never a
//     hardcoded 12/20 or 20 (and never hardcoded 5/10/15 either —
//     those are just the current live tiers, used here as FIXTURE
//     data); no tiers configured = honest empty text, NO fake bar;
//   * next milestone = the SMALLEST threshold greater than the real
//     successful count; "N more" = next − successful; all reached
//     = completed state, never a broken bar or fake next target;
//   * history rows (mockup-style when present): avatar + real name
//     + "Joined/Invited <date>" + VERIFIED (gold fill + check) /
//     JOINED (gold outline) / INVITED (grey fill) pill; 0 invites =
//     the honest "No invitations yet." empty state;
//   * bottom: "Share your code: <real code>" + INVITE FRIENDS;
//   * pending TEAM invites (Accept/Decline) at the TOP — the section
//     only renders while one is actually pending.
//
// Pins the REAL-data rendering against the SupaDb.testFixtures
// seam (same pattern as team_invite_notification_test.dart). No
// mock names/dates/code from the reference appear anywhere here.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/more_screens.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _uid = 'invitee-uid';
const _captainUid = 'captain-uid';

Map<String, dynamic> _profileRow({String code = '502X1NFC'}) => {
      'firebase_uid': _uid,
      'display_name': 'Test Player',
      'username': 'testplayer',
      'referral_code': code,
    };

Map<String, dynamic> _inviteRow({
  String referredUid = 'friend-1',
  String email = 'alpha@example.com',
  String status = 'invited',
  String createdAt = '2025-11-23T12:00:00Z',
}) => {
      'referrer_uid': _uid,
      'referred_uid': referredUid,
      'referred_email': email,
      'status': status,
      'created_at': createdAt,
    };

// The LIVE referral_milestones tiers (backend check 2026-11-21
// ~22:42 PKT) — used here as FIXTURE data only. The app reads
// them at runtime; nothing in lib/ hardcodes these numbers.
List<Map<String, dynamic>> _liveTiers() => [
      {'milestone_friends': 5, 'points': 10, 'title': '5 friends'},
      {'milestone_friends': 10, 'points': 7, 'title': '10 friends'},
      {'milestone_friends': 15, 'points': 30, 'title': '15 friends'},
    ];

Map<String, dynamic> _teamInviteRow({String status = 'pending', String id = 'invite-1'}) => {
      'id': id,
      'team_id': 'team-1',
      'invited_firebase_uid': _uid,
      'inviter_firebase_uid': _captainUid,
      'status': status,
      'created_at': '2026-11-21T10:00:00Z',
    };

Map<String, List<Map<String, dynamic>>> _fixtures({
  List<Map<String, dynamic>>? invites,
  List<Map<String, dynamic>>? milestones,
  bool withTeamInvite = false,
}) => {
      'profiles': [
        _profileRow(),
        {'firebase_uid': _captainUid, 'display_name': 'sameer', 'username': 'sameer'},
      ],
      'pending_referrals': invites ?? [],
      'referral_milestones': milestones ?? [],
      'team_invitations': withTeamInvite ? [_teamInviteRow()] : [],
      'teams': [
        {'id': 'team-1', 'name': 'Falcons', 'captain_uid': _captainUid, 'invite_code': 'ABC123'},
      ],
      'team_members': [
        {'team_id': 'team-1', 'firebase_uid': _captainUid, 'user_name': 'sameer', 'role': 'captain'},
      ],
      'user_notifications': [],
    };

/// Pumps [YourInvitesPage] and lets its async _load finish. No
/// pumpAndSettle — the _EmberDots sparkles repeat forever.
Future<void> _pumpInvites(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: YourInvitesPage(uid: _uid)));
  await tester.pump();
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUp(() {
    // YourInvitesPage._load awaits _isOnline() (Connectivity) first;
    // with no platform handler in tests that call never resolves,
    // so _load never finishes. Mock it online.
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

  group('milestone math (runtime thresholds)', () {
    testWidgets('next = smallest threshold above successful; "N more" + "successful/next"', (tester) async {
      SupaDb.testFixtures = _fixtures(
        invites: [
          _inviteRow(status: 'joined', email: 'alpha@example.com'),
          _inviteRow(referredUid: 'friend-2', email: 'beta@example.com', status: 'verified'),
          _inviteRow(referredUid: 'friend-3', email: 'gamma@example.com', status: 'invited'),
        ],
        milestones: _liveTiers(),
      );
      await _pumpInvites(tester);
      // Real counts: 3 total, 2 successful.
      expect(find.text('YOUR INVITES'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      // Next milestone is 5 (not 20, not hardcoded): 5 − 2 = 3 more.
      expect(find.text('3 more to Next Milestone', findRichText: true), findsOneWidget);
      expect(find.textContaining('/5', findRichText: true), findsOneWidget);
      // Bar + chest render (bar is the only progress indicator).
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('at 0 successful the next milestone is 5: "5 more", "0/5"', (tester) async {
      SupaDb.testFixtures = _fixtures(invites: [], milestones: _liveTiers());
      await _pumpInvites(tester);
      expect(find.text('5 more to Next Milestone', findRichText: true), findsOneWidget);
      expect(find.textContaining('/5', findRichText: true), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('no tiers configured = honest empty text, NO fake bar', (tester) async {
      SupaDb.testFixtures = _fixtures(invites: [], milestones: []);
      await _pumpInvites(tester);
      expect(find.text('No community milestones have been set up yet.'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('more to Next Milestone'), findsNothing);
    });

    testWidgets('all milestones reached = completed state, full bar, no fake next target', (tester) async {
      SupaDb.testFixtures = _fixtures(
        invites: [
          _inviteRow(status: 'joined', email: 'alpha@example.com'),
          _inviteRow(referredUid: 'friend-2', email: 'beta@example.com', status: 'joined'),
          _inviteRow(referredUid: 'friend-3', email: 'gamma@example.com', status: 'verified'),
        ],
        milestones: [
          {'milestone_friends': 2, 'points': 5, 'title': '2 friends'},
        ],
      );
      await _pumpInvites(tester);
      expect(find.text('All milestones reached'), findsOneWidget);
      expect(find.textContaining('/2', findRichText: true), findsOneWidget);
      expect(find.text('more to Next Milestone'), findsNothing);
      final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      expect(bar.value, 1.0);
    });
  });

  group('invitation history (real data, mockup pills)', () {
    testWidgets('rows show real names, reference dates, and all three pills', (tester) async {
      SupaDb.testFixtures = _fixtures(
        invites: [
          _inviteRow(status: 'verified', email: 'alpha@example.com', createdAt: '2025-11-23T12:00:00Z'),
          _inviteRow(referredUid: 'friend-2', email: 'beta@example.com', status: 'joined', createdAt: '2025-11-21T12:00:00Z'),
          _inviteRow(referredUid: 'friend-3', email: 'gamma@example.com', status: 'invited', createdAt: '2025-11-20T12:00:00Z'),
        ],
        milestones: _liveTiers(),
      );
      await _pumpInvites(tester);
      expect(find.text('INVITATION HISTORY'), findsOneWidget);
      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);
      expect(find.text('gamma'), findsOneWidget);
      expect(find.text('Joined Nov 23, 2025'), findsOneWidget);
      expect(find.text('Joined Nov 21, 2025'), findsOneWidget);
      expect(find.text('Invited Nov 20, 2025'), findsOneWidget);
      expect(find.text('VERIFIED'), findsOneWidget);
      expect(find.text('JOINED'), findsOneWidget);
      expect(find.text('INVITED'), findsOneWidget);
      // No reference mock values anywhere on the page.
      expect(find.text('Specter_007'), findsNothing);
      expect(find.text('ARENA123'), findsNothing);
    });

    testWidgets('0 invites = honest empty state, no fake rows', (tester) async {
      SupaDb.testFixtures = _fixtures(invites: [], milestones: _liveTiers());
      await _pumpInvites(tester);
      expect(find.text('No invitations yet.'), findsOneWidget);
      expect(find.text('VERIFIED'), findsNothing);
      expect(find.text('JOINED'), findsNothing);
      expect(find.text('INVITED'), findsNothing);
    });
  });

  group('share code + CTA', () {
    testWidgets('shows the REAL referral code, never the reference mock', (tester) async {
      SupaDb.testFixtures = _fixtures(invites: [], milestones: []);
      await _pumpInvites(tester);
      expect(find.textContaining('502X1NFC', findRichText: true), findsOneWidget);
      expect(find.text('ARENA123'), findsNothing);
      expect(find.text('INVITE FRIENDS'), findsOneWidget);
    });
  });

  group('pending team invites (top section)', () {
    testWidgets('shows TEAM INVITATIONS with Accept/Decline when one is pending', (tester) async {
      SupaDb.testFixtures = _fixtures(invites: [], milestones: [], withTeamInvite: true);
      await _pumpInvites(tester);
      expect(find.text('TEAM INVITATIONS'), findsOneWidget);
      expect(find.text('Falcons'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);
    });

    testWidgets('no pending invite = no section (reference match untouched)', (tester) async {
      SupaDb.testFixtures = _fixtures(invites: [], milestones: [], withTeamInvite: false);
      await _pumpInvites(tester);
      expect(find.text('TEAM INVITATIONS'), findsNothing);
      expect(find.text('Accept'), findsNothing);
    });

    testWidgets('tapping Accept joins the team and clears the section', (tester) async {
      SupaDb.testFixtures = _fixtures(invites: [], milestones: [], withTeamInvite: true);
      await _pumpInvites(tester);
      await tester.tap(find.text('Accept'));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('TEAM INVITATIONS'), findsNothing);
      expect(SupaDb.testFixtures!['team_members']!.any((m) => m['firebase_uid'] == _uid && m['role'] == 'member'), true);
      expect(SupaDb.testFixtures!['team_invitations']!.first['status'], 'accepted');
    });

    testWidgets('tapping Decline clears the section without joining', (tester) async {
      SupaDb.testFixtures = _fixtures(invites: [], milestones: [], withTeamInvite: true);
      await _pumpInvites(tester);
      await tester.tap(find.text('Decline'));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('TEAM INVITATIONS'), findsNothing);
      expect(SupaDb.testFixtures!['team_members']!.any((m) => m['firebase_uid'] == _uid), false);
      expect(SupaDb.testFixtures!['team_invitations']!.first['status'], 'declined');
    });
  });
}
