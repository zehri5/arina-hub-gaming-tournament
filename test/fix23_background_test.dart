// FIX 23 — APP-WIDE BACKGROUND (items 21, 22).
// The bundled cleaned artwork is the default app-wide background
// (dark scrim for readability); a remote URL from app_settings
// overrides it when set and loadable; unset/bad URL falls back
// to the bundled default; light mode keeps the plain light color.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';

import 'audio_test_helpers.dart';

void main() {
  group('fix23 item 21 — bundled asset (source)', () {
    test('asset file exists and is declared in pubspec', () {
      // Binary file: readAsStringSync would throw, so check the
      // file directly (same project-root resolution as
      // requireProjectFile).
      final asset =
          File('${findProjectRoot().path}/assets/images/app_background.png');
      expect(asset.existsSync(), isTrue);
      expect(asset.lengthSync(), greaterThan(0));
      final pubspec = requireProjectFile('pubspec.yaml');
      expect(pubspec, contains('- assets/images/app_background.png'));
      expect(AppBackgroundLayer.defaultAsset,
          'assets/images/app_background.png');
    });

    test('superseded background assets are NOT bundled', () {
      final pubspec = requireProjectFile('pubspec.yaml');
      expect(pubspec, isNot(contains('app_background_no_logo')));
      expect(pubspec, isNot(contains('1000050456')));
    });

    test('main.dart boot fetch sets the remote background URL', () {
      final main = codeOnly(requireProjectFile('lib/main.dart'));
      expect(main, contains('SupaDb.appBackgroundUrl.value ='));
      expect(main, contains('appBackgroundUrlFromSettings(settings)'));
      expect(main, contains('AppBackgroundLayer('));
    });

    test('ArenaBackground renders the app-wide layer', () {
      final ui = codeOnly(requireProjectFile('lib/widgets/arena_ui.dart'));
      expect(ui, contains('class ArenaBackground'));
      expect(ui, contains('AppBackgroundLayer'));
    });
  });

  group('fix23 item 22 — settings helpers (unit)', () {
    test('appBackgroundUrlFromSettings reads theme.app_background_url', () {
      expect(
          SupaDb.appBackgroundUrlFromSettings({
            'theme': {'app_background_url': 'https://x.example/bg.jpg'}
          }),
          'https://x.example/bg.jpg');
      expect(SupaDb.appBackgroundUrlFromSettings({'theme': {}}), '');
      expect(SupaDb.appBackgroundUrlFromSettings({}), '');
      expect(SupaDb.appBackgroundUrlFromSettings({'theme': null}), '');
    });

    // FIX 32 (2026-11-24): themeWithBackground + the admin theme
    // page tests are gone with the panel (AdminDbSystem deleted).
    // The user app only READS the background URL (test above).
  });

  group('fix23 items 21+22 — AppBackgroundLayer widget', () {
    HttpOverrides? prevOverrides;

    setUp(() {
      prevOverrides = HttpOverrides.current;
      SupaDb.appBackgroundUrl.value = '';
      themeLightNotifier.value = false;
      // The cache manager looks up its store via path_provider
      // before downloading — mock the channel so remote loads can
      // proceed in tests (it uses the support dir, not temp).
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (MethodCall call) async {
        if (call.method == 'getTemporaryDirectory' ||
            call.method == 'getApplicationSupportDirectory') {
          return '/tmp';
        }
        return null;
      });
    });

    tearDown(() {
      HttpOverrides.global = prevOverrides;
      SupaDb.appBackgroundUrl.value = '';
      themeLightNotifier.value = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'), null);
    });

    Future<void> pumpLayer(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                AppBackgroundLayer(),
                Center(child: Text('content')),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('default: bundled asset image + 0.55 scrim',
        (tester) async {
      await pumpLayer(tester);
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<AssetImage>());
      expect((image.image as AssetImage).assetName,
          AppBackgroundLayer.defaultAsset);
      final scrim = tester.widget<Container>(
          find.byKey(const ValueKey('app_bg_scrim')));
      expect(scrim.color, Colors.black.withValues(alpha: 0.55));
      expect(find.text('content'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('remote URL set: network image used', (tester) async {
      HttpOverrides.global = _MockHttpOverrides();
      SupaDb.appBackgroundUrl.value = 'https://x.example/bg.jpg';
      await pumpLayer(tester);
      // Let the precache chain finish (store open + download +
      // cache write) so the 8s timeout timer is cancelled.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<CachedNetworkImageProvider>());
      expect((image.image as CachedNetworkImageProvider).url,
          'https://x.example/bg.jpg');
      expect(tester.takeException(), isNull);
    });

    testWidgets('bad URL: falls back to the bundled default',
        (tester) async {
      HttpOverrides.global = _FailingHttpOverrides();
      SupaDb.appBackgroundUrl.value = 'https://bad.example/bg.jpg';
      await pumpLayer(tester);
      // The cache manager swallows download errors (its stream
      // never errors), so the fallback is the precache timeout
      // (8s): advance fake time past it and the bundled default
      // must take over.
      await tester.pump(const Duration(seconds: 9));
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<AssetImage>());
      expect((image.image as AssetImage).assetName,
          AppBackgroundLayer.defaultAsset);
      expect(tester.takeException(), isNull);
    });

    testWidgets('light mode: solid light color, no image', (tester) async {
      themeLightNotifier.value = true;
      await pumpLayer(tester);
      expect(find.byType(Image), findsNothing);
      expect(find.text('content'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('respectLightMode false: image even in light mode',
        (tester) async {
      themeLightNotifier.value = true;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [AppBackgroundLayer(respectLightMode: false)],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// Serves a 1x1 PNG for any URL (copied from
/// test/listeners_detail_test.dart).
class _MockHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _MockHttpClient();
}

class _MockHttpClient extends Fake implements HttpClient {
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

  // The cache manager reads these during download; a Fake throws
  // UnimplementedError for any unimplemented member, which the
  // manager swallows — stalling the precache forever.
  @override
  HttpHeaders get headers => _MockHttpHeaders();

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => false;

  @override
  String get reasonPhrase => 'OK';

  @override
  List<Cookie> get cookies => [];

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

/// Every request fails (unreachable remote background).
class _FailingHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FailingHttpClient();
}

class _FailingHttpClient extends Fake implements HttpClient {
  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      throw const SocketException('unreachable');
}
