// FIX 1 COMPACT VOICE PANEL (user order 2026-11-22, voice call +
// screenshot ~/workspace/user/files/1000049936_62_asu3.jpg — TEST
// CO clan chat, embedded voice panel): the bottom controls row
// (Connecting pill + Music + Settings + Close) is GONE — Close
// removed outright, Music / Settings / Connecting moved UP INTO
// the host (Admin) card, into the empty black space above the
// green mic button. The moved controls are SMALL; only the green
// mic stays BIG (56px). The host card is a bit shorter (tighter
// padding + gaps) and the host avatar a bit smaller.
//
// FIX 16 SUPERSESSION (2026-11-23): the compact controls row
// (_buildHostCardControls + _hostCardIconBtn) is GONE — Music /
// RJ / Settings moved to the header Settings sheet (via the
// voice controller), only the Connecting pill stays in the host
// card, next to the mic. The pins below assert the NEW structure.
//
// Source pins (what the code says). The room page cannot be
// widget-booted here (build() dereferences FirebaseAuth), and
// the v2017 widget tests already cover the TeamChatPage mount —
// so, like the rest of the room-screen mount tests, these pins
// assert the code itself. Phone-only: the rendered look (the
// panel really is more compact on a 360dp phone).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String rel) => File('test/../$rel').readAsStringSync();

/// Source with full-line comments stripped, so a mention inside a
/// comment (e.g. "Close removed outright") never counts as code.
String _codeOnly(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

/// The slice of [src] between two markers (exclusive of the end
/// marker), for scoped assertions.
String _region(String src, String start, String end) {
  final s = src.indexOf(start);
  expect(s, isNot(-1), reason: 'region start not found: $start');
  final e = src.indexOf(end, s + start.length);
  expect(e, isNot(-1), reason: 'region end not found: $end');
  return src.substring(s, e);
}

void main() {
  late String room;
  late String code;
  late String features;
  late String sheet;

  setUpAll(() {
    room = _read('lib/screens/room_screen.dart');
    code = _codeOnly(room);
    features = _read('lib/screens/pro_features.dart');
    sheet = _read('lib/widgets/voice_settings_sheet.dart');
  });

  group('FIX 1 — Close button gone, bottom row gone', () {
    test('the bottom controls row method is deleted', () {
      expect(code.contains('_buildEmbeddedControls'), isFalse,
          reason: 'the old bottom controls row must be gone');
      expect(code.contains('_embeddedControlBtn'), isFalse,
          reason: 'the old 40px bottom-row button helper must be gone');
    });

    test('no Close button anywhere in the embedded panel', () {
      final embedded = _region(
        code,
        'Widget _buildEmbeddedVoice(',
        '@override\n  Widget build(BuildContext context)',
      );
      expect(embedded.contains('Icons.close'), isFalse,
          reason: 'no Close (X) button may remain in the panel');
      expect(embedded.contains("'Close'"), isFalse);
    });

    test('the embedded panel no longer calls the bottom row', () {
      final embedded = _region(
        code,
        'Widget _buildEmbeddedVoice(',
        '@override\n  Widget build(BuildContext context)',
      );
      expect(embedded.contains('_buildEmbeddedControls'), isFalse,
          reason: 'the embedded panel must not call the deleted row');
    });
  });

  group('FIX 1 — close path survives via the header Voice toggle', () {
    test('UnifiedRoomPage still declares onCloseVoice', () {
      expect(code.contains('final VoidCallback? onCloseVoice;'), isTrue);
    });

    test('TeamChatPage still toggles + closes the panel', () {
      final featCode = _codeOnly(features);
      expect(featCode.contains('void _toggleVoice()'), isTrue);
      expect(featCode.contains('onCloseVoice:'), isTrue);
      expect(
          featCode.contains('onVoice: _isTournament ? null : _toggleVoice'),
          isTrue,
          reason: 'header Voice button must still toggle the panel');
      expect(
          featCode.contains(
              'if (_voicePanelOpen && !_isTournament) _buildVoicePanel()'),
          isTrue);
    });
  });

  group('FIX 1 — controls moved INTO the host card', () {
    test('pill stays in the card; Music + Settings + RJ moved to the sheet', () {
      // FIX 16: the compact controls row is gone — the pill alone
      // stays in the host card (see _buildConnectingPill), and
      // Music / Settings / RJ moved to the header Settings sheet
      // via the voice controller (the room binds the real
      // callbacks in _bindVoiceController).
      final pill = _region(
        code,
        'Widget _buildConnectingPill()',
        'List<Widget> _buildRequestBanners()',
      );
      expect(pill.contains("'Voice On'"), isTrue);
      expect(pill.contains("'Connecting…'"), isTrue);
      expect(code.contains('onMusic: () => unawaited('), isTrue);
      expect(code.contains("_showRjVoiceConsole(initialSection: 'player')"),
          isTrue);
      expect(code.contains('onRoomSettings: _showRoomSettings'), isTrue);
      expect(code.contains('onRjConsole: _showRjVoiceConsole'), isTrue);
      // RJ still host-gated — the gate moved into the binding.
      // FIX 20 (fix 7b): the host is admin / team captain /
      // community organizer (same parity as music broadcast).
      expect(
          code.contains(
              'rjVisible: () =>\n          _isAdminForBroadcast ||\n          _isTeamCaptainForBroadcast ||\n          _isCommunityOrganizerForBroadcast,'),
          isTrue);
    });

    test('the host strip mounts the pill in row 2 (status strip), mic in row 1 (FIX 23 item 2)', () {
      final strip = _region(
        code,
        'Widget _buildHostStrip(',
        'Widget _buildHostLiveColumn(',
      );
      // FIX 23 item 2 SUPERSEDES FIX 16's one-row compact card:
      // the compact card is TWO rows now — row 1: avatar + name
      // + mic; row 2: the status strip (Live pill, Connecting
      // pill, listeners, Connected). The full page stays one row.
      // The pill + mic are both still in the card, and the old
      // controls row stays gone.
      expect(strip.contains('_buildHostMicButton('), isTrue);
      expect(strip.contains('_buildHostStatusStrip('), isTrue);
      expect(strip.contains('_buildHostCardControls()'), isFalse);
      final statusStrip = _region(
        code,
        'Widget _buildHostStatusStrip(',
        'Widget _buildHostLiveColumn(',
      );
      expect(statusStrip.contains('_buildConnectingPill()'), isTrue);
      expect(strip.contains('crossAxisAlignment: CrossAxisAlignment.end'),
          isFalse);
    });

    test('embedded voice mounts the compact host card', () {
      expect(
          code.contains(
              '_buildHostStrip(uid, peers, compactControls: true)'),
          isTrue);
    });

    test('full room page keeps the current host card', () {
      expect(code.contains('          _buildHostStrip(uid, peers),'), isTrue,
          reason: 'the full page must NOT get the compact card');
    });
  });

  group('FIX 1 — sizes: small controls, BIG mic, shorter card', () {
    test('green mic button size UNCHANGED (56px, icon 24)', () {
      final mic = _region(
        code,
        'Widget _buildHostMicButton(',
        'Widget _buildConnectingPill()',
      );
      expect(mic.contains('width: 56,'), isTrue);
      expect(mic.contains('height: 56,'), isTrue);
      // FIX 22 item 18a: the mic button now shows STATE, not the
      // action — mic icon + green when ON, mic_off + grey when
      // OFF, with an ON/OFF label below (the old Mute/Unmute
      // action label is gone).
      expect(mic.contains('micOn ? Icons.mic : Icons.mic_off'), isTrue);
      expect(mic.contains("micOn ? 'ON' : 'OFF'"), isTrue);
      expect(mic.contains('0xFF16D879'), isTrue);
      expect(mic.contains('0xFF5A6076'), isTrue);
      expect(mic.contains('size: 24'), isTrue);
    });

    test('voice functions survive in the header Settings sheet', () {
      // FIX 16: the small host-card icon buttons are gone — their
      // functions live in the header Settings sheet (Music /
      // Settings / RJ / Close voice), reached through the voice
      // controller the room binds in _bindVoiceController.
      expect(code.contains('void _bindVoiceController()'), isTrue);
      expect(code.contains('widget.voiceController?.bind('), isTrue);
      expect(code.contains('onCloseVoice: widget.onCloseVoice'), isTrue);
    });

    test('moved Connecting pill is SMALL (9px text, tight padding)', () {
      final controls = _region(
        code,
        'Widget _buildConnectingPill()',
        'List<Widget> _buildRequestBanners()',
      );
      // FIX 31b: the 9px text wears the AI Studio body token now
      // (Inter 9, w800) — same size, same tight padding.
      expect(controls.contains('ArenaTypography.body(9'), isTrue);
      expect(
          controls.contains(
              'padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3)'),
          isTrue);
      // The old pill was 12px text with 10/6 padding — gone.
      expect(controls.contains('fontSize: 12'), isFalse);
    });

    test('host card is SHORTER (tighter padding; single name row)', () {
      final strip = _region(
        code,
        'Widget _buildHostStrip(',
        'Widget _buildHostLiveColumn(',
      );
      // Card padding: vertical 14 -> 8 in compact mode
      // (Fix 1: 10; Fix 16 tightened it to 8).
      expect(
          strip.contains(
              'vertical: compactControls ? 8 : 14'),
          isTrue);
      // FIX 12 G7 (2026-11-23 §7): the pill/subtitle/tagline and
      // their inter-label gaps are GONE — the text column is a
      // single organizer-name row, so the old gap pins must NOT
      // remain. (FIX 16 had tightened the first gap to ? 2 : 4;
      // G7 removes both gaps entirely.)
      expect(strip.contains('compactControls ? 2 : 4'), isFalse);
      expect(strip.contains('compactControls ? 2 : 3'), isFalse);
      expect(strip.contains('Text(hostName'), isTrue);
    });

    test('host avatar is SMALLER (radius 30 -> 26)', () {
      expect(
          code.contains(
              '_avatar(hostName, hostUnmuted, hostUid, compactControls ? 26 : 30)'),
          isTrue);
    });

    test('Room Owner subtitle is GONE (FIX 12 G7 supersedes)', () {
      // FIX 12 G7 (user order 2026-11-23 §7): the 'Room Owner' /
      // 'Tournament Creator' subtitle row is REMOVED from the
      // top box — the organizer's name is the only label there.
      // This test used to pin the row's overflow handling; it now
      // pins the removal (see fix12_g7_organizer_name_test.dart).
      expect(
          code.contains(
              "Flexible(child: Text(hostIsAdminOwner ? 'Room Owner' : 'Tournament Creator'"),
          isFalse);
      expect(code.contains("'Room Owner'"), isFalse);
      expect(code.contains("'Tournament Creator'"), isFalse);
      // The name row keeps the overflow-safe shape (Flexible +
      // ellipsis) the old subtitle row had.
      expect(code.contains('maxLines: 1, overflow: TextOverflow.ellipsis'),
          isTrue);
    });

    test('no new colours in the compact controls', () {
      final pill = _region(
        code,
        'Widget _buildConnectingPill()',
        'List<Widget> _buildRequestBanners()',
      );
      final sheetCode = _codeOnly(sheet);
      // Gold royalGold + the existing green/red accents only —
      // no new hex colour literals in the pill or the settings
      // sheet. FIX 31b: the pill's gold is the AI Studio token
      // (ArenaColors.royalGold); the sheet still uses kGold.
      expect(pill.contains('Color(0xFF'), isFalse);
      expect(sheetCode.contains('Color(0xFF'), isFalse);
      expect(pill.contains('ArenaColors.royalGold'), isTrue);
      expect(sheetCode.contains('kGold'), isTrue);
    });
  });
}
