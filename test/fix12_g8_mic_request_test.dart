// FIX 12 G8 — COMMUNITY MIC-REQUEST FLOW (2026-11-23, user
// clarification 01:08 — supersedes MD §8): community mic rules =
// the FULL 6-mic system WITH the mic-request flow, exactly as the
// old clan had it. Any member can request a mic; the request goes
// to the ORGANIZER (community creator); the organizer
// approves/rejects. Users are NOT listen-only.
//
// Covered (non-vacuous — every assert pins a live wiring line or
// a pure helper the live code calls):
//   1. Request target: a non-organizer's request from the
//      community room goes to the organizer in room
//      community_<id> (communityRoomAdminUid + _voiceRoomId +
//      _sendMicRequest's voiceInboxSend target).
//   2. Organizer sees approve/reject: _loadRoomAdmin resolves
//      _adminUid to the organizer in community scope, so
//      _isRoomAdmin is true for the organizer only — the
//      mic_request inbox handler and the approve/reject banner
//      are both gated on it.
//   3. Approval assigns a seat: the organizer's approval sends
//      mic_approved with a mic_slot:N payload (micSlotPayload /
//      parseApprovedMicSlot round-trip), the requester's join
//      carries the assigned seat, and slot picking runs over
//      exactly 6 seats (firstFreeMicSlot + _communityMicCount).
//   4. Rejection clears the request: reject sends mic_rejected
//      and drops the row from the organizer's pending list; the
//      requester's mic_rejected handler clears the pending flag.
//
// Pattern: pure-helper tests (the helpers live top-level in
// room_screen.dart precisely so they are testable without booting
// the room — same pattern as rj_voice_mount_test.dart) plus
// source-invariant tests (same pattern as
// v2016_fix11_relocation_test.dart): no network, no
// Supabase/Firebase init. A two-phone live run is still the only
// proof the inbox rows actually arrive — see the report.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/room_screen.dart';
import 'package:protournament_user/services/squad.dart';

String _read(String path) => File(path).readAsStringSync();

// Code only: full-line // comments are stripped because the
// removal/FIX notes mention old entries by name — the assertions
// must check code, not prose.
String _code(String src) {
  return src
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');
}

void main() {
  group('G8 — community room identity (mic-request routing)', () {
    test('community room id is community_<id>', () {
      expect(communityRoomId('c42'), 'community_c42');
      expect(communityRoomId('c42'), isNot(startsWith('squad_')));
      expect(communityRoomId('c42'), isNot(startsWith('tournament_')));
    });

    test('room page routes community scope via communityRoomId', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      expect(room,
          contains("_isCommunity ? communityRoomId(widget.communityId)"));
      expect(room, contains("bool get _isCommunity => widget.scope == 'community';"));
    });

    test('room page takes community identity params', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      expect(room, contains('final String communityId;'));
      expect(room, contains('final String communityName;'));
      expect(room, contains('final String organizerUid;'));
      expect(room, contains("this.organizerUid = '',"));
      expect(room,
          contains("final String scope; // 'tournament' | 'squad' | 'team' | 'community'"));
    });

    test('community room loads the COMMUNITIES row, creator = created_by_uid', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      expect(
          room,
          contains(
              "_isCommunity ? SupaDb.getRow('communities', 'id', widget.communityId)"));
      expect(
          room,
          contains(
              "_isCommunity ? SupaDb.strOf(t['created_by_uid'], widget.organizerUid)"));
    });
  });

  group('G8 — request target: the organizer, not the app admin', () {
    test('organizer wins when known', () {
      expect(
        communityRoomAdminUid(organizerUid: 'org-uid', appAdminUid: 'app-uid'),
        'org-uid',
      );
    });

    test('falls back to the app admin when the organizer is unknown', () {
      expect(
        communityRoomAdminUid(organizerUid: '', appAdminUid: 'app-uid'),
        'app-uid',
      );
    });

    test('empty organizer + empty admin stays empty (fail-closed send)', () {
      expect(
        communityRoomAdminUid(organizerUid: '', appAdminUid: ''),
        '',
      );
    });

    test('_loadRoomAdmin overrides _adminUid with the organizer in community scope', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      expect(
        room,
        contains(
            '_adminUid = communityRoomAdminUid(organizerUid: widget.organizerUid, appAdminUid: _adminUid);'),
        reason:
            'the override must run inside _loadRoomAdmin, before _isRoomAdmin is computed',
      );
      // The override must be scoped to community rooms — the clan /
      // tournament flow keeps the designated app admin.
      final idx = room.indexOf(
          '_adminUid = communityRoomAdminUid(organizerUid: widget.organizerUid');
      expect(idx, isPositive);
      expect(room.substring(0, idx), contains('if (_isCommunity) {'));
    });

    test('_isRoomAdmin is true exactly for the resolved _adminUid', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      expect(
          room,
          contains(
              '_isRoomAdmin = uid.isNotEmpty && _adminUid.isNotEmpty && uid == _adminUid;'));
    });

    test('a non-organizer sends mic_request to _adminUid in the community room', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      expect(
        room,
        contains(
            "await SupaDb.voiceInboxSend(_voiceRoomId, _adminUid, uid, {'kind': 'mic_request'});"),
        reason:
            '_sendMicRequest targets _adminUid (the organizer in community scope) in _voiceRoomId (community_<id>)',
      );
      // The Take-Mic tap sends the request when no live approval
      // exists — no entry point can bypass the request gate.
      expect(room, contains('await _sendMicRequest();'));
    });

    test('cancel sends mic_request_cancel to the same target', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      expect(
        room,
        contains(
            "await SupaDb.voiceInboxSend(_voiceRoomId, _adminUid, uid, {'kind': 'mic_request_cancel'});"),
      );
    });
  });

  group('G8 — organizer sees approve/reject', () {
    test('mic_request is only handled by the room admin (the organizer)', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      final idx = room.indexOf("case 'mic_request':");
      expect(idx, isPositive);
      final handler = room.substring(idx, idx + 600);
      expect(handler, contains('if (!_isRoomAdmin) return false;'),
          reason: 'a non-organizer phone must drop the request, never list it');
      expect(handler, contains("_micRequests.add({'uid': fromUid, 'name': name})"));
    });

    test('mic_request_cancel is only handled by the room admin', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      final idx = room.indexOf("case 'mic_request_cancel':");
      expect(idx, isPositive);
      final handler = room.substring(idx, idx + 400);
      expect(handler, contains('if (!_isRoomAdmin) return false;'));
      expect(handler,
          contains("_micRequests.removeWhere((r) => r['uid'] == fromUid)"));
    });

    test('approve/reject banner shows only for the admin with pending requests', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      expect(room, contains('if (_isRoomAdmin && _micRequests.isNotEmpty)'));
      expect(room, contains("child: const Text('Approve'"));
      expect(room, contains("child: const Text('Reject'"));
    });

    test('mic-request sheet is admin-only and offers Approve + Reject per request', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      final idx = room.indexOf('void _showMicRequestsSheet()');
      expect(idx, isPositive);
      final sheet = room.substring(idx, idx + 2200);
      expect(sheet, contains('if (!_isRoomAdmin) return;'));
      expect(sheet, contains('_approveWithSlot('));
      expect(sheet, contains('_rejectMicRequest('));
    });

    test('toasts name the ORGANIZER in community scope', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      expect(room,
          contains("String get _approverWordCap => _isCommunity ? 'Organizer' : 'Admin';"));
      expect(room, contains(r"'$_approverWordCap ka pata nahi chal raha"));
      expect(room, contains(r"'Mic request $_approverWord ko bhej di hai"));
    });
  });

  group('G8 — approval assigns a seat', () {
    test('mic_slot payload round-trips for every community seat 1..6', () {
      for (var slot = 1; slot <= 6; slot++) {
        expect(micSlotPayload(slot), 'mic_slot:$slot');
        expect(parseApprovedMicSlot(micSlotPayload(slot)), slot);
      }
    });

    test('parseApprovedMicSlot: no slot or malformed payload is null, never a crash', () {
      expect(parseApprovedMicSlot(''), isNull);
      expect(parseApprovedMicSlot('mic_slot:'), isNull);
      expect(parseApprovedMicSlot('hello'), isNull);
      expect(parseApprovedMicSlot('mic_slot:abc'), isNull);
    });

    test('firstFreeMicSlot: empty room -> seat 1', () {
      expect(firstFreeMicSlot(<int>{}, 6), 1);
    });

    test('firstFreeMicSlot: skips taken seats', () {
      expect(firstFreeMicSlot({1, 2, 3}, 6), 4);
      expect(firstFreeMicSlot({2, 3, 4, 5, 6}, 6), 1);
    });

    test('firstFreeMicSlot: full room -> null', () {
      expect(firstFreeMicSlot({1, 2, 3, 4, 5, 6}, 6), isNull);
    });

    test('firstFreeMicSlot: out-of-range taken values do not block assignment', () {
      expect(firstFreeMicSlot({9, 99}, 6), 1);
    });

    test('community rooms have exactly 6 mic seats (never the tournament 9)', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      expect(room,
          contains('int get _communityMicCount => widget.micCount > 0 ? widget.micCount : 6;'));
      expect(room,
          contains('_isCommunity ? _communityMicCount : _isSquad ? _squadCapacity'));
      // Both seat grids render the community count, not 9.
      expect(
          room,
          contains(
              'final usable = _isTeam ? _teamMicCount : _isCommunity ? _communityMicCount : _isSquad ? _squadCapacity'));
      expect(
          room,
          contains(
              'final total = _isTeam ? _teamMicCount : _isCommunity ? _communityMicCount : 9;'));
    });

    test('approve-with-slot picks the first free seat via the helper', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      final idx = room.indexOf('Future<void> _approveWithSlot(');
      expect(idx, isPositive);
      final fn = room.substring(idx, idx + 900);
      expect(fn, contains('final firstFree = firstFreeMicSlot(taken, usable);'));
      expect(fn, contains('if (firstFree == null) {'));
      expect(fn, contains('await _approveMicRequest(targetUid, name, slot);'));
    });

    test('approval sends mic_approved with the slot payload and clears the pending row', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      final idx = room.indexOf('Future<void> _approveMicRequest(');
      expect(idx, isPositive);
      final fn = room.substring(idx, idx + 1800);
      expect(
          fn,
          contains(
              "await _sendAdminControl(targetUid, 'mic_approved', sdp: micSlotPayload(slot));"));
      expect(fn,
          contains("_micRequests.removeWhere((r) => r['uid'] == targetUid)"));
      // Community rooms have no room_mutes rows — approval must not
      // touch the tournament-keyed table with an empty tournament id.
      expect(fn, contains('if (!_isTeam && !_isCommunity) {'));
    });

    test('approval receipt parses the slot and the join carries it as the assigned seat', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      final idx = room.indexOf("case 'mic_approved':");
      expect(idx, isPositive);
      final handler = room.substring(idx, idx + 1600);
      expect(handler, contains('_micApprovedSlot = parseApprovedMicSlot(sdp);'));
      expect(handler, contains('_micRequestPending = false;'));
      expect(handler, contains("if (_adminUid.isEmpty || fromUid != _adminUid) return false;"),
          reason: 'only an approval FROM the organizer counts');
      expect(room, contains('_room.assignedSeat = _micApprovedSlot;'));
    });
  });

  group('G8 — rejection clears the request', () {
    test('reject sends mic_rejected and drops the row from the pending list', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      final idx = room.indexOf('Future<void> _rejectMicRequest(');
      expect(idx, isPositive);
      final fn = room.substring(idx, idx + 700);
      expect(fn, contains("await _sendAdminControl(targetUid, 'mic_rejected');"));
      expect(fn,
          contains("_micRequests.removeWhere((r) => r['uid'] == targetUid)"));
    });

    test('rejection receipt clears the requester pending flag and any approval', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      final idx = room.indexOf("case 'mic_rejected':");
      expect(idx, isPositive);
      final handler = room.substring(idx, idx + 800);
      expect(handler, contains('_micApprovedUntil = null;'));
      expect(handler, contains('_micApprovedSlot = null;'));
      expect(handler, contains('_micRequestPending = false;'));
      expect(handler, contains("if (_adminUid.isEmpty || fromUid != _adminUid) return false;"),
          reason: 'only a rejection FROM the organizer counts');
    });
  });

  group('G8 — no scope bleed', () {
    test('team rooms never use the community_ prefix', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      expect(room, isNot(contains('communityRoomId(widget.teamId)')));
    });

    test('organizer fallback in the host strip uses the organizer, not the app admin', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      expect(
        room,
        contains(
            "_isCommunity ? (_creatorUid.isNotEmpty ? _creatorUid : widget.organizerUid)"),
      );
    });

    test('no new gold shade: the room still only uses #FDC903 gold', () {
      final room = _read('lib/screens/room_screen.dart');
      // The file's gold is 0xFFFDC903; the banned old shades must not
      // reappear anywhere in the file.
      expect(room, isNot(contains('0xFFFFE20A')));
      expect(room, isNot(contains('0xFFFFCC00')));
    });
  });
}
