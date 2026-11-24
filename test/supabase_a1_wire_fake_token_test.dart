// O-2 wire test (fake-token case) — separate file because Supabase
// can only be initialized ONCE per isolate: this file initializes
// with an accessToken that returns a fake Firebase token, and pins
// the behaviour that the REST header is STILL '' (the empty
// Authorization override wins over the token — on purpose, see the
// NOTE in main.dart).
import 'dart:async';
import 'dart:convert';

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
      accessToken: () async => 'fake-firebase-token',
      httpClient: recording,
    );
  });

  test('wire: with a fake Firebase token, REST Authorization is still empty', () async {
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
}
