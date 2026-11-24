// FIX 12 G7 — REWRITTEN for FIX 22 items 14 + 16 + 19 (user
// orders 2026-11-23 18:59–19:12, voice call + reference
// screenshot). G7's original rule ("top box shows ONLY the
// organizer name — no Host pill, no bio") is SUPERSEDED by the
// user's latest direct order from looking at the screenshot:
//
//   * the gold 'Host' pill is BACK above the name (item 14a);
//   * the tagline line is BACK — real bio/description only,
//     omitted when neither exists, NEVER the screenshot's
//     sample text (item 14b);
//   * the scope name sits inside the card (item 14d);
//   * a tappable members button (total + online) lives inside
//     the card (item 16 — supersedes item 14e's 'N live');
//   * the blue verified tick sits INLINE beside the name,
//     Facebook style, when earned (item 19);
//   * the mic button shows its STATE (ON/OFF), not the action
//     (item 14 ext. a).
//
// What G7 still forbids (unchanged): 'Room Owner' /
// 'Tournament Creator' subtitles, 'Host Admin' text anywhere,
// role-named fallbacks ('Host'/'Admin' instead of 'Organizer').
//
// Source pins (what the code says). The room page cannot be
// widget-booted here (build() dereferences FirebaseAuth) — same
// pattern as fix1_voice_panel_compact_test.dart and
// v2016_room_voice_test.dart. Phone-only: the rendered look.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String rel) => File('test/../$rel').readAsStringSync();

/// Source with full-line comments stripped, so a mention inside a
/// comment (e.g. the G7 "REMOVED" notes) never counts as code.
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
  late String code;

  setUpAll(() {
    code = _codeOnly(_read('lib/screens/room_screen.dart'));
  });

  String strip() => _region(
        code,
        'Widget _buildHostStrip(',
        'Widget _buildHostLiveColumn(',
      );

  String hostEntry() => _region(
        code,
        'Map<String, dynamic>? _hostEntry(',
        'Widget _stageCellFree(',
      );

  group('G7 (FIX 22 item 14) — top box: Host pill + organizer name', () {
    test('organizer name is shown (hostName Text, flexible + ellipsis)',
        () {
      // FIX 31b: the name wears the AI Studio heading token now
      // (Rajdhani 17, w700) — same size, same Flexible + ellipsis.
      expect(
          strip().contains(
              'Flexible(child: Text(hostName, style: ArenaTypography.heading(17)'),
          isTrue,
          reason: 'the top box must render the organizer name');
    });

    test('the name comes from the host entry (organizer), not a literal',
        () {
      final s = strip();
      expect(s.contains('_hostEntry(tsnap.hasData'), isTrue);
      // FIX 23 item 17: the no-host fallback is 'No host' now
      // (was 'No one on voice yet') — same host-entry source.
      expect(s.contains("final hostName = host == null ? 'No host' : host['name'] as String;"),
          isTrue);
    });

    test('gold Host pill is PRESENT above the name (item 14a)', () {
      // SUPERSEDES G7's "no Host pill" rule — the user's latest
      // direct order keeps the pill.
      // FIX 31b: the pill is the AI Studio host-card pill now —
      // a Row with a Lucide crown + token-styled 'Host' text on
      // a royal-gold fill (same pill as the full-page screen).
      final s = strip();
      expect(
          s.contains(
              "Text('Host', style: ArenaTypography.body(10, color: ArenaColors.primaryBg, weight: FontWeight.w800))"),
          isTrue);
      expect(s.contains('ArenaColors.royalGold'), isTrue);
      // The pill comes before the name in the column.
      expect(s.indexOf("Text('Host'"),
          lessThan(s.indexOf('Text(hostName')));
    });

    test("no 'Room Owner' / 'Tournament Creator' subtitle in the top box",
        () {
      final s = strip();
      expect(s.contains("'Room Owner'"), isFalse);
      expect(s.contains("'Tournament Creator'"), isFalse);
      // FIX 23 item 16c SUPERSEDES the "no trophy icon" pin:
      // the trophy is back, but ONLY as the community-image
      // fallback (no cover photo set) beside the community
      // name — never as a subtitle row.
      expect(s.contains('if (coverUrl.isNotEmpty)'), isTrue);
      expect(s.contains('ArenaCachedImage(imageUrl: coverUrl'), isTrue);
      // FIX 31b: the trophy fallback wears the AI Studio royal
      // gold now (same icon, same size).
      expect(s.contains('Icon(Icons.emoji_events, color: ArenaColors.royalGold, size: 16)'),
          isTrue);
    });

    test('tagline is real bio/description or omitted — never sample text',
        () {
      final s = strip();
      // Bio lookup (async) falls back to the scope description;
      // an empty tagline renders nothing at all.
      expect(s.contains('FutureBuilder<String>'), isTrue);
      expect(s.contains('future: _hostBioFor(hostUid)'), isTrue);
      expect(s.contains('final tag = bio.isNotEmpty ? bio : description;'),
          isTrue);
      expect(s.contains('if (tag.isEmpty) return const SizedBox.shrink();'),
          isTrue);
      // Item 14b SUPERSEDES G7's "no italic tagline" rule — the
      // tagline is back, in the same italic style.
      expect(s.contains('FontStyle.italic'), isTrue);
    });

    test("the screenshot's sample tagline appears nowhere in lib", () {
      var scanned = 0;
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        scanned++;
        expect(f.readAsStringSync(), isNot(contains('Good Vibes')),
            reason: f.path);
      }
      expect(scanned, greaterThan(50), reason: 'scanned $scanned files');
    });

    test('scope name is present inside the card (item 14d)', () {
      final s = strip();
      expect(s.contains('if (scopeName.isNotEmpty)'), isTrue);
      expect(s.contains('scopeName,'), isTrue);
      // NO 'N live' suffix in the scope line — item 16 moved
      // the live count into the members button below.
      expect(s.contains('liveCount'), isFalse);
      expect(s.contains('liveKnown'), isFalse);
    });

    test('members button is GONE from the card — the count lives in the sidebar (FIX 23 item 12b)',
        () {
      final s = strip();
      // FIX 23 item 12b: no "members" text anywhere in the room
      // — the host-card members button (total + online) is
      // removed. The real count lives in the sidebar Followers
      // entry, which opens the same members page.
      expect(s.contains('widget.onHostCardMembersPressed'), isFalse);
      expect(s.contains('widget.hostCardTotalMembers'), isFalse);
      expect(s.contains('members'), isFalse);
      final sb = _region(
        code,
        'Widget _buildEmbeddedSidebar(',
        'Widget _sidebarRoundBtn(',
      );
      expect(sb.contains("'Followers'"), isTrue);
      expect(sb.contains('followersSub'), isTrue);
      expect(sb.contains('widget.onSidebarFollowers'), isTrue);
      expect(sb.contains('members'), isFalse);
    });

    test("no 'Admin' text in the top box", () {
      expect(strip().contains("'Admin'"), isFalse,
          reason: 'no Admin text may appear in the top box');
    });

    test("the text 'Host Admin' appears nowhere in lib", () {
      var scanned = 0;
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        scanned++;
        expect(f.readAsStringSync(), isNot(contains('Host Admin')),
            reason: f.path);
      }
      // Non-vacuous: the walk must actually have covered the tree.
      expect(scanned, greaterThan(50), reason: 'scanned $scanned files');
    });
  });

  group('G7 — name fallbacks are role-free', () {
    test("host fallbacks say 'Organizer', never 'Host' / 'Admin' — and item 17 removed fallbacks entirely", () {
      final h = hostEntry();
      expect(h.contains("'name': 'Host'"), isFalse);
      expect(h.contains("'name': 'Admin'"), isFalse);
      expect(h.contains(": 'Admin'"), isFalse);
      // FIX 23 item 17 SUPERSEDES the two 'Organizer' fallbacks:
      // _hostEntry returns null when the organizer is not
      // present — no fallback name of ANY kind is invented.
      expect('Organizer'.allMatches(h).length, 0);
      expect(h.contains('return null;'), isTrue);
    });
  });

  group('G7 (FIX 22 item 14) — LIVE badge, mic STATE and pill STAY', () {
    test('LIVE badge still present', () {
      // FIX 23 item 2: the pill is extracted into _buildLivePill
      // (the compact card's status strip reuses the identical
      // widget) — pin it there, plus the column's call.
      final pill = _region(
        code,
        'Widget _buildLivePill()',
        'Widget _buildHostStatusStrip(',
      );
      expect(pill.contains("Text('Live'"), isTrue);
      // FIX 31b: the Live red is the AI Studio token now.
      expect(pill.contains('ArenaColors.liveRed'), isTrue);
      final live = _region(
        code,
        'Widget _buildHostLiveColumn(',
        'Widget _buildHostMicButton(',
      );
      expect(live.contains('_buildLivePill()'), isTrue);
      expect(strip().contains('_buildHostLiveColumn('), isTrue,
          reason: 'the top box must still mount the Live column');
    });

    test('mic button shows its STATE (56px, ON/OFF) — not the action',
        () {
      final mic = _region(
        code,
        'Widget _buildHostMicButton(',
        // FIX 16 deleted _buildHostCardControls — the widget that
        // follows the mic button now is _buildConnectingPill.
        'Widget _buildConnectingPill()',
      );
      expect(mic.contains('width: 56,'), isTrue);
      expect(mic.contains('height: 56,'), isTrue);
      // State, not action: distinct icon + label + colour per
      // state (green mic + ON vs grey mic_off + OFF).
      expect(mic.contains('Icon(micOn ? Icons.mic : Icons.mic_off'), isTrue);
      expect(mic.contains("Text(micOn ? 'ON' : 'OFF'"), isTrue);
      expect(mic.contains('const Color(0xFF16D879)'), isTrue);
      expect(mic.contains('const Color(0xFF5A6076)'), isTrue);
      // The old backwards action labels are gone.
      expect(mic.contains("'Mute'"), isFalse);
      expect(mic.contains("'Unmute'"), isFalse);
      expect(strip().contains('_buildHostMicButton('), isTrue,
          reason: 'the top box must still mount the mic button');
    });

    test(
        'Connecting pill stays in the card; Music/RJ open the console (FIX 22 item 21)',
        () {
      // FIX 16 (merged 2026-11-23): the compact controls row
      // (_buildHostCardControls + _hostCardIconBtn) is GONE — the
      // Connecting pill alone stays in the host card, and Music /
      // Settings / RJ moved to the header Settings sheet via the
      // voice controller. FIX 22 item 21: Music opens the RJ
      // console focused on the PLAYER section (no standalone
      // player sheet any more).
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
      expect(code.contains('onMusic: _showMusicPlayer'), isFalse);
      expect(code.contains('onRoomSettings: _showRoomSettings'), isTrue);
      expect(code.contains('onRjConsole: _showRjVoiceConsole'), isTrue);
      expect(strip().contains('_buildConnectingPill()'), isTrue,
          reason: 'the top box must still mount the Connecting pill');
    });

    test('blue tick renders INLINE beside the name (item 19)', () {
      final s = strip();
      // The tick FutureBuilder sits INSIDE the name Row, after
      // the name Text — same line, Facebook style, never below.
      final nameIdx = s.indexOf('Text(hostName');
      final tickIdx = s.indexOf('future: _hostVerifiedFor(hostUid)');
      final iconIdx = s.indexOf('Icon(Icons.verified');
      expect(nameIdx, isNot(-1));
      expect(tickIdx, greaterThan(nameIdx));
      expect(iconIdx, greaterThan(tickIdx));
      // The tick shows for the admin owner, the verified flag, or
      // 1000+ followers — the three halves of the condition, in
      // order. FIX 23 item 2: the condition is guarded by
      // hostUid.isNotEmpty now (no tick when no host).
      expect(s.contains('final show = hostUid.isNotEmpty &&'), isTrue);
      expect(s.contains('hostIsAdminOwner ||'), isTrue);
      expect(s.contains('widget.hostCardVerified ||'), isTrue);
      expect(
          s.indexOf('widget.hostCardVerified ||'),
          greaterThan(s.indexOf('final show = hostUid.isNotEmpty &&')));
      expect(s.contains('hostVerifiedTick('), isTrue);
      expect(
          s.contains(
              'return const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.verified, color: nBlue, size: 16));'),
          isTrue);
    });
  });
}
