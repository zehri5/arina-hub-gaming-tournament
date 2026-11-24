// FIX 22 item 23 — the sticky "chat history deleted" marker.
// The room clear no longer inserts a CHAT_CLEARED marker (the
// toast IS the one-time notification), old markers get deleted
// too, and the community + team lists filter legacy markers at
// every ingestion point so they never display again.

import 'package:flutter_test/flutter_test.dart';

import 'audio_test_helpers.dart';

String _region(String src, String start, String end) {
  final s = src.indexOf(start);
  if (s < 0) return '';
  final e = src.indexOf(end, s + start.length);
  if (e < 0) return '';
  return src.substring(s, e);
}

void main() {
  group('fix22 item 23 — room clear inserts no marker', () {
    late String clear;

    setUpAll(() {
      final room =
          codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
      clear = _region(
        room,
        'Future<void> _clearChat() async {',
        'void _handleChatEmptied(',
      );
    });

    test('clear region exists', () {
      expect(clear, isNotEmpty);
    });

    test('no marker row is sent on clear', () {
      expect(clear, isNot(contains('_chatClearedPrefix')));
      expect(clear, isNot(contains('CHAT_CLEARED')));
      expect(clear, isNot(contains('sendChat(')));
    });

    test('the toast still confirms the clear once', () {
      expect(clear, contains("toast(context, 'Chat clear kar di hai"));
    });
  });

  group('fix22 item 23 — legacy markers never display', () {
    test('community list filters CHAT_CLEARED at its single ingestion point (FIX 23 item 7)',
        () {
      final community = codeOnly(
          requireProjectFile('lib/screens/communities_screens.dart'));
      // FIX 23 item 7 (live-only chat) SUPERSEDES the 3-point
      // filter: history is never loaded on entry, so _mergeLive
      // is now the ONLY ingestion point — and it still filters
      // legacy markers (plus the live-entry filter).
      expect('_isChatClearedRow(m)'.allMatches(community).length, 1);
      expect(community, contains('_mergeLive'));
      expect(community, contains('_isLiveMessage'));
      expect(community,
          contains("const _chatClearedPrefix = 'CHAT_CLEARED::';"));
    });

    test('team chat filters CHAT_CLEARED rows too', () {
      final team =
          codeOnly(requireProjectFile('lib/screens/pro_features.dart'));
      expect(team, contains("startsWith('CHAT_CLEARED::')"));
    });
  });

  group('fix22 item 23 — empty-trigger replaces the marker trigger',
      () {
    test('_handleChatEmptied exists, _handleChatClearedRows is gone',
        () {
      final room =
          codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
      expect(room, contains('void _handleChatEmptied('));
      expect(room, isNot(contains('_handleChatClearedRows')));
      expect(room, contains('_hadChatMessages'));
    });
  });
}
