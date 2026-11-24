// v2016 FIX 8 (2026-11-22) — the "Online" count next to Live Chat
// must be accurate: live presence, updates on join/leave.
//
// The count rule is a pure helper on PresenceService
// (countOnlineUsers): union of in-room + online presence rows and
// live voice-peer uids from BOTH engines (mesh + LiveKit). A uid
// on both counts once. The old code was presence-OR-voice: as soon
// as any presence row was online, voice peers NOT in the presence
// map (room admin, spectators, a voice user whose presence
// heartbeat went stale) were invisible and the count under-read.
//
// These are REAL unit tests on the counting rule (join/leave
// sequences), not source pins — plus pins proving the Room screen
// actually uses the helper and the header shows it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/presence_service.dart';

String _read(String path) => File(path).readAsStringSync();

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

// A presence row: fresh (just heartbeated) or stale (5 min old).
Map<String, dynamic> _row({required String tournamentId, required bool fresh}) => {
      'current_tournament_id': tournamentId,
      'last_seen': fresh ? _nowMs() : _nowMs() - 5 * 60 * 1000,
    };

// Tournament-room rule, mirroring _presenceInRoom.
bool _inRoom(Map<String, dynamic> row) => row['current_tournament_id'] == 't1';

int _count({
  Map<String, Map<String, dynamic>> presence = const {},
  List<String> mesh = const [],
  List<String> liveKit = const [],
}) =>
    PresenceService.countOnlineUsers(
      presenceMap: presence,
      inRoom: _inRoom,
      meshPeerUids: mesh,
      liveKitUids: liveKit,
    );

void main() {
  group('Fix 8 — Online count rule', () {
    test('empty room counts 0', () {
      expect(_count(), 0);
    });

    test('presence join/leave moves the count', () {
      final presence = <String, Map<String, dynamic>>{};
      expect(_count(presence: presence), 0);
      // u1 joins (fresh, in this room).
      presence['u1'] = _row(tournamentId: 't1', fresh: true);
      expect(_count(presence: presence), 1);
      // u2 joins.
      presence['u2'] = _row(tournamentId: 't1', fresh: true);
      expect(_count(presence: presence), 2);
      // u1 leaves (row removed).
      presence.remove('u1');
      expect(_count(presence: presence), 1);
      // u2 leaves.
      presence.remove('u2');
      expect(_count(presence: presence), 0);
    });

    test('stale presence rows do not count; going stale drops the count',
        () {
      final presence = <String, Map<String, dynamic>>{
        'u1': _row(tournamentId: 't1', fresh: true),
        'u2': _row(tournamentId: 't1', fresh: false),
      };
      expect(_count(presence: presence), 1);
      // u1's heartbeat stops — the row goes stale.
      presence['u1'] = _row(tournamentId: 't1', fresh: false);
      expect(_count(presence: presence), 0);
    });

    test('online elsewhere is not online here', () {
      final presence = <String, Map<String, dynamic>>{
        'u1': _row(tournamentId: 't1', fresh: true),
        // u2 is fresh but in another tournament's room.
        'u2': _row(tournamentId: 't2', fresh: true),
      };
      expect(_count(presence: presence), 1);
      // u2 moves into this room.
      presence['u2'] = _row(tournamentId: 't1', fresh: true);
      expect(_count(presence: presence), 2);
    });

    test('voice peers outside the presence map count (union, not OR)', () {
      final presence = <String, Map<String, dynamic>>{
        'u1': _row(tournamentId: 't1', fresh: true),
      };
      // Admin on LiveKit voice, not a registered player: invisible
      // to the presence map, must still count.
      expect(_count(presence: presence, liveKit: ['admin']), 2);
      // A mesh voice peer, also unregistered.
      expect(_count(presence: presence, liveKit: ['admin'], mesh: ['guest']),
          3);
      // No presence at all: voice alone still counts.
      expect(_count(liveKit: ['admin'], mesh: ['guest']), 2);
    });

    test('a uid on voice AND in presence counts once', () {
      final presence = <String, Map<String, dynamic>>{
        'u1': _row(tournamentId: 't1', fresh: true),
      };
      expect(_count(presence: presence, mesh: ['u1']), 1);
      expect(_count(presence: presence, liveKit: ['u1']), 1);
      expect(_count(presence: presence, mesh: ['u1'], liveKit: ['u1']), 1);
    });

    test('voice leave drops the count', () {
      final presence = <String, Map<String, dynamic>>{
        'u1': _row(tournamentId: 't1', fresh: true),
      };
      expect(_count(presence: presence, liveKit: ['admin']), 2);
      // Admin leaves voice.
      expect(_count(presence: presence, liveKit: []), 1);
      // Mesh peer joins then leaves.
      expect(_count(presence: presence, mesh: ['guest']), 2);
      expect(_count(presence: presence, mesh: []), 1);
    });

    test('a voice user with stale presence still counts', () {
      // u1 is on mesh voice but their presence heartbeat went
      // stale (>2 min) — the old presence-OR-voice code missed
      // them whenever anyone else was online.
      final presence = <String, Map<String, dynamic>>{
        'u1': _row(tournamentId: 't1', fresh: false),
        'u2': _row(tournamentId: 't1', fresh: true),
      };
      expect(_count(presence: presence, mesh: ['u1']), 2);
    });

    test('realistic session: joins and leaves in sequence', () {
      final presence = <String, Map<String, dynamic>>{};
      final mesh = <String>[];
      final liveKit = <String>[];
      int count() => _count(presence: presence, mesh: mesh, liveKit: liveKit);

      expect(count(), 0);
      presence['u1'] = _row(tournamentId: 't1', fresh: true); // host enters
      expect(count(), 1);
      presence['u2'] = _row(tournamentId: 't1', fresh: true); // player enters
      expect(count(), 2);
      liveKit.add('admin'); // admin joins voice (not registered)
      expect(count(), 3);
      mesh.add('u2'); // u2 joins mesh voice — already counted
      expect(count(), 3);
      presence.remove('u1'); // host leaves
      expect(count(), 2);
      liveKit.remove('admin'); // admin leaves voice
      expect(count(), 1);
      presence.remove('u2'); // u2 leaves (voice row also gone)
      mesh.remove('u2');
      expect(count(), 0);
    });
  });

  group('Fix 8 — Room screen wiring (source pins)', () {
    late String roomSrc;
    setUpAll(() {
      roomSrc = _read('lib/screens/room_screen.dart');
    });

    test('_roomUserCount delegates to the union rule', () {
      final start = roomSrc.indexOf('int _roomUserCount()');
      expect(start, isNot(-1));
      final window = roomSrc.substring(start, start + 1500);
      expect(window, contains('PresenceService.countOnlineUsers'));
      expect(window, contains('meshPeerUids: _room.peers.keys'));
      expect(window, contains('liveKitUids: _lkRoom.participants.keys'));
      // No presence-OR-voice fallback left: the old
      // "if (online > 0) return online" must be gone.
      expect(window, isNot(contains('if (online > 0) return online')));
    });

    test('Live Chat header shows the count', () {
      expect(roomSrc, contains("Text('\${_roomUserCount()} online'"));
    });

    test('presence query includes the local uid', () {
      final start = roomSrc.indexOf('Future<void> _checkPresenceWelcomes()');
      expect(start, isNot(-1));
      final window = roomSrc.substring(start, start + 2000);
      expect(window,
          contains('final myUid = FirebaseAuth.instance.currentUser?.uid'));
      expect(window, contains('queryUids'));
      expect(window, contains('getPresenceMap(queryUids)'));
      // And the welcome loop skips self (no 'A player' row).
      expect(roomSrc, contains('if (e.key == myUid) continue;'));
    });
  });
}
