// MUSIC LIBRARY PANEL TESTS — ARENA HUB #10 AUDIO, Group 9 (2026-11-22).
//
// Widget tests for lib/widgets/music_library_panel.dart (AI Studio
// code, reviewed line-by-line — see MUSIC_LIBRARY_INTEGRATION.md §1).
// The panel is pure UI over constructor props, so every callback is
// recorded and the tests prove the FIRINGS (with the right song
// key), not just the rendering. No MethodChannel, no native code.
//
// The panel is a Column with an Expanded song list, so it needs a
// bounded height — every test pumps it on a sized surface
// (360x800, like the room sheet) instead of inside a scroll view.
// One test uses a narrow 320 px surface (no-overflow check).
//
// Fixture titles/artists are DELIBERATELY different from the
// design image's example values ("Night Drive", "DJ Arman", ...) —
// the render tests would fail if the panel hardcoded any of them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/widgets/music_library_panel.dart';

const _songA = LibrarySong(
  key: 'file:/music/river-road.mp3',
  title: 'River Road',
  artist: 'Sara Khan',
  duration: Duration(minutes: 3, seconds: 45),
);

const _songB = LibrarySong(
  key: 'tone:Ocean Calm',
  title: 'Ocean Calm',
  artist: 'Built-in tone',
  isTone: true,
);

const _songC = LibrarySong(
  key: 'file:/music/city-lights.mp3',
  title: 'City Lights',
  artist: 'The Wanderers',
  duration: Duration(minutes: 4, seconds: 12),
  inPlaylist: true,
);

const _statusLine = 'Shared • ducked to 5% — RJ bed';

/// Records every callback the panel fires, in order.
class _Calls {
  final List<int> tabs = [];
  final List<String> searches = [];
  final List<String> plays = [];
  int pauseResume = 0;
  int stops = 0;
  int openPlayer = 0;
  final List<String> bookmarks = [];
  final List<String> edits = [];
  int uploads = 0;
  int closes = 0;
}

Future<void> _pumpPanel(
  WidgetTester tester,
  _Calls calls, {
  List<LibrarySong> songs = const [_songA, _songC],
  LibrarySong? nowPlaying,
  bool nowPlayingPaused = false,
  bool broadcastOn = true,
  int selectedTab = 0,
  String searchQuery = '',
  Size surface = const Size(360, 800),
}) async {
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MusicLibraryPanel(
          songs: songs,
          nowPlaying: nowPlaying,
          nowPlayingPaused: nowPlayingPaused,
          broadcastOn: broadcastOn,
          selectedTab: selectedTab,
          searchQuery: searchQuery,
          onTabChanged: calls.tabs.add,
          onSearchChanged: calls.searches.add,
          onPlaySong: calls.plays.add,
          onPauseResume: () => calls.pauseResume++,
          onStop: () => calls.stops++,
          onOpenPlayer: () => calls.openPlayer++,
          onToggleBookmark: calls.bookmarks.add,
          onEditSong: calls.edits.add,
          onUpload: () => calls.uploads++,
          onClose: () => calls.closes++,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('rendering', () {
    testWidgets('songs render with title, artist and duration badge',
        (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls);
      expect(find.text('River Road'), findsOneWidget);
      expect(find.text('Sara Khan'), findsOneWidget);
      expect(find.text('City Lights'), findsOneWidget);
      expect(find.text('The Wanderers'), findsOneWidget);
      expect(find.text('03:45'), findsOneWidget);
      expect(find.text('04:12'), findsOneWidget);
      // Count row counts the (already filtered) list.
      expect(find.text('All: 2'), findsOneWidget);
    });

    testWidgets('duration badge is hidden when duration is null',
        (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls, songs: const [_songB]);
      expect(find.text('Ocean Calm'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^[0-9]{2}:[0-9]{2}$')),
          findsNothing);
    });

    testWidgets('tone rows have no edit button; file rows do',
        (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls, songs: const [_songB, _songA]);
      // Exactly one pencil: the file row. The tone row has none.
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      // The tone row still gets its bookmark + play buttons.
      expect(find.byIcon(Icons.bookmark_border), findsNWidgets(2));
      expect(find.byIcon(Icons.play_arrow), findsNWidgets(2));
    });

    testWidgets('empty state differs per tab', (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls, songs: const [], selectedTab: 0);
      expect(find.text('No songs yet — use Local Upload below.'),
          findsOneWidget);
      expect(find.text('All: 0'), findsOneWidget);

      await _pumpPanel(tester, calls, songs: const [], selectedTab: 1);
      expect(find.text('My Playlist is empty — tap the bookmark on any song.'),
          findsOneWidget);
    });

    testWidgets('bottom broadcast banner shows only when broadcast is on',
        (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls, broadcastOn: true);
      // Broadcast card + bottom banner both carry the sensors icon.
      expect(find.byIcon(Icons.sensors), findsNWidgets(2));
      expect(find.textContaining('Broadcast ON:'), findsOneWidget);

      await _pumpPanel(tester, calls, broadcastOn: false);
      expect(find.byIcon(Icons.sensors), findsOneWidget);
      expect(find.textContaining('Broadcast ON:'), findsNothing);
    });

    testWidgets('header, broadcast card, tabs, search and upload render',
        (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls);
      expect(find.text('Music'), findsOneWidget);
      expect(find.text('Broadcast My Music'), findsOneWidget);
      expect(find.text('Local Music'), findsOneWidget);
      expect(find.text('My Playlist'), findsOneWidget);
      expect(find.text('Search for songs or artists'), findsOneWidget);
      expect(find.text('Local Upload'), findsOneWidget);
      expect(
          find.text(
              'Your own audio files from this phone (MP3, WAV, M4A, AAC, OGG, FLAC). No downloads, nothing paid.'),
          findsOneWidget);
    });
  });

  group('tabs + search', () {
    testWidgets('tapping tabs fires onTabChanged with the tab index',
        (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls);
      await tester.tap(find.text('My Playlist'));
      await tester.tap(find.text('Local Music'));
      expect(calls.tabs, [1, 0]);
    });

    testWidgets('typing in search fires onSearchChanged', (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls);
      await tester.enterText(find.byType(TextField), 'River');
      expect(calls.searches, ['River']);
    });

    testWidgets('clear button fires onSearchChanged with empty string',
        (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls, searchQuery: 'river');
      final clear = find.descendant(
        of: find.byType(TextField),
        matching: find.byIcon(Icons.close),
      );
      expect(clear, findsOneWidget);
      await tester.tap(clear);
      expect(calls.searches, ['']);
    });

    testWidgets('no clear button when the query is empty', (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls, searchQuery: '');
      expect(
          find.descendant(
            of: find.byType(TextField),
            matching: find.byIcon(Icons.close),
          ),
          findsNothing);
    });
  });

  group('broadcast status pill is display-only', () {
    testWidgets('ON pill shows the live state and does nothing on tap',
        (tester) async {
      // FIX 22 item 21: hosting is GO LIVE only — the pill is
      // a display-only status indicator, NOT a toggle (no
      // onBroadcastChanged callback exists any more).
      final calls = _Calls();
      await _pumpPanel(tester, calls, broadcastOn: true);
      expect(find.text('ON'), findsOneWidget);
      await tester.tap(find.text('ON'));
      await tester.pump();
      expect(find.text('ON'), findsOneWidget);
    });

    testWidgets('OFF pill shows the local state and does nothing on tap',
        (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls, broadcastOn: false);
      expect(find.text('OFF'), findsOneWidget);
      await tester.tap(find.text('OFF'));
      await tester.pump();
      expect(find.text('OFF'), findsOneWidget);
    });
  });

  group('song row actions', () {
    testWidgets('play button fires onPlaySong with the song key',
        (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls, songs: const [_songA]);
      await tester.tap(find.byIcon(Icons.play_arrow));
      expect(calls.plays, ['file:/music/river-road.mp3']);
    });

    testWidgets(
        'playing row shows pause icon and its button fires onPauseResume',
        (tester) async {
      final calls = _Calls();
      const playing = LibrarySong(
        key: 'file:/music/river-road.mp3',
        title: 'River Road',
        artist: 'Sara Khan',
        duration: Duration(minutes: 3, seconds: 45),
        isPlaying: true,
      );
      await _pumpPanel(tester, calls, songs: const [playing]);
      expect(find.byIcon(Icons.pause), findsOneWidget);
      await tester.tap(find.byIcon(Icons.pause));
      expect(calls.pauseResume, 1);
      expect(calls.plays, isEmpty);
    });

    testWidgets(
        'paused playing row shows play icon and resumes via onPauseResume',
        (tester) async {
      final calls = _Calls();
      const paused = LibrarySong(
        key: 'file:/music/river-road.mp3',
        title: 'River Road',
        artist: 'Sara Khan',
        isPlaying: true,
        isPaused: true,
      );
      await _pumpPanel(tester, calls, songs: const [paused]);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byIcon(Icons.pause), findsNothing);
      await tester.tap(find.byIcon(Icons.play_arrow));
      expect(calls.pauseResume, 1);
      expect(calls.plays, isEmpty);
    });

    testWidgets('playing row shows its status line; idle rows do not',
        (tester) async {
      final calls = _Calls();
      const playing = LibrarySong(
        key: 'file:/music/river-road.mp3',
        title: 'River Road',
        artist: 'Sara Khan',
        isPlaying: true,
        statusLine: _statusLine,
      );
      await _pumpPanel(tester, calls, songs: const [playing, _songC]);
      expect(find.text(_statusLine), findsOneWidget);
    });

    testWidgets('bookmark toggle fires onToggleBookmark with the song key',
        (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls);
      // _songA is not in the playlist (outline), _songC is (filled).
      expect(find.byIcon(Icons.bookmark_border), findsOneWidget);
      expect(find.byIcon(Icons.bookmark), findsOneWidget);
      await tester.tap(find.byIcon(Icons.bookmark_border));
      await tester.tap(find.byIcon(Icons.bookmark));
      expect(calls.bookmarks, [
        'file:/music/river-road.mp3',
        'file:/music/city-lights.mp3',
      ]);
    });

    testWidgets('edit button fires onEditSong with the song key',
        (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls, songs: const [_songA]);
      await tester.tap(find.byIcon(Icons.edit_outlined));
      expect(calls.edits, ['file:/music/river-road.mp3']);
    });
  });

  group('now-playing strip', () {
    const nowPlaying = LibrarySong(
      key: 'file:/music/river-road.mp3',
      title: 'River Road',
      artist: 'Sara Khan',
      duration: Duration(minutes: 3, seconds: 45),
      isPlaying: true,
      statusLine: _statusLine,
    );

    testWidgets('strip shows title, artist and status line',
        (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls,
          songs: const [], nowPlaying: nowPlaying);
      expect(find.text('River Road'), findsOneWidget);
      expect(find.text('Sara Khan'), findsOneWidget);
      expect(find.text(_statusLine), findsOneWidget);
      expect(find.text('Open\nplayer'), findsOneWidget);
    });

    testWidgets('strip is hidden when nothing is playing', (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls, nowPlaying: null);
      expect(find.text('Open\nplayer'), findsNothing);
      expect(find.byIcon(Icons.stop), findsNothing);
    });

    testWidgets('strip pause button fires onPauseResume', (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls,
          songs: const [_songC], nowPlaying: nowPlaying);
      // The row is idle (play icon); only the strip shows pause.
      expect(find.byIcon(Icons.pause), findsOneWidget);
      await tester.tap(find.byIcon(Icons.pause));
      expect(calls.pauseResume, 1);
    });

    testWidgets('strip shows play icon when paused', (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls,
          songs: const [], nowPlaying: nowPlaying, nowPlayingPaused: true);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byIcon(Icons.pause), findsNothing);
    });

    testWidgets('strip stop button fires onStop', (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls,
          songs: const [_songC], nowPlaying: nowPlaying);
      expect(find.byIcon(Icons.stop), findsOneWidget);
      await tester.tap(find.byIcon(Icons.stop));
      expect(calls.stops, 1);
    });

    testWidgets('Open player fires onOpenPlayer', (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls,
          songs: const [], nowPlaying: nowPlaying);
      await tester.tap(find.text('Open\nplayer'));
      expect(calls.openPlayer, 1);
    });
  });

  group('header + upload', () {
    testWidgets('no settings button; close button fires its callback',
        (tester) async {
      // FIX 22 item 22 extension: the library header Settings
      // button opened the same hosting dialog as the player's
      // (removed — hosting is GO LIVE only). Close still works.
      final calls = _Calls();
      await _pumpPanel(tester, calls, searchQuery: '');
      expect(find.byIcon(Icons.settings), findsNothing);
      // With an empty query the header X is the only close icon.
      await tester.tap(find.byIcon(Icons.close));
      expect(calls.closes, 1);
    });

    testWidgets('Local Upload fires onUpload', (tester) async {
      final calls = _Calls();
      await _pumpPanel(tester, calls);
      await tester.tap(find.text('Local Upload'));
      expect(calls.uploads, 1);
    });
  });

  group('narrow surface', () {
    testWidgets('320 px wide renders without overflow', (tester) async {
      final calls = _Calls();
      const nowPlaying = LibrarySong(
        key: 'file:/music/river-road.mp3',
        title: 'River Road',
        artist: 'Sara Khan',
        isPlaying: true,
        statusLine: _statusLine,
      );
      await _pumpPanel(tester, calls,
          songs: const [_songA, _songB, _songC],
          nowPlaying: nowPlaying,
          surface: const Size(320, 640));
      expect(find.text('River Road'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
