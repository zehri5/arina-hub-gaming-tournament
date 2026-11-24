// ARENA HUB #10 AUDIO — Group 9, RJ STUDIO listeners UI:
// listener count row + listeners detail sheet widget tests.
// Presentational only: no Supabase, no Firebase, no LiveKit, no
// real network (avatar URLs are served a 1x1 PNG by a mock
// HttpClient — see _MockHttpOverrides).
//
// Covers: the count row renders with N; tapping it opens the
// detail sheet; the sheet header shows count + peak; rows render
// name/time/avatar; rows sort longest-listening first; the empty
// state ("No listeners yet"); non-host sees the count row but no
// sliders; host sees both; and the listening-since format
// ("just now" / "12 min" / "1h 5m").

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/audio_effects_panel.dart';
import 'package:protournament_user/screens/listeners_detail_sheet.dart';
import 'package:protournament_user/services/live_listeners.dart';
import 'package:protournament_user/theme.dart';

Widget _wrapPanel(Widget child) => MaterialApp(
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: kBg),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// The sheet needs a bounded height from its parent (the modal
/// bottom sheet gives it 70% of the screen).
Widget _wrapSheet(Widget child) => MaterialApp(
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: kBg),
      home: Scaffold(body: SizedBox(height: 600, child: child)),
    );

/// A listener who has been listening for [ago] — the 30s cushion
/// keeps the rendered minute count stable across a minute boundary
/// while the test runs.
RjListener _listener(
  String uid,
  String name,
  Duration ago, [
  String? avatarUrl,
]) =>
    RjListener(
      uid: uid,
      displayName: name,
      listeningSince: DateTime.now().subtract(ago),
      avatarUrl: avatarUrl,
    );

/// Serves a 1x1 transparent PNG for every HTTP request, so avatar
/// URLs load in tests without touching the network.
class _MockHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _MockHttpClient();
}

class _MockHttpClient extends Fake implements HttpClient {
  // NetworkImage sets this on the shared client at first use.
  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _MockHttpClientRequest();
}

class _MockHttpClientRequest extends Fake implements HttpClientRequest {
  @override
  HttpHeaders get headers => _MockHttpHeaders();

  @override
  Future<HttpClientResponse> close() async => _MockHttpClientResponse();
}

class _MockHttpHeaders extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}
}

class _MockHttpClientResponse extends Fake implements HttpClientResponse {
  static final List<int> _pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  );

  @override
  int get statusCode => 200;

  @override
  int get contentLength => _pngBytes.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.fromIterable([_pngBytes]).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
}

void main() {
  // Dart 3.14: HttpOverrides.global is a setter only (no getter),
  // so there is no previous value to restore — null is the default.
  setUp(() {
    HttpOverrides.global = _MockHttpOverrides();
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  testWidgets('count row renders the live count in gold', (tester) async {
    await tester.pumpWidget(
      _wrapPanel(const AudioEffectsPanel(isHost: true, listenerCount: 128)),
    );
    await tester.pump();

    expect(find.byKey(const Key('listener-count-row')), findsOneWidget);
    expect(find.text('128 listening'), findsOneWidget);
    expect(find.byIcon(Icons.headphones), findsOneWidget);
    final text = tester.widget<Text>(find.text('128 listening'));
    expect(text.style?.color, kGold);
  });

  testWidgets('tapping the count row opens the detail sheet', (tester) async {
    await tester.pumpWidget(
      _wrapPanel(
        AudioEffectsPanel(
          isHost: true,
          listenerCount: 128,
          peakListeners: 214,
          listeners: [
            _listener(
              'u1',
              'Ayesha Khan',
              const Duration(minutes: 12, seconds: 30),
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.text('LISTENERS - 128'), findsNothing);
    await tester.tap(find.byKey(const Key('listener-count-row')));
    await tester.pumpAndSettle();

    expect(find.text('LISTENERS - 128'), findsOneWidget);
    expect(find.text('Peak: 214'), findsOneWidget);
    expect(find.text('Ayesha Khan - 12 min'), findsOneWidget);
  });

  testWidgets('sheet header shows count + peak', (tester) async {
    await tester.pumpWidget(
      _wrapSheet(
        const ListenersDetailSheet(
          listeners: [],
          listenerCount: 128,
          peakListeners: 214,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('LISTENERS - 128'), findsOneWidget);
    expect(find.text('Peak: 214'), findsOneWidget);
  });

  testWidgets('rows render name, time and avatar', (tester) async {
    await tester.pumpWidget(
      _wrapSheet(
        ListenersDetailSheet(
          listeners: [
            _listener(
              'u1',
              'Ayesha Khan',
              const Duration(minutes: 12, seconds: 30),
              'https://example.com/ayesha.jpg',
            ),
            _listener(
              'u2',
              'Bilal Ahmed',
              const Duration(minutes: 8, seconds: 30),
            ),
          ],
          listenerCount: 2,
          peakListeners: 9,
        ),
      ),
    );
    await tester.pump();
    // Let the (mocked) avatar image resolve.
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Ayesha Khan - 12 min'), findsOneWidget);
    expect(find.text('Bilal Ahmed - 8 min'), findsOneWidget);
    expect(find.byType(CircleAvatar), findsNWidgets(2));
    // Photo listener: NetworkImage with the profile URL.
    final photoAvatar = tester.widget<CircleAvatar>(
      find.byKey(const Key('listener-avatar-u1')),
    );
    final image = photoAvatar.backgroundImage;
    expect(image, isA<NetworkImage>());
    expect((image as NetworkImage).url, 'https://example.com/ayesha.jpg');
    // No-photo listener: initial circle ("B" for Bilal).
    expect(find.text('B'), findsOneWidget);
    expect(find.byIcon(Icons.volume_up), findsNWidgets(2));
  });

  testWidgets('rows sort longest-listening first', (tester) async {
    await tester.pumpWidget(
      _wrapSheet(
        ListenersDetailSheet(
          listeners: [
            _listener(
              'u3',
              'Hassan Raza',
              const Duration(minutes: 2, seconds: 30),
            ),
            _listener(
              'u1',
              'Ayesha Khan',
              const Duration(minutes: 12, seconds: 30),
            ),
            _listener(
              'u2',
              'Usman Tariq',
              const Duration(minutes: 5, seconds: 30),
            ),
          ],
          listenerCount: 3,
          peakListeners: 9,
        ),
      ),
    );
    await tester.pump();

    // Longest first on screen: 12 min above 5 min above 2 min.
    final topAyesha = tester.getTopLeft(find.text('Ayesha Khan - 12 min')).dy;
    final topUsman = tester.getTopLeft(find.text('Usman Tariq - 5 min')).dy;
    final topHassan = tester.getTopLeft(find.text('Hassan Raza - 2 min')).dy;
    expect(topAyesha, lessThan(topUsman));
    expect(topUsman, lessThan(topHassan));
  });

  testWidgets('empty state: no listeners yet', (tester) async {
    await tester.pumpWidget(
      _wrapSheet(
        const ListenersDetailSheet(
          listeners: [],
          listenerCount: 0,
          peakListeners: 0,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('No listeners yet'), findsOneWidget);
    expect(find.byType(CircleAvatar), findsNothing);
  });

  testWidgets('empty state via the panel: tap with no listeners', (
    tester,
  ) async {
    await tester.pumpWidget(_wrapPanel(const AudioEffectsPanel(isHost: true)));
    await tester.pump();

    expect(find.text('0 listening'), findsOneWidget);
    await tester.tap(find.byKey(const Key('listener-count-row')));
    await tester.pumpAndSettle();

    expect(find.text('LISTENERS - 0'), findsOneWidget);
    expect(find.text('Peak: 0'), findsOneWidget);
    expect(find.text('No listeners yet'), findsOneWidget);
  });

  testWidgets('non-host sees the count row but no sliders', (tester) async {
    await tester.pumpWidget(
      _wrapPanel(
        AudioEffectsPanel(
          isHost: false,
          listenerCount: 128,
          peakListeners: 214,
          listeners: [
            _listener(
              'u1',
              'Ayesha Khan',
              const Duration(minutes: 12, seconds: 30),
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.text('128 listening'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.text('Preset'), findsNothing);
    // ...and a listener can still open the sheet from the count row.
    await tester.tap(find.byKey(const Key('listener-count-row')));
    await tester.pumpAndSettle();
    expect(find.text('LISTENERS - 128'), findsOneWidget);
    expect(find.text('Ayesha Khan - 12 min'), findsOneWidget);
  });

  testWidgets('host sees both the count row and the console', (tester) async {
    await tester.pumpWidget(
      _wrapPanel(const AudioEffectsPanel(isHost: true, listenerCount: 128)),
    );
    await tester.pump();

    expect(find.text('RJ STUDIO'), findsOneWidget);
    expect(find.text('128 listening'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(7));
    expect(find.text('Noise gate'), findsOneWidget);
  });

  group('formatListeningSince', () {
    test('under 1 minute reads "just now"', () {
      final now = DateTime(2026, 11, 22, 19, 30);
      expect(
        formatListeningSince(
          now.subtract(const Duration(seconds: 30)),
          now: now,
        ),
        'just now',
      );
      expect(formatListeningSince(now, now: now), 'just now');
      // A future timestamp (clock skew) also reads as "just now".
      expect(
        formatListeningSince(now.add(const Duration(seconds: 10)), now: now),
        'just now',
      );
    });

    test('under 1 hour reads "N min"', () {
      final now = DateTime(2026, 11, 22, 19, 30);
      expect(
        formatListeningSince(
          now.subtract(const Duration(minutes: 12)),
          now: now,
        ),
        '12 min',
      );
      expect(
        formatListeningSince(
          now.subtract(const Duration(minutes: 1)),
          now: now,
        ),
        '1 min',
      );
      expect(
        formatListeningSince(
          now.subtract(const Duration(minutes: 59, seconds: 59)),
          now: now,
        ),
        '59 min',
      );
    });

    test('1 hour or more reads "1h 5m" style', () {
      final now = DateTime(2026, 11, 22, 19, 30);
      expect(
        formatListeningSince(
          now.subtract(const Duration(hours: 1, minutes: 5)),
          now: now,
        ),
        '1h 5m',
      );
      expect(
        formatListeningSince(now.subtract(const Duration(hours: 2)), now: now),
        '2h',
      );
      expect(
        formatListeningSince(
          now.subtract(const Duration(hours: 1, minutes: 59)),
          now: now,
        ),
        '1h 59m',
      );
    });
  });
}
