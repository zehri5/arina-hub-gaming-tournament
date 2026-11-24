// v2015 (2026-11-22) — BACKEND MOVE (user order 07:23): the app
// talks to the project's own server (api.appfixguru.com) instead
// of Supabase cloud, and the Authorization header goes out EMPTY
// (the new server answers 401 to the anon-key Bearer token).
//
// Mechanism (verified by reading supabase-2.14.0): the client's
// AuthHttpClient only ADDS Authorization when the header is absent
// (putIfAbsent) — a header already present, even empty, is never
// overwritten with the Bearer token. The apikey header still flows
// (putIfAbsent adds it), and Realtime reads the empty header as an
// empty access token. These tests pin the URL, the untouched anon
// key, the headers line at init, and the runtime result: a client
// built from the real config carries an empty Authorization in its
// own header map AND in the REST client's headers (which is what
// every from()/rpc() query builder inherits).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/supabase_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('Backend move — new server, empty Authorization', () {
    test('config points at api.appfixguru.com, not Supabase cloud', () {
      final src = _read('lib/supabase_config.dart');
      // Scope to the constant itself — the file's comment names the
      // old URL for history, which is fine.
      final urlLine =
          src.split('\n').firstWhere((l) => l.contains('kSupabaseUrl ='));
      expect(urlLine, contains("'https://api.appfixguru.com'"));
      expect(urlLine, isNot(contains('supabase.co')));
      expect(kSupabaseUrl, 'https://api.appfixguru.com');
    });

    test('anon key line is untouched', () {
      final src = _read('lib/supabase_config.dart');
      expect(
          src,
          contains(
              "kSupabaseAnonKey = 'sb_publishable_Udf0OJ30kDpHOLq2taGnyw_inw0EjSt'"));
    });

    test('Supabase.initialize passes an empty Authorization header', () {
      final src = _read('lib/main.dart');
      final at = src.indexOf('Supabase.initialize(');
      expect(at, isNot(-1));
      final block = src.substring(at, at + 400);
      expect(block, contains("headers: const {'Authorization': ''}"));
      expect(block, contains('url: kSupabaseUrl'));
      expect(block, contains('publishableKey: kSupabaseAnonKey'));
    });

    test('a client built from the real config carries empty Authorization',
        () async {
      final client = SupabaseClient(
        kSupabaseUrl,
        kSupabaseAnonKey,
        headers: const {'Authorization': ''},
      );
      addTearDown(() async => client.dispose());
      // The client's own header map (source of every sub-client).
      expect(client.headers['Authorization'], '');
      // The REST client every from()/rpc() inherits its headers
      // from — empty here means AuthHttpClient's putIfAbsent never
      // adds the Bearer token to any data request.
      expect(client.rest.headers['Authorization'], '');
      // The URL really moved: REST + Realtime derive from it.
      expect(client.rest.url, startsWith('https://api.appfixguru.com'));
    });
  });
}
