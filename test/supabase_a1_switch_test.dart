// O-2 / A1 SWITCH (2026-11-22) — the app talks to the self-hosted
// server at api.appfixguru.com, NOT the old Supabase cloud:
//   1. kSupabaseUrl points at A1.
//   2. streamList poll: with pollInterval, the list refetches on a
//      timer (the self-hosted server has no Realtime relay).
//   3. Cancelling a polling stream stops the timer (no leak).
//   4. Wire: signed-out REST sends `Authorization: ''` + apikey —
//      the empty override is load-bearing (A1 answers 401 PGRST301
//      to `Bearer <publishable>`).
//   5. streamChat passes the 3 s poll to every branch (static pin).
//
// Plain test() with REAL timers — NOT testWidgets: fake async
// deadlocks on the Realtime socket. A recording HTTP client stands
// in for the network, so no live server is needed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/supabase_config.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Records every request, answers every REST read with an empty
/// JSON array (so getList returns []).
class _RecordingClient extends http.BaseClient {
  final List<http.BaseRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final body = utf8.encode('[]');
    return http.StreamedResponse(
      Stream.value(body),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  final recording = _RecordingClient();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: kSupabaseUrl,
      publishableKey: kSupabaseAnonKey,
      headers: const {'Authorization': ''},
      // Signed out: no Firebase token (same as the main.dart
      // accessToken callback when currentUser is null).
      accessToken: () async => null,
      httpClient: recording,
    );
  });

  test('A1 URL: app points at api.appfixguru.com', () {
    expect(kSupabaseUrl, 'https://api.appfixguru.com');
  });

  test('streamList poll emits repeatedly on pollInterval', () async {
    final events = <List<Map<String, dynamic>>>[];
    final sub = SupaDb.streamList('app_settings', pollInterval: const Duration(milliseconds: 100)).listen(events.add);
    await Future.delayed(const Duration(milliseconds: 350));
    await sub.cancel();
    expect(events.length, greaterThanOrEqualTo(3));
  });

  test('cancelling a polling stream stops the timer', () async {
    var count = 0;
    final sub = SupaDb.streamList('app_settings', pollInterval: const Duration(milliseconds: 50)).listen((_) => count++);
    await Future.delayed(const Duration(milliseconds: 160));
    expect(count, greaterThanOrEqualTo(2));
    await sub.cancel();
    final atCancel = count;
    await Future.delayed(const Duration(milliseconds: 200));
    expect(count, atCancel);
  });

  test('wire: signed-out REST sends empty Authorization + apikey', () async {
    recording.requests.clear();
    await SupaDb.getList('app_settings', limit: 1);
    final rest = recording.requests.where((r) => r.url.path.contains('/rest/v1/')).toList();
    expect(rest, isNotEmpty);
    final headers = <String, String>{};
    for (final e in rest.last.headers.entries) {
      headers[e.key.toLowerCase()] = e.value;
    }
    expect(headers['authorization'], '');
    expect(headers['apikey'], kSupabaseAnonKey);
  });

  // Static pin (from the #16 verify round): streamChat must pass
  // the 3 s poll to EVERY branch (squad, team, watch_live,
  // community, tournament) — the self-hosted server has no
  // Realtime relay. The community branch is FIX 12 G6 (the
  // community voice room's MUSIC:: rows — without the poll the
  // room's music stream never refreshes on A1).
  test('streamChat passes a 3 s poll to every branch', () {
    final src = File('lib/services/supabase_db.dart').readAsStringSync();
    final at = src.indexOf('static Stream<List<Map<String, dynamic>>> streamChat(');
    expect(at, isNot(-1));
    final block = src.substring(at, at + 2500);
    final polls = 'pollInterval: const Duration(seconds: 3)'.allMatches(block).length;
    expect(polls, 5); // squad, team, watch_live, community, tournament
  });
}
