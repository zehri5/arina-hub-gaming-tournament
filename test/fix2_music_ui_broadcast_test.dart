// FIX 2 — MUSIC LIBRARY + PLAYER UI + BROADCAST/UPLOAD (2026-11-22).
//
// Sameer's 4 complaints (voice call 22:36 + screenshot
// 1000049937_63_6ljr.jpg — Music library sheet, TEST CO chat):
//   A. Library UI != the design he had made (design:
//      music-library-design-final.png).
//   B. The player NEVER opens — tapping "Open player" just plays
//      the song in place; the player UI (vinyl, spectrum, knobs,
//      presets) never appears.
//   C. Broadcast turns OFF the moment a track is selected, and
//      will NOT turn ON while a track plays.
//   D. Local Upload does NOTHING while Broadcast is ON; works
//      only after turning Broadcast OFF.
//
// What the fixes are (room_screen.dart mount + library panel):
//   B. onOpenPlayer/onPlaylist await the sheet's exit
//      (ModalRoute.popped) before pushing the next sheet — the
//      synchronous pop+push raced the exit on device; and
//      _showMusicPlayer ensured the player instead of refusing
//      when the field was null. Tapping the now-playing strip's
//      title/artist area also opens the player. (FIX 22 item 21:
//      the standalone player sheet is retired — the player
//      lives inside the RJ console now, and the console
//      prologue ensures the player the same way.)
//   C. Broadcast permission is scope-aware (team captain counts
//      as a broadcaster; the tournament join gate never blocks
//      team scope), and a failed share NEVER reverts the toggle
//      to OFF — the room falls back to speaker mode instead.
//   D. _pickAndShareFile picks FIRST and shares second — the
//      upload never depends on broadcast state.
//   A. Library panel matches the design: white song-card artist,
//      stronger golden glows, warm radial glow backdrop, and the
//      list shrink-wraps so Local Upload sits right under the
//      last song (no big empty gap).
//
// The mount itself (UnifiedRoomPage) cannot be pumped in a widget
// test (Firebase/Supabase/LiveKit), so the mount fixes are pinned
// by source — the same pattern as music_dsp_swap_mount_test.dart.
// The panel behaviour is pinned by real widget tests.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/widgets/music_library_panel.dart';
import 'package:protournament_user/widgets/music_player_panel.dart';

String _read(String path) => File(path).readAsStringSync();

/// Source slice from [startMarker] (inclusive) to [endMarker]
/// (exclusive) — the end marker is searched AFTER the start.
String _slice(String src, String startMarker, String endMarker) {
  final start = src.indexOf(startMarker);
  final end = src.indexOf(endMarker, start + startMarker.length);
  return src.substring(start, end);
}

class _Calls {
  int openPlayer = 0;
  int pauseResume = 0;
  int stop = 0;
  int upload = 0;
  final List<String> playSong = <String>[];
}

const _stripSong = LibrarySong(
  key: 'file:/x/strip.mp3',
  title: 'Strip Song',
  artist: 'Strip Artist',
  duration: Duration(minutes: 7, seconds: 5),
  isPlaying: true,
  statusLine: 'Local only',
);

const _listSong = LibrarySong(
  key: 'file:/x/list.mp3',
  title: 'List Song',
  artist: 'List Artist',
  duration: Duration(minutes: 3, seconds: 45),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpLibrary(
    WidgetTester tester,
    _Calls calls, {
    bool broadcastOn = false,
    LibrarySong? nowPlaying = _stripSong,
    List<LibrarySong> songs = const [_listSong],
  }) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF1E1408),
          body: MusicLibraryPanel(
            songs: songs,
            nowPlaying: nowPlaying,
            nowPlayingPaused: false,
            broadcastOn: broadcastOn,
            selectedTab: 0,
            searchQuery: '',
            onTabChanged: (_) {},
            onSearchChanged: (_) {},
            onPlaySong: (k) => calls.playSong.add(k),
            onPauseResume: () => calls.pauseResume++,
            onStop: () => calls.stop++,
            onOpenPlayer: () => calls.openPlayer++,
            onToggleBookmark: (_) {},
            onEditSong: (_) {},
            onUpload: () => calls.upload++,
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  MusicPlayerPanel playerPanel() {
    return MusicPlayerPanel(
      title: 'Strip Song',
      artist: 'Strip Artist',
      statusLine: 'Shared • ducked to 5% — RJ bed',
      isDucked: true,
      position: const Duration(seconds: 83),
      duration: const Duration(minutes: 7, seconds: 5),
      onSeek: (_) {},
      isPlaying: true,
      isRepeat: false,
      onPlayPause: () {},
      onRepeat: () {},
      onPrevious: () {},
      onNext: () {},
      onPlaylist: () {},
      onStop: () {},
      volume: 0.8,
      onVolumeChanged: (_) {},
      broadcastOn: true,
      isHost: true,
      reverb: 0.6,
      echo: 0.45,
      delayMs: 250,
      bassDb: 6,
      onReverb: (_) {},
      onEcho: (_) {},
      onDelayMs: (_) {},
      onBassDb: (_) {},
      preset: 'Room',
      onPreset: (_) {},
      noiseCancellation: true,
      onNoiseCancellation: (_) {},
      noiseGateEnabled: true,
      noiseGateThresholdDb: -45,
      onNoiseGateEnabled: (_) {},
      onNoiseGateThreshold: (_) {},
      compressorEnabled: true,
      compressorThresholdDb: -18,
      compressorRatio: 2.5,
      onCompressorEnabled: (_) {},
      onCompressorThreshold: (_) {},
      onCompressorRatio: (_) {},
      listenerCount: 128,
      listenerAvatarUrls: const [],
      onListenersPressed: () {},
    );
  }

  group('B — open player (panel)', () {
    testWidgets('tapping the now-playing strip title opens the player',
        (tester) async {
      final calls = _Calls();
      await pumpLibrary(tester, calls);
      await tester.tap(find.text('Strip Song'));
      await tester.pump();
      expect(calls.openPlayer, 1,
          reason: 'strip title tap must fire onOpenPlayer');
      expect(calls.pauseResume, 0);
    });

    testWidgets('tapping the strip status line opens the player',
        (tester) async {
      final calls = _Calls();
      await pumpLibrary(tester, calls);
      await tester.tap(find.text('Local only').first);
      await tester.pump();
      expect(calls.openPlayer, 1,
          reason: 'strip status tap must fire onOpenPlayer');
    });

    testWidgets('Open player button still opens the player',
        (tester) async {
      final calls = _Calls();
      await pumpLibrary(tester, calls);
      await tester.tap(find.text('Open\nplayer'));
      await tester.pump();
      expect(calls.openPlayer, 1);
    });

    testWidgets('strip pause button does NOT open the player',
        (tester) async {
      // The list song is NOT playing (play icon), so the only
      // pause icon on screen is the strip's own pause button.
      final calls = _Calls();
      await pumpLibrary(tester, calls);
      expect(find.byIcon(Icons.pause), findsOneWidget);
      await tester.tap(find.byIcon(Icons.pause));
      await tester.pump();
      expect(calls.pauseResume, 1);
      expect(calls.openPlayer, 0,
          reason: 'the strip InkWell must not swallow the pause tap');
    });

    testWidgets('strip stop button does NOT open the player',
        (tester) async {
      final calls = _Calls();
      await pumpLibrary(tester, calls);
      expect(find.byIcon(Icons.stop), findsOneWidget);
      await tester.tap(find.byIcon(Icons.stop));
      await tester.pump();
      expect(calls.stop, 1);
      expect(calls.openPlayer, 0,
          reason: 'the strip InkWell must not swallow the stop tap');
    });
  });

  group('B — open player (sheet transition, fixed mount pattern)', () {
    testWidgets(
        'awaited pop + show opens the REAL player panel from the library sheet',
        (tester) async {
      // Replicates the FIXED mount code (room_screen.dart
      // onOpenPlayer): await the popped route, then show the
      // player sheet. Uses pump() with durations, never
      // pumpAndSettle — the player's vinyl repeats forever.
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late BuildContext roomCtx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              roomCtx = context;
              return Scaffold(
                body: TextButton(
                  onPressed: () {
                    showModalBottomSheet<void>(
                      context: roomCtx,
                      backgroundColor: const Color(0xFF1E1408),
                      isScrollControlled: true,
                      builder: (ctx) {
                        final calls = _Calls();
                        return SizedBox(
                          height:
                              MediaQuery.of(ctx).size.height * 0.85,
                          child: MusicLibraryPanel(
                            songs: const [_listSong],
                            nowPlaying: _stripSong,
                            nowPlayingPaused: false,
                            broadcastOn: false,
                            selectedTab: 0,
                            searchQuery: '',
                            onTabChanged: (_) {},
                            onSearchChanged: (_) {},
                            onPlaySong: (_) {},
                            onPauseResume: () {},
                            onStop: () {},
                            onOpenPlayer: () async {
                              final popped =
                                  ModalRoute.of(ctx)?.popped;
                              Navigator.pop(ctx);
                              if (popped != null) await popped;
                              showModalBottomSheet<void>(
                                context: roomCtx,
                                backgroundColor:
                                    const Color(0xFF1E1408),
                                isScrollControlled: true,
                                builder: (_) => playerPanel(),
                              );
                            },
                            onToggleBookmark: (_) {},
                            onEditSong: (_) {},
                            onUpload: () {},
                                            onClose: () => Navigator.pop(ctx),
                          ),
                        );
                      },
                    );
                  },
                  child: const Text('open lib'),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('open lib'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Music'), findsOneWidget);
      await tester.tap(find.text('Open\nplayer'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(MusicPlayerPanel), findsOneWidget,
          reason: 'the player sheet must open after the awaited pop');
      expect(find.text('Music'), findsNothing,
          reason: 'the library sheet must be gone');
      expect(find.text('Strip Song'), findsOneWidget);
    });
  });

  group('C+D — broadcast status pill is display-only + upload (panel)', () {
    testWidgets('broadcast pill shows OFF and does nothing on tap',
        (tester) async {
      // FIX 22 item 21: hosting is GO LIVE only — the library
      // pill is a display-only status indicator, NOT a toggle.
      // Tapping it must not call anything (there is no
      // onBroadcastChanged callback any more).
      final calls = _Calls();
      await pumpLibrary(tester, calls, broadcastOn: false);
      expect(find.text('OFF'), findsOneWidget);
      await tester.tap(find.text('OFF'));
      await tester.pump();
      expect(find.text('OFF'), findsOneWidget);
    });

    testWidgets('broadcast pill shows ON and does nothing on tap',
        (tester) async {
      final calls = _Calls();
      await pumpLibrary(tester, calls, broadcastOn: true);
      expect(find.text('ON'), findsOneWidget);
      await tester.tap(find.text('ON'));
      await tester.pump();
      expect(find.text('ON'), findsOneWidget);
    });

    testWidgets('Local Upload fires with Broadcast OFF', (tester) async {
      final calls = _Calls();
      await pumpLibrary(tester, calls, broadcastOn: false);
      await tester.tap(find.text('Local Upload'));
      await tester.pump();
      expect(calls.upload, 1);
    });

    testWidgets('Local Upload fires with Broadcast ON', (tester) async {
      final calls = _Calls();
      await pumpLibrary(tester, calls, broadcastOn: true);
      await tester.tap(find.text('Local Upload'));
      await tester.pump();
      expect(calls.upload, 1,
          reason: 'upload must work whether broadcast is ON or OFF');
    });
  });

  group('A — library design elements', () {
    testWidgets('all design sections render', (tester) async {
      final calls = _Calls();
      await pumpLibrary(tester, calls, broadcastOn: true);
      expect(find.text('Music'), findsOneWidget);
      expect(find.text('Broadcast My Music'), findsOneWidget);
      expect(find.text('Local Music'), findsOneWidget);
      expect(find.text('My Playlist'), findsOneWidget);
      expect(find.text('Search for songs or artists'), findsOneWidget);
      expect(find.text('All: 1'), findsOneWidget);
      expect(find.text('Session library — your uploaded songs'),
          findsOneWidget);
      expect(find.text('List Song'), findsOneWidget);
      expect(find.text('03:45'), findsOneWidget,
          reason: 'duration badge on the song card');
      expect(find.text('Local Upload'), findsOneWidget);
      expect(
          find.textContaining(
              'Your own audio files from this phone'),
          findsOneWidget);
      expect(find.textContaining('Broadcast ON:'), findsOneWidget,
          reason: 'bottom broadcast banner shows while ON');
    });

    testWidgets('bottom broadcast banner hides while OFF',
        (tester) async {
      final calls = _Calls();
      await pumpLibrary(tester, calls, broadcastOn: false);
      expect(find.textContaining('Broadcast ON:'), findsNothing);
    });

    testWidgets('song-card artist is white (design)', (tester) async {
      final calls = _Calls();
      await pumpLibrary(tester, calls);
      final artist = tester.widget<Text>(find.text('List Artist'));
      expect(artist.style?.color, const Color(0xFFFFFFFF),
          reason: 'design shows the song-card artist in white');
    });

    testWidgets('now-playing strip artist stays gold', (tester) async {
      final calls = _Calls();
      await pumpLibrary(tester, calls);
      final artist = tester.widget<Text>(find.text('Strip Artist'));
      expect(artist.style?.color, const Color(0xFFFDC903),
          reason: 'design shows the strip artist in gold');
    });
  });

  group('A — player design elements', () {
    testWidgets('all design sections render', (tester) async {
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: const Color(0xFF1E1408),
            body: playerPanel(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Strip Song'), findsOneWidget);
      expect(find.text('Strip Artist'), findsOneWidget);
      expect(find.text('RJ bed'), findsOneWidget);
      expect(find.text('01:23'), findsOneWidget);
      expect(find.text('07:05'), findsOneWidget);
      expect(find.text('HOST-ONLY MUSIC EFFECTS'), findsOneWidget);
      expect(find.text('REVERB'), findsOneWidget);
      expect(find.text('ECHO'), findsOneWidget);
      expect(find.text('DELAY'), findsOneWidget);
      expect(find.text('BASS'), findsOneWidget);
      expect(find.text('PRESETS:'), findsOneWidget);
      expect(find.text('OFF'), findsOneWidget);
      expect(find.text('ROOM'), findsOneWidget);
      expect(find.text('HALL'), findsOneWidget);
      expect(find.text('Noise Cancellation'), findsOneWidget);
      expect(find.text('128 listening'), findsOneWidget);
      expect(find.text('Broadcast ON'), findsOneWidget);
      expect(
          find.text(
              'Seeking moves only your phone — shared listeners keep their own position.'),
          findsOneWidget);
    });
  });

  group('mount source pins (room_screen.dart)', () {
    late String src;
    setUpAll(() {
      src = _read('lib/screens/room_screen.dart');
    });

    test('team captain counts as a broadcaster', () {
      expect(src.contains('_isTeamCaptainForBroadcast'), isTrue);
      // FIX 12 G6 (F1): the community organizer joins the gate —
      // the captain term is unchanged, still second in the chain.
      expect(
          src.contains(
              '_canBroadcastMusic => _isAdminForBroadcast || _isTeamCaptainForBroadcast || _isCommunityOrganizerForBroadcast || _musicApproved'),
          isTrue,
          reason: 'captain must pass the broadcast permission gate');
      expect(src.contains("bool get _broadcastJoinBlocked => !_isTeam"),
          isTrue,
          reason: 'the tournament join gate must never block team scope');
    });

    test('upload picks the file BEFORE any broadcast gate', () {
      final fn = _slice(src, 'Future<void> _pickAndShareFile()',
          'Future<void> _setBroadcast(');
      final pick = fn.indexOf('await _pickAudioFile()');
      final joinGate = fn.indexOf('_broadcastJoinBlocked');
      final permGate = fn.indexOf('_canBroadcastMusic');
      expect(pick, isNot(-1));
      expect(joinGate, isNot(-1));
      expect(permGate, isNot(-1));
      expect(pick, lessThan(joinGate),
          reason: 'pick must precede the join gate');
      expect(pick, lessThan(permGate),
          reason: 'pick must precede the permission gate');
      expect(fn.contains('_upsertLibraryFile(picked.path, picked.name)'),
          isTrue);
      expect(fn.contains('await _playLocalFile(picked.path, picked.name)'),
          isTrue,
          reason: 'a blocked share still plays the picked file locally');
    });

    test('a failed share NEVER reverts the broadcast toggle', () {
      final fn = _slice(src, 'Future<bool> _uploadAndShareFile(',
          'Future<void> _broadcastExistingFile(');
      expect(fn.contains('_broadcastMusic = false'), isFalse,
          reason: 'no revert-to-OFF anywhere in the share path');
      expect(fn.contains('_sharedFallback = true'), isTrue,
          reason: 'failed fromToggle shares fall back to speaker mode');
      expect(fn.contains('Broadcast ON via speaker'), isTrue);
    });

    test('setBroadcast ON still flips the toggle ON', () {
      final fn = _slice(
          src, 'Future<void> _setBroadcast(', 'Future<void> _playPrevNext(');
      expect(fn.contains('setState(() => _broadcastMusic = true)'), isTrue);
    });

    test('track select falls through to local play when blocked', () {
      final fn = _slice(src, 'Future<void> _playLibraryEntry(',
          'Future<void> _pickAndShareFile()');
      expect(fn.contains('playing locally only for now'), isTrue);
      expect(fn.contains('_broadcastJoinBlocked'), isTrue);
      expect(fn.contains('_broadcastMusic = false'), isFalse,
          reason: 'selecting a track must never switch broadcast off');
    });

    test('sheet transitions await the popped route', () {
      // FIX 20 (fix 15): onOpenPlayer + onPlaylist + onRjPanel
      // await the sheet exit before opening the next sheet.
      // FIX 22 item 21: the player lives INSIDE the console now,
      // so onPlaylist pops the console's sheetCtx, not ctx.
      expect('ModalRoute.of(ctx)?.popped'.allMatches(src).length, 2,
          reason: 'onOpenPlayer AND onRjPanel await the library exit');
      expect('ModalRoute.of(sheetCtx)?.popped'.allMatches(src).length, 1,
          reason: 'onPlaylist awaits the console exit');
      expect(src.contains('if (popped != null) await popped'), isTrue);
    });

    test('console prologue ensures the player instead of refusing', () {
      // FIX 22 item 21: _showMusicPlayer is RETIRED — the console
      // contains the player section, so the console prologue
      // ensures the player (same idempotent call) before the
      // sheet opens. No null-player refusal anywhere.
      final fn = _slice(src, 'Future<void> _showRjVoiceConsole(',
          '// FIX 22 item 22: _showMusicSettings is DELETED');
      expect(fn.contains('await _ensureMusicPlayer();'), isTrue);
      expect(fn.contains('if (!mounted) return;'), isTrue);
      expect(fn.contains('_musicPlayer == null'), isFalse,
          reason: 'the null-player refusal is gone');
      expect(src.contains('Widget _buildConsoleMusicSection('), isTrue);
      expect(src.contains('Future<void> _showMusicPlayer()'), isFalse);
    });

    test('player host flag includes the team captain', () {
      expect(
          src.contains(
              'isHost: _isAdminForBroadcast || _isTeamCaptainForBroadcast'),
          isTrue);
    });

    test('room screen stays inside its line budget', () {
      final lines =
          '\n'.allMatches(src).length + (src.endsWith('\n') ? 0 : 1);
      // Merge-time baseline update (Fix 24 2026-11-23, merged
      // step 7 2026-11-24): the radio music mixer round (APM mixer
      // register/unregister/gains, Krisp force-switch, call-in seat
      // assignment + guest-pick pure rules, link-gated gesture
      // rule, GO LIVE / END LIVE hooks, console wiring, pump feed)
      // legitimately grew room_screen by 365 lines (10940 ->
      // 11305) on top of the fix23 + item-31 tree. The bound now
      // counts from the post-Fix-24 count, with a fresh 200-line
      // budget for the next round. Runaway growth still fails.
      expect(lines, lessThan(11305 + 200),
          reason: 'room screen grew by ${lines - 11305} lines since '
              'Fix 24 (post-Fix-24: 11305); wiring must be surgical');
    });
  });
}
