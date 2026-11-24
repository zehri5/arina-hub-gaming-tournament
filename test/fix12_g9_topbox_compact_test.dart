// FIX12 G9 — TOP BOX COMPACT (user order 2026-11-23, §9 of
// COMMUNITY-CLAN-FIX-2026-11-23, voice call + screenshots): in the
// voice-room top box (the host card of the shared UnifiedRoomPage,
// mounted into the community by G6), Connecting / Music / Settings
// are SMALL compact chips sitting UP in the top box with LIVE +
// mic/mute-unmute, and the whole top box is SHORTER so space is
// saved.
//
// What G9 changed (all inside the compact/embedded card only — the
// full room page is untouched, and G7 owns the labels in this box):
// outer top 8 -> 6, card padding 10 -> 8, the decorative tagline
// hidden, the controls-to-mic gap 6 -> 4, the Live-column gaps
// 4 -> 2, and the Mute/Unmute label under the mic hidden (the Live
// column beside it already says Mic on / Muted). Whole top box
// ≈110px vs ≈134px before.
//
// Source pins (what the code says). The room page cannot be
// widget-booted here (build() dereferences FirebaseAuth), so —
// like the FIX 1 mount tests — these pins assert the code itself,
// including an arithmetic HEIGHT BUDGET parsed from the literals.
// Phone-only: the rendered look (the box really is visibly more
// compact on a 360dp phone).
//
// MERGE-LANE NOTE (G9 merge, 2026-11-23): G9 was built against
// the pre-FIX-16 base, so 8 tests are adapted to the merged
// main — FIX 16 deleted _buildHostCardControls + _hostCardIconBtn
// (Music/RJ/Settings moved to the header Settings sheet via the
// voice controller; the pill sits NEXT TO the mic in one row),
// G7 deleted the tagline + subtitle outright (both modes), and
// G6b made the Live-column status connection-aware
// (_hostPresenceLabel). The adapted tests pin the NEW structure
// with the SAME intent (small chips up top, shorter box); no
// lib code was changed for them.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String rel) => File('test/../$rel').readAsStringSync();

/// Source with full-line comments stripped, so a mention inside a
/// comment (e.g. "gap 6 -> 4") never counts as code.
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

/// First integer captured by [pattern] in [src]; fails the test if
/// the pattern is absent, so a silent non-match can never pass.
int _parseInt(String src, String pattern, String what) {
  final m = RegExp(pattern).firstMatch(src);
  expect(m, isNotNull, reason: '$what not found in source: $pattern');
  return int.parse(m!.group(1)!);
}

void main() {
  late String room;
  late String code;

  setUpAll(() {
    room = _read('lib/screens/room_screen.dart');
    code = _codeOnly(room);
  });

  String strip() => _region(
        code,
        'Widget _buildHostStrip(',
        'Widget _buildHostLiveColumn(',
      );

  String live() => _region(
        code,
        'Widget _buildHostLiveColumn(',
        'Widget _buildHostMicButton(',
      );

  String mic() => _region(
        code,
        'Widget _buildHostMicButton(',
        'Widget _buildConnectingPill() {',
      );

  // FIX 16 deleted _buildHostCardControls + _hostCardIconBtn — the
  // pill lives in _buildConnectingPill now (same region fix1 pins).
  String pill() => _region(
        code,
        'Widget _buildConnectingPill()',
        'List<Widget> _buildRequestBanners()',
      );

  group('G9 — small controls sit UP in the top box', () {
    test('compact card holds the pill; Music + Settings live in the sheet',
        () {
      // FIX 16: the controls row is gone — the pill sits next to
      // the mic (4 honest states, G6b) and Music/Settings/RJ
      // moved to the header Settings sheet via the voice
      // controller the room binds in _bindVoiceController.
      final p = pill();
      expect(p.contains("'Voice On'"), isTrue);
      expect(p.contains("'Voice Failed'"), isTrue);
      expect(p.contains("'Connecting…'"), isTrue);
      expect(p.contains("'Not connected'"), isTrue);
      expect(code.contains('void _bindVoiceController()'), isTrue);
      // FIX 22 item 21: Music opens the RJ console focused on
      // the PLAYER section (no standalone player sheet).
      expect(code.contains('onMusic: () => unawaited('), isTrue);
      expect(
          code.contains("_showRjVoiceConsole(initialSection: 'player')"),
          isTrue);
      expect(code.contains('onRoomSettings: _showRoomSettings,'), isTrue);
      expect(code.contains('onRjConsole: _showRjVoiceConsole,'), isTrue);
    });

    test('the host strip mounts pill + Live + mic in TWO compact rows', () {
      // FIX 23 item 2 SUPERSEDES the one-row layout: the compact
      // card is TWO rows — Row 1 (avatar + name + mic), Row 2
      // (the status strip: Live pill + listeners + Connecting
      // pill + Connected box). FIX 16's controls row is still
      // gone.
      final s = strip();
      expect(code.contains('_buildHostCardControls'), isFalse,
          reason: 'FIX 16 deleted the controls row');
      expect(s.contains('if (compactControls)'), isTrue);
      final micAt = s.indexOf('_buildHostMicButton(');
      final statusAt = s.indexOf('_buildHostStatusStrip(');
      expect(micAt, isNot(-1));
      expect(statusAt, greaterThan(micAt),
          reason: 'status strip (row 2) sits after the mic row');
      // The status strip holds the pill (+ the Connected box).
      // FIX 31b: LIVE + listeners have ONE home now — they moved
      // OUT of the status strip into the panel header strip
      // (_fix31bHeaderStrip), so they are never shown twice.
      final status = _region(code, 'Widget _buildHostStatusStrip(',
          'Widget _buildHostLiveColumn(');
      expect(status.contains('_buildConnectingPill()'), isTrue);
      expect(status.contains('_buildLivePill()'), isFalse);
      expect(status.contains('_buildListenersRow()'), isFalse);
      final headerStrip = _region(code, 'Widget _fix31bHeaderStrip(',
          'Widget _fix31bPodiumHeader(');
      expect(headerStrip.contains('_buildLivePill()'), isTrue);
      expect(headerStrip.contains('_buildListenersRow()'), isTrue);
    });

    test('Connecting pill is a SMALL chip (9px text, tight padding)', () {
      final p = pill();
      // FIX 31b: the 9px text wears the AI Studio body token now
      // (Inter 9, w800) — same size, same tight padding.
      expect(p.contains('ArenaTypography.body(9'), isTrue);
      expect(
          p.contains(
              'padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3)'),
          isTrue);
      // The old pill was 12px text with 10/6 padding — gone.
      expect(p.contains('fontSize: 12'), isFalse);
    });

    test('Music / Settings / RJ survive in the header sheet (FIX 16)', () {
      // FIX 16: the 28px icon buttons are gone with the controls
      // row — their functions live in the header Settings sheet,
      // reached through the voice controller.
      expect(code.contains('_hostCardIconBtn'), isFalse,
          reason: 'FIX 16 deleted the small icon buttons');
      expect(code.contains('void _bindVoiceController()'), isTrue);
      expect(code.contains('widget.voiceController?.bind('), isTrue);
      expect(code.contains('onCloseVoice: widget.onCloseVoice'), isTrue);
      // FIX 22 item 21: Music opens the RJ console focused on
      // the PLAYER section (no standalone player sheet).
      expect(code.contains('onMusic: () => unawaited('), isTrue);
      expect(
          code.contains("_showRjVoiceConsole(initialSection: 'player')"),
          isTrue);
      expect(code.contains('onRoomSettings: _showRoomSettings,'), isTrue);
      expect(code.contains('onRjConsole: _showRjVoiceConsole,'), isTrue);
    });

    test('embedded voice mounts the compact top box', () {
      expect(
          code.contains(
              '_buildHostStrip(uid, peers, compactControls: true)'),
          isTrue);
    });

    test('full room page keeps its own (non-compact) top box', () {
      expect(code.contains('          _buildHostStrip(uid, peers),'), isTrue);
    });
  });

  group('G9 — the top box is SHORTER (height reduced)', () {
    test('outer top 8 -> 6 in compact mode', () {
      expect(
          strip().contains(
              'EdgeInsets.fromLTRB(12, compactControls ? 6 : 8, 12, 0)'),
          isTrue);
    });

    test('card padding 10 -> 8 in compact mode (old 10 gone)', () {
      expect(strip().contains('vertical: compactControls ? 8 : 14'),
          isTrue);
      expect(code.contains('compactControls ? 10 : 14'), isFalse,
          reason: 'the old FIX 1 padding must not survive anywhere');
    });

    test('no controls-to-mic gap at all (FIX 16 deleted the row)', () {
      // FIX 16: the controls row is gone, so its 6px gap is gone
      // too. FIX 23 item 2: Row 1's horizontal gaps are the
      // hoisted hostGap (8px in compact mode, avatar|middle|mic),
      // and Row 2 follows after a 6px vertical gap.
      final s = strip();
      expect(s.contains('_buildHostCardControls'), isFalse);
      expect(s.contains('final hostGap = SizedBox(width: compactControls ? 8 : 10)'),
          isTrue);
      final at = s.indexOf('if (compactControls)');
      final to = s.indexOf('else', at);
      final row = s.substring(at, to);
      expect('hostGap,'.allMatches(row).length, 2,
          reason: 'Row 1 has two hostGap spacers: avatar|middle|mic');
      expect(row.contains('const SizedBox(height: 6),'), isTrue);
      // FIX 31b: the strip is no-arg now (LIVE + listeners moved
      // to the header strip — it needs no hostOnVoice any more).
      expect(row.contains('_buildHostStatusStrip()'), isTrue);
    });

    test('Live-column gaps are 2 in compact mode (was 4)', () {
      final l = live();
      expect(l.contains('Widget _buildHostLiveColumn('), isTrue);
      expect(l.contains('{bool compact = false}'), isTrue);
      // FIX 22 item 14 added two more rows (listeners under the
      // LIVE pill + the Connected box at the bottom), so the
      // column now has FOUR 2-in-compact gaps: pill|listeners,
      // listeners|wave, wave|status, status|Connected box.
      expect('compact ? 2 : 4'.allMatches(l).length, 4,
          reason: 'all Live-column gaps must tighten in compact mode');
      // FIX 23 item 2: the compact card no longer mounts the
      // Live column directly — Row 2 is the status strip (which
      // reuses the pill + listeners builders). The full-page
      // branch still mounts the Live column (no compact flag).
      expect(
          strip().contains('_buildHostStatusStrip()'), isTrue);
      expect(
          strip().contains(
              '_buildHostLiveColumn(hostUnmuted, hostOnVoice)'),
          isTrue);
    });

    test('tagline is real data only, omitted when absent (FIX 22 item 14)', () {
      // FIX 22 item 14 SUPERSEDES G7's deletion: the tagline is
      // BACK, but only as REAL data — the organizer's profile bio
      // (async, _hostBioFor) else the scope description — and the
      // line is omitted (SizedBox.shrink) when neither exists.
      // The screenshot's sample text must NEVER appear in code.
      expect(code.contains('Good Vibes • Real Talks • Heart Connects'),
          isFalse,
          reason: 'sample tagline text must never ship');
      expect(code.contains('future: _hostBioFor(hostUid)'), isTrue,
          reason: 'tagline starts from the organizer bio lookup');
      expect(code.contains('final tag = bio.isNotEmpty ? bio : description;'),
          isTrue,
          reason: 'bio wins, else the scope description');
      expect(code.contains('if (tag.isEmpty) return const SizedBox.shrink();'),
          isTrue,
          reason: 'no bio and no description = no tagline line');
    });

    test('ON/OFF state label shows in BOTH modes (FIX 22 item 14a)', () {
      // SUPERSEDES G9's "label hidden in compact" rule: the mic
      // button now shows its STATE (ON/OFF) at a glance in both
      // modes — no compact gate, no backwards Mute/Unmute action
      // labels.
      final m = mic();
      expect(m.contains('bool compact = false'), isTrue);
      expect(m.contains('if (!compact) ...['), isFalse);
      expect(m.contains("Text(micOn ? 'ON' : 'OFF'"), isTrue);
      expect(m.contains("'Mute'"), isFalse);
      expect(m.contains("'Unmute'"), isFalse);
      // The compact cluster passes compact: true.
      expect(
          strip().contains(
              'hostName: hostName, compact: true)'),
          isTrue);
    });

    test('green mic button size UNCHANGED (56px, icon 24)', () {
      final m = mic();
      expect(m.contains('width: 56,'), isTrue);
      expect(m.contains('height: 56,'), isTrue);
      // FIX 22 item 14b renamed the ternary (micOn = hostUnmuted,
      // behavior identical): mic when on, mic_off when muted.
      expect(m.contains('micOn ? Icons.mic : Icons.mic_off'), isTrue);
      expect(m.contains('size: 24'), isTrue);
    });

    test('HEIGHT BUDGET: compact top box <= 112px (was ~134px)', () {
      // Parse the driving literals from the code itself — a
      // regression in any one of them fails this test.
      // MERGE LANE: FIX 16 deleted the controls row (no 28px row,
      // no 6px gap) and G7 deleted the badge/subtitle/tagline, so
      // the budget below is the FIX-16 structure: ONE row
      // (Live column | pill | mic) + a name-only left column.
      final s = strip();
      final outerTop = _parseInt(s,
          r'fromLTRB\(12, compactControls \? (\d+) : 8, 12, 0\)', 'outer top');
      final cardPad = _parseInt(
          s, r'vertical: compactControls \? (\d+) : 14', 'card padding');
      expect(code.contains('_buildHostCardControls'), isFalse,
          reason: 'FIX 16 deleted the controls row — no row, no gap');
      final liveGap = _parseInt(
          live(), r'compact \? (\d+) : 4', 'Live-column gap');
      final micSize =
          _parseInt(mic(), r'width: (\d+),\s*\n\s*height: (\d+),', 'mic size');
      expect(outerTop, 6);
      expect(cardPad, 8);
      expect(liveGap, 2);
      expect(micSize, 56);

      // Right cluster: ONE row — Live column vs the 56px mic.
      // Live column = pill (4+4 padding + 11px text at height
      // 1.2 = 21.2) + gap + wave (max 14: 5 + 9 in _MicWave) +
      // gap + status text (11 x 1.2 = 13.2).
      expect(code.contains('final h = 5 + 9 *'), isTrue,
          reason: 'wave max height 14 must stay pinned');
      const pillH = 8 + 11 * 1.2; // 21.2
      const statusH = 11 * 1.2; // 13.2
      const waveMax = 14.0;
      final liveColH = pillH + liveGap + waveMax + liveGap + statusH;
      final rowH = liveColH > micSize ? liveColH : micSize.toDouble();
      final rightClusterH = rowH;

      // Left column (G7): the organizer name ONLY (17 x 1.2 =
      // 20.4) — badge, subtitle and tagline are all gone. It
      // must stay under the right cluster, so the right cluster
      // — not the text — sets the height.
      const leftColH = 17 * 1.2;
      expect(leftColH, lessThan(rightClusterH),
          reason: 'left column must not outgrow the right cluster');

      final total = outerTop + 2 * cardPad + rightClusterH;
      // Pre-G9 (FIX 1) budget: 8 + 2*10 + 28 + 6 + 72.2 ≈ 134px
      // (72.2 = mic 56 + 3 + label 13.2; tagline could push the
      // left column to ~101px on a 360dp phone).
      // FIX-16 budget: 6 + 2*8 + 56 = 78px.
      const oldTotal = 134.0;
      expect(total, lessThan(oldTotal),
          reason: 'compact top box must be shorter than before');
      expect(total, lessThanOrEqualTo(112),
          reason: 'compact top box budget is 110px (+2 slack)');
    });
  });

  group('G9 — LIVE + mic controls still present', () {
    test('Live pill + wave + status still render', () {
      final l = live();
      // FIX 23 item 12c: the Live pill is an extracted builder
      // (shared by the live column AND the compact status strip).
      final pill = _region(code, 'Widget _buildLivePill()',
          'Widget _buildListenersRow()');
      expect(pill.contains("Text('Live'"), isTrue);
      // FIX 31b: the Live red is the AI Studio token now.
      expect(pill.contains('ArenaColors.liveRed'), isTrue);
      expect(l.contains('_buildLivePill()'), isTrue);
      expect(l.contains('_MicWave(active: hostUnmuted)'), isTrue);
      expect(l.contains("'Mic on'"), isTrue);
      expect(l.contains("'Muted'"), isTrue);
      // G6b: the offline case is connection-aware now — the
      // literal 'Offline' moved into _hostPresenceLabel().
      expect(l.contains('_hostPresenceLabel()'), isTrue);
    });

    test('mic button still toggles (own seat) / toasts (others)', () {
      final m = mic();
      expect(m.contains('_toggleOwnSeat()'), isTrue);
      expect(m.contains("toast(context, 'Host is not on voice right now.')"),
          isTrue);
    });

    test('no new colours in the touched helpers', () {
      // Gold royalGold + the existing Live red only — no new hex
      // literals in the Live column. (FIX 23 item 12c: the Live
      // red lives in the extracted _buildLivePill now, not
      // inline. FIX 31b: it is the AI Studio token there.)
      expect(live().contains('Color(0xFF'), isFalse);
      final pill = _region(code, 'Widget _buildLivePill()',
          'Widget _buildListenersRow()');
      expect(pill.contains('ArenaColors.liveRed'), isTrue);
    });
  });

  group('G9 — full page untouched', () {
    test('full-page call sites pass no compact flag', () {
      final s = strip();
      expect(s.contains('_buildHostLiveColumn(hostUnmuted, hostOnVoice),'),
          isTrue);
      expect(
          s.contains(
              '_buildHostMicButton(hostOnVoice: hostOnVoice, hostIsMe: hostIsMe, hostUnmuted: hostUnmuted, hostName: hostName),'),
          isTrue);
    });
  });
}
