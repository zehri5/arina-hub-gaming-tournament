// FIX 22 items 14 + 16 + 19 — host card pins.
// Host pill + name + avatar + real tagline; members button
// (total + online, opens the FULL list); mic ON/OFF state;
// LIVE gated by hostOnVoice; Connected/Disconnected box;
// blue tick INLINE beside the name (flag OR followers >= 1000).

import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/room_screen.dart';

import 'audio_test_helpers.dart';

String _region(String src, String start, String end) {
  final s = src.indexOf(start);
  if (s < 0) return '';
  final e = src.indexOf(end, s + start.length);
  if (e < 0) return '';
  return src.substring(s, e);
}

void main() {
  group('fix22 items 14 + 16 — host card structure', () {
    late String room;
    late String strip;

    setUpAll(() {
      room = codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
      strip = _region(
        room,
        'Widget _buildHostStrip(',
        'Widget _buildHostLiveColumn(',
      );
    });

    test('host strip region exists', () {
      expect(strip, isNotEmpty);
    });

    test('no "Room Owner" anywhere in the host card', () {
      expect(strip, isNot(contains('Room Owner')));
    });

    test('Host pill + name + avatar present', () {
      expect(strip, contains("'Host'"));
      expect(strip, contains('_avatar(hostName, hostUnmuted, hostUid,'));
    });

    test('no "N live" in the scope line (item 16 supersedes 14e)', () {
      expect(strip, isNot(contains('liveKnown')));
      expect(strip, isNot(contains('liveCount')));
    });

    test('FIX 23 item 12b: NO members button / "members" text in the card',
        () {
      // FIX 22 item 16's members button is REMOVED (user order
      // 2026-11-23): the word "Members" appears nowhere in the
      // room; followers live in the sidebar (item 9/12).
      expect(strip, isNot(contains('onHostCardMembersPressed')));
      expect(strip, isNot(contains('hostCardTotalMembers')));
      expect(strip, isNot(contains('hostCardOnlineMembers')));
      expect(strip, isNot(contains(' members')));
      expect(strip, isNot(contains('Members')));
    });

    test('mic shows STATE: green mic + ON vs grey mic_off + OFF', () {
      final mic = _region(
        room,
        'Widget _buildHostMicButton(',
        'Widget _buildConnectingPill()',
      );
      expect(mic, isNotEmpty);
      expect(mic, contains('0xFF16D879'));
      expect(mic, contains('0xFF5A6076'));
      expect(mic, contains('micOn ? Icons.mic : Icons.mic_off'));
      expect(mic, contains("micOn ? 'ON' : 'OFF'"));
    });

    test('LIVE pill gated by hostOnVoice + listeners count', () {
      final live = _region(
        room,
        'Widget _buildHostLiveColumn(',
        'Widget _buildEmbeddedSidebar() {',
      );
      expect(live, isNotEmpty);
      expect(live, contains('if (hostOnVoice)'));
      // FIX 23 item 12c: the pill + listeners row are extracted
      // builders (called from the live column AND the compact
      // status strip); the count lives in _buildListenersRow.
      expect(live, contains('_buildLivePill()'));
      expect(live, contains('_buildListenersRow()'));
      final listeners = _region(
        room,
        'Widget _buildListenersRow()',
        'Widget _buildConnectedBox()',
      );
      expect(listeners, contains('_liveListeners.listenerCount'));
      expect(listeners, contains('Icons.headset'));
    });

    test('Connected/Disconnected box uses _voiceConnected', () {
      expect(room, contains("connected ? 'Connected' : 'Disconnected'"));
    });
  });

  group('fix22 item 19 — blue tick rule', () {
    test('flag true -> tick', () {
      expect(hostVerifiedTick(flag: true), isTrue);
      expect(hostVerifiedTick(flag: true, followersCount: 0), isTrue);
    });

    test('1000 followers -> tick, 999 -> no tick', () {
      expect(hostVerifiedTick(flag: false, followersCount: 1000), isTrue);
      expect(hostVerifiedTick(flag: false, followersCount: 1500), isTrue);
      expect(hostVerifiedTick(flag: false, followersCount: 999), isFalse);
      expect(hostVerifiedTick(flag: false, followersCount: 0), isFalse);
    });

    test('unknown count -> no tick', () {
      expect(hostVerifiedTick(flag: false), isFalse);
      expect(hostVerifiedTick(flag: false, followersCount: null), isFalse);
    });

    test('profileVerifiedFlag reads both spellings, absent = false', () {
      expect(profileVerifiedFlag({'verified': true}), isTrue);
      expect(profileVerifiedFlag({'is_verified': true}), isTrue);
      expect(profileVerifiedFlag({'verified': false}), isFalse);
      expect(profileVerifiedFlag({}), isFalse);
      expect(profileVerifiedFlag({'name': 'x'}), isFalse);
    });

    test('tick renders INLINE in the name Row (not below the name)',
        () {
      final room =
          codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
      final strip = _region(
        room,
        'Widget _buildHostStrip(',
        'Widget _buildHostLiveColumn(',
      );
      // The verified icon sits in the same Row as the host name,
      // 4px after it — Facebook style.
      expect(strip, contains('Icon(Icons.verified'));
      final iconAt = strip.indexOf('Icon(Icons.verified');
      expect(iconAt, isNot(-1));
      expect(strip.substring(0, iconAt), contains('Row('));
    });
  });
}
