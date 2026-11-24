// v2016 FIX 15 — community organizer moderation tests.
//
// Once the app admin approves voice for a public community
// (communities.voice_enabled), the community ORGANIZER (creator)
// gets admin-like powers INSIDE THAT COMMUNITY ONLY: mute
// (LiveKit data packet), ban/block/kick (community-scoped
// chat_restrictions row) and chat-history delete.
//
// Everything here runs against SupaDb.testFixtures (the FIX 6
// seam) — no Supabase, no network. The scoping tests are the
// point: an organizer of community A must NEVER moderate
// community B.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:protournament_user/community_service.dart';
import 'package:protournament_user/screens/communities_screens.dart';
import 'package:protournament_user/services/livekit_voice_service.dart';
import 'package:protournament_user/services/supabase_db.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SupaDb.testFixtures = {
      'communities': [
        {
          'id': 'comm-a',
          'name': 'Alpha',
          'created_by_uid': 'u-org-a',
          'voice_enabled': true,
        },
        {
          'id': 'comm-b',
          'name': 'Beta',
          'created_by_uid': 'u-org-b',
          'voice_enabled': true,
        },
        {
          'id': 'comm-c',
          'name': 'Gamma',
          'created_by_uid': 'u-org-a',
          'voice_enabled': false,
        },
      ],
      'community_members': [
        {'community_id': 'comm-a', 'firebase_uid': 'u-org-a', 'role': 'creator'},
        {'community_id': 'comm-a', 'firebase_uid': 'u-mem', 'role': 'member'},
        {'community_id': 'comm-b', 'firebase_uid': 'u-org-b', 'role': 'creator'},
        // u-org-a is a plain MEMBER of B (organizer of A only).
        {'community_id': 'comm-b', 'firebase_uid': 'u-org-a', 'role': 'member'},
        {'community_id': 'comm-b', 'firebase_uid': 'u-mem', 'role': 'member'},
        {'community_id': 'comm-c', 'firebase_uid': 'u-org-a', 'role': 'creator'},
        {'community_id': 'comm-c', 'firebase_uid': 'u-mem', 'role': 'member'},
      ],
      'chat_restrictions': [],
      'chat_messages': [
        {
          'id': 'm1',
          'scope': 'community',
          'community_id': 'comm-a',
          'firebase_uid': 'u-mem',
          'message': 'hello A',
        },
        {
          'id': 'm2',
          'scope': 'community',
          'community_id': 'comm-a',
          'firebase_uid': 'u-org-a',
          'message': 'hi A',
        },
        {
          'id': 'm3',
          'scope': 'community',
          'community_id': 'comm-b',
          'firebase_uid': 'u-mem',
          'message': 'hello B',
        },
      ],
    };
  });

  tearDown(() {
    SupaDb.testFixtures = null;
  });

  group('isOrganizerOf (pure)', () {
    test('creator by created_by_uid', () {
      expect(
          CommunityGroups.isOrganizerOf(
              uid: 'u1', createdByUid: 'u1', role: 'member'),
          isTrue);
    });

    test('creator by role row', () {
      expect(
          CommunityGroups.isOrganizerOf(
              uid: 'u1', createdByUid: 'u2', role: 'creator'),
          isTrue);
    });

    test('plain member is not the organizer', () {
      expect(
          CommunityGroups.isOrganizerOf(
              uid: 'u1', createdByUid: 'u2', role: 'member'),
          isFalse);
    });

    test('empty uid is never the organizer', () {
      expect(
          CommunityGroups.isOrganizerOf(
              uid: '', createdByUid: '', role: 'creator'),
          isFalse);
    });
  });

  group('canOrganizerModerate (pure)', () {
    test('organizer + voice approved can moderate', () {
      expect(
          CommunityGroups.canOrganizerModerate(
              isOrganizer: true, voiceApproved: true),
          isTrue);
    });

    test('organizer without voice approval cannot', () {
      expect(
          CommunityGroups.canOrganizerModerate(
              isOrganizer: true, voiceApproved: false),
          isFalse);
    });

    test('non-organizer with voice approval cannot', () {
      expect(
          CommunityGroups.canOrganizerModerate(
              isOrganizer: false, voiceApproved: true),
          isFalse);
    });
  });

  group('isRestrictedInCommunityRows (pure)', () {
    test('global row restricts in every community', () {
      final rows = [
        {'firebase_uid': 'u1', 'reason': 'x'},
      ];
      expect(SupaDb.isRestrictedInCommunityRows(rows, 'comm-a'), isTrue);
      expect(SupaDb.isRestrictedInCommunityRows(rows, 'comm-b'), isTrue);
    });

    test('scoped row restricts only its own community', () {
      final rows = [
        {'firebase_uid': 'u1', 'community_id': 'comm-a'},
      ];
      expect(SupaDb.isRestrictedInCommunityRows(rows, 'comm-a'), isTrue);
      expect(SupaDb.isRestrictedInCommunityRows(rows, 'comm-b'), isFalse);
    });

    test('no rows means not restricted', () {
      expect(SupaDb.isRestrictedInCommunityRows([], 'comm-a'), isFalse);
    });
  });

  group('isChatRestrictedInCommunity (fixtures)', () {
    test('scoped row for A restricts in A only', () async {
      SupaDb.testFixtures!['chat_restrictions'] = [
        {'firebase_uid': 'u-mem', 'community_id': 'comm-a'},
      ];
      expect(
          await SupaDb.isChatRestrictedInCommunity('u-mem', 'comm-a'),
          isTrue);
      expect(
          await SupaDb.isChatRestrictedInCommunity('u-mem', 'comm-b'),
          isFalse);
    });

    test('global row restricts everywhere', () async {
      SupaDb.testFixtures!['chat_restrictions'] = [
        {'firebase_uid': 'u-mem'},
      ];
      expect(
          await SupaDb.isChatRestrictedInCommunity('u-mem', 'comm-a'),
          isTrue);
      expect(
          await SupaDb.isChatRestrictedInCommunity('u-mem', 'comm-b'),
          isTrue);
    });

    test('empty uid or community is never restricted', () async {
      expect(await SupaDb.isChatRestrictedInCommunity('', 'comm-a'),
          isFalse);
      expect(await SupaDb.isChatRestrictedInCommunity('u-mem', ''), isFalse);
    });
  });

  group('isCommunityVoiceApproved (fixtures)', () {
    test('true when the flag is true', () async {
      expect(await CommunityGroups.isCommunityVoiceApproved('comm-a'),
          isTrue);
    });

    test('false when the flag is false', () async {
      expect(await CommunityGroups.isCommunityVoiceApproved('comm-c'),
          isFalse);
    });

    test('false for a missing community', () async {
      expect(await CommunityGroups.isCommunityVoiceApproved('comm-nope'),
          isFalse);
    });
  });

  group('isOrganizer (fixtures)', () {
    test('organizer of A is organizer of A', () async {
      expect(await CommunityGroups.isOrganizer('u-org-a', 'comm-a'), isTrue);
    });

    test('organizer of A is NOT organizer of B', () async {
      expect(await CommunityGroups.isOrganizer('u-org-a', 'comm-b'), isFalse);
    });

    test('plain member is not the organizer', () async {
      expect(await CommunityGroups.isOrganizer('u-mem', 'comm-a'), isFalse);
    });
  });

  group('restrictMemberInCommunity (fixtures) — SCOPING', () {
    test('organizer of A blocks a member in A (scoped row)', () async {
      final res = await CommunityGroups.restrictMemberInCommunity(
          communityId: 'comm-a',
          requesterUid: 'u-org-a',
          targetUid: 'u-mem');
      expect(res['ok'], isTrue);
      final rows = SupaDb.testFixtures!['chat_restrictions']!;
      expect(rows.length, 1);
      expect(rows.first['firebase_uid'], 'u-mem');
      expect(rows.first['community_id'], 'comm-a');
      expect(
          await SupaDb.isChatRestrictedInCommunity('u-mem', 'comm-a'),
          isTrue);
      expect(
          await SupaDb.isChatRestrictedInCommunity('u-mem', 'comm-b'),
          isFalse);
    });

    test('organizer of A CANNOT block in B', () async {
      final res = await CommunityGroups.restrictMemberInCommunity(
          communityId: 'comm-b',
          requesterUid: 'u-org-a',
          targetUid: 'u-mem');
      expect(res['ok'], isFalse);
      expect(SupaDb.testFixtures!['chat_restrictions'], isEmpty);
      expect(
          await SupaDb.isChatRestrictedInCommunity('u-mem', 'comm-b'),
          isFalse);
    });

    test('plain member cannot block anyone', () async {
      final res = await CommunityGroups.restrictMemberInCommunity(
          communityId: 'comm-a',
          requesterUid: 'u-mem',
          targetUid: 'u-org-a');
      expect(res['ok'], isFalse);
      expect(SupaDb.testFixtures!['chat_restrictions'], isEmpty);
    });

    test('organizer cannot block before voice approval', () async {
      final res = await CommunityGroups.restrictMemberInCommunity(
          communityId: 'comm-c',
          requesterUid: 'u-org-a',
          targetUid: 'u-mem');
      expect(res['ok'], isFalse);
      expect(SupaDb.testFixtures!['chat_restrictions'], isEmpty);
    });

    test('cannot block the creator or self', () async {
      final creator = await CommunityGroups.restrictMemberInCommunity(
          communityId: 'comm-b',
          requesterUid: 'u-org-b',
          targetUid: 'u-org-b');
      expect(creator['ok'], isFalse);
      final self = await CommunityGroups.restrictMemberInCommunity(
          communityId: 'comm-a',
          requesterUid: 'u-org-a',
          targetUid: 'u-org-a');
      expect(self['ok'], isFalse);
      expect(SupaDb.testFixtures!['chat_restrictions'], isEmpty);
    });

    test('cannot block a non-member', () async {
      final res = await CommunityGroups.restrictMemberInCommunity(
          communityId: 'comm-a',
          requesterUid: 'u-org-a',
          targetUid: 'u-stranger');
      expect(res['ok'], isFalse);
      expect(SupaDb.testFixtures!['chat_restrictions'], isEmpty);
    });

    test('blocking twice is idempotent (no duplicate row)', () async {
      await CommunityGroups.restrictMemberInCommunity(
          communityId: 'comm-a',
          requesterUid: 'u-org-a',
          targetUid: 'u-mem');
      final second = await CommunityGroups.restrictMemberInCommunity(
          communityId: 'comm-a',
          requesterUid: 'u-org-a',
          targetUid: 'u-mem');
      expect(second['ok'], isTrue);
      expect(second['already'], isTrue);
      expect(SupaDb.testFixtures!['chat_restrictions']!.length, 1);
    });
  });

  group('unrestrictMemberInCommunity (fixtures)', () {
    test('lifts only the scoped row, never a global admin row',
        () async {
      SupaDb.testFixtures!['chat_restrictions'] = [
        {'firebase_uid': 'u-mem', 'community_id': 'comm-a'},
        {'firebase_uid': 'u-mem', 'reason': 'admin block'},
      ];
      final res = await CommunityGroups.unrestrictMemberInCommunity(
          communityId: 'comm-a',
          requesterUid: 'u-org-a',
          targetUid: 'u-mem');
      expect(res['ok'], isTrue);
      final rows = SupaDb.testFixtures!['chat_restrictions']!;
      expect(rows.length, 1);
      expect(rows.first['community_id'], isNull);
      // The global admin block still applies in A.
      expect(
          await SupaDb.isChatRestrictedInCommunity('u-mem', 'comm-a'),
          isTrue);
    });

    test('organizer of A CANNOT unblock in B', () async {
      SupaDb.testFixtures!['chat_restrictions'] = [
        {'firebase_uid': 'u-mem', 'community_id': 'comm-b'},
      ];
      final res = await CommunityGroups.unrestrictMemberInCommunity(
          communityId: 'comm-b',
          requesterUid: 'u-org-a',
          targetUid: 'u-mem');
      expect(res['ok'], isFalse);
      expect(SupaDb.testFixtures!['chat_restrictions']!.length, 1);
    });
  });

  group('restrictedMemberUids (fixtures)', () {
    test('returns only this community scoped uids', () async {
      SupaDb.testFixtures!['chat_restrictions'] = [
        {'firebase_uid': 'u-mem', 'community_id': 'comm-a'},
        {'firebase_uid': 'u-other', 'community_id': 'comm-b'},
        {'firebase_uid': 'u-global'},
      ];
      expect(await CommunityGroups.restrictedMemberUids('comm-a'),
          {'u-mem'});
      expect(await CommunityGroups.restrictedMemberUids('comm-b'),
          {'u-other'});
    });
  });

  group('clearCommunityChat (fixtures) — SCOPING', () {
    test('organizer of A clears only A history', () async {
      final res = await CommunityGroups.clearCommunityChat(
          communityId: 'comm-a',
          requesterUid: 'u-org-a',
          requesterName: 'Org A');
      expect(res['ok'], isTrue);
      expect(res['deleted'], 2);
      final msgs = SupaDb.testFixtures!['chat_messages']!;
      expect(msgs.length, 1);
      expect(msgs.first['id'], 'm3');
    });

    test('organizer of A CANNOT clear B history', () async {
      final res = await CommunityGroups.clearCommunityChat(
          communityId: 'comm-b',
          requesterUid: 'u-org-a',
          requesterName: 'Org A');
      expect(res['ok'], isFalse);
      expect(SupaDb.testFixtures!['chat_messages']!.length, 3);
    });

    test('organizer cannot clear before voice approval', () async {
      final res = await CommunityGroups.clearCommunityChat(
          communityId: 'comm-c',
          requesterUid: 'u-org-a',
          requesterName: 'Org A');
      expect(res['ok'], isFalse);
      expect(SupaDb.testFixtures!['chat_messages']!.length, 3);
    });
  });

  group('normCommunity voice_enabled', () {
    test('maps the flag to both key styles', () {
      final m = CommunityGroups.normCommunity({
        'id': 'c1',
        'name': 'X',
        'voice_enabled': true,
      });
      expect(m['voice_enabled'], isTrue);
      expect(m['voiceEnabled'], isTrue);
    });

    test('missing flag reads as false (fail-closed)', () {
      final m = CommunityGroups.normCommunity({'id': 'c1', 'name': 'X'});
      expect(m['voice_enabled'], isFalse);
      expect(m['voiceEnabled'], isFalse);
    });
  });

  group('LiveKit organizer packets (pure)', () {
    test('organizer packet with the right topic is honored', () {
      expect(
          LiveKitVoiceService.shouldHonorOrganizerPacket(
              senderIdentity: 'u-org-a',
              organizerUid: 'u-org-a',
              topic: LiveKitVoiceService.organizerControlTopic),
          isTrue);
    });

    test('a stranger packet is ignored', () {
      expect(
          LiveKitVoiceService.shouldHonorOrganizerPacket(
              senderIdentity: 'u-mem',
              organizerUid: 'u-org-a',
              topic: LiveKitVoiceService.organizerControlTopic),
          isFalse);
    });

    test('no organizer configured means ignore everything', () {
      expect(
          LiveKitVoiceService.shouldHonorOrganizerPacket(
              senderIdentity: 'u-org-a',
              organizerUid: '',
              topic: LiveKitVoiceService.organizerControlTopic),
          isFalse);
    });

    test('wrong topic is ignored', () {
      expect(
          LiveKitVoiceService.shouldHonorOrganizerPacket(
              senderIdentity: 'u-org-a',
              organizerUid: 'u-org-a',
              topic: 'something_else'),
          isFalse);
    });

    test('null sender is ignored', () {
      expect(
          LiveKitVoiceService.shouldHonorOrganizerPacket(
              senderIdentity: null,
              organizerUid: 'u-org-a',
              topic: LiveKitVoiceService.organizerControlTopic),
          isFalse);
    });

    test('mute and unmute kinds parse', () {
      expect(
          LiveKitVoiceService.organizerControlKindFromData(
              utf8.encode(jsonEncode({'kind': 'organizer_mute'}))),
          'organizer_mute');
      expect(
          LiveKitVoiceService.organizerControlKindFromData(
              utf8.encode(jsonEncode({'kind': 'organizer_unmute'}))),
          'organizer_unmute');
    });

    test('garbage and other kinds return null', () {
      expect(LiveKitVoiceService.organizerControlKindFromData([1, 2, 3]),
          isNull);
      expect(
          LiveKitVoiceService.organizerControlKindFromData(
              utf8.encode(jsonEncode({'kind': 'hello'}))),
          isNull);
      expect(
          LiveKitVoiceService.organizerControlKindFromData(
              utf8.encode(jsonEncode(['not', 'a', 'map']))),
          isNull);
    });
  });

  group('LiveKit organizer-mute lock', () {
    test('self-unmute is ignored while organizer-muted', () async {
      final svc = LiveKitVoiceService(roomId: 'r1', roomLabel: 'Room');
      svc.mutedByOrganizer = true;
      svc.muted = true;
      await svc.setMuted(false);
      expect(svc.muted, isTrue);
      svc.dispose();
    });

    test('self-unmute works when not organizer-muted', () async {
      final svc = LiveKitVoiceService(roomId: 'r1', roomLabel: 'Room');
      svc.muted = true;
      await svc.setMuted(false);
      expect(svc.muted, isFalse);
      svc.dispose();
    });

    test('disconnect releases the organizer-mute lock', () async {
      final svc = LiveKitVoiceService(roomId: 'r1', roomLabel: 'Room');
      svc.mutedByOrganizer = true;
      await svc.disconnect();
      expect(svc.mutedByOrganizer, isFalse);
      svc.dispose();
    });
  });

  group('shouldKickFromCommunityChat — kick rule', () {
    test('restricted + logged in + not admin is kicked', () {
      expect(
          shouldKickFromCommunityChat(
              loggedIn: true, isAdmin: false, isRestricted: true),
          isTrue);
    });

    test('admin is never kicked', () {
      expect(
          shouldKickFromCommunityChat(
              loggedIn: true, isAdmin: true, isRestricted: true),
          isFalse);
    });

    test('logged-out viewer is not kicked', () {
      expect(
          shouldKickFromCommunityChat(
              loggedIn: false, isAdmin: false, isRestricted: true),
          isFalse);
    });

    test('not restricted is not kicked', () {
      expect(
          shouldKickFromCommunityChat(
              loggedIn: true, isAdmin: false, isRestricted: false),
          isFalse);
    });
  });
}
