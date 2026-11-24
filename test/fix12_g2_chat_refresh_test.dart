// FIX 12 G2 (2026-11-23) — community chat refresh (§2 of
// COMMUNITY-CLAN-FIX-2026-11-23): the sender never saw their own
// message because CommunityGroups.streamCommunityChat called
// SupaDb.streamList WITHOUT pollInterval, and A1 has NO Realtime
// (404) — so the stream never refetched after its first load.
// Fix: streamCommunityChat passes pollInterval: 3 s (the exact
// O-2 pattern streamChat already uses).
//
// These tests are NON-VACUOUS: the behavioural test subscribes to
// the REAL streamCommunityChat and counts emissions over >3 s —
// with the poll it emits at least twice (initial fetch + one
// refetch); if pollInterval is removed it emits exactly once and
// the test FAILS. The static pin fails the same way (0 matches).
//
// Plain test() with REAL timers — NOT testWidgets: fake async
// deadlocks on the Realtime socket (same reason as
// supabase_a1_switch_test.dart). A recording HTTP client stands
// in for the network, so no live server is needed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:protournament_user/community_service.dart';
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
      accessToken: () async => null,
      httpClient: recording,
    );
  });

  tearDown(() {
    SupaDb.testFixtures = null;
  });

  test('streamCommunityChat refetches on a 3 s poll (sender sees own message)', () async {
    final events = <List<Map<String, dynamic>>>[];
    final sub = CommunityGroups.streamCommunityChat('community-1').listen(events.add);
    // Initial fetch + one full 3 s poll cycle (plus margin).
    await Future.delayed(const Duration(milliseconds: 4200));
    await sub.cancel();
    // Without pollInterval this is exactly 1 (initial fetch only)
    // and the test FAILS — that is the §2 bug.
    expect(events.length, greaterThanOrEqualTo(2));
  });

  test('streamCommunityChat polls the community chat query, not another table', () async {
    recording.requests.clear();
    final sub = CommunityGroups.streamCommunityChat('community-9').listen((_) {});
    await Future.delayed(const Duration(milliseconds: 4200));
    await sub.cancel();
    final rest = recording.requests.where((r) => r.url.path.contains('/rest/v1/chat_messages')).toList();
    // Initial fetch + at least one poll refetch, all scoped to the
    // community chat query (scope=eq.community, community_id=eq.<id>).
    expect(rest.length, greaterThanOrEqualTo(2));
    for (final r in rest) {
      expect(r.url.queryParameters['scope'], 'eq.community');
      expect(r.url.queryParameters['community_id'], 'eq.community-9');
    }
  });

  test('streamCommunityChat passes a 3 s pollInterval (static pin)', () {
    final src = File('lib/community_service.dart').readAsStringSync();
    final at = src.indexOf('static Stream<List<Map<String, dynamic>>> streamCommunityChat(');
    expect(at, isNot(-1));
    final block = src.substring(at, at + 1500);
    final polls = 'pollInterval: const Duration(seconds: 3)'.allMatches(block).length;
    expect(polls, 1);
  });

  test('streamCommunityChat with an empty community id emits [] immediately', () async {
    final events = await CommunityGroups.streamCommunityChat('').toList();
    expect(events, [
      <Map<String, dynamic>>[],
    ]);
  });
}
