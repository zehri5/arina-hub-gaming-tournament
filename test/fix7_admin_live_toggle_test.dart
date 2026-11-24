// FIX 7 ADMIN PANEL LIVE ON/OFF TOGGLE (Sameer's order 2026-11-22
// 23:11, voice call — pakka hukm): link + on/off sab kuch Admin
// Panel ke andar se hona chahiye, bahar se (backend/SQL) nahi.
//
// FIX 32 (2026-11-24, admin-panel removal): the admin form, the
// detail view and the step-5 validator groups are GONE with the
// panel. What REMAINS is the service layer — AdminDbTournaments
// (kept: the organizer builder uses it) must still carry
// `show_watch_live` in its create/update paths, or the flag can
// never become true from the user app either.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String rel) => File('test/../$rel').readAsStringSync();

/// Source with full-line comments stripped, so a mention inside a
/// comment never counts as code.
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
  late String service;
  late String serviceCode;

  setUpAll(() {
    service = _read('lib/services/admin_db_tournaments.dart');
    serviceCode = _codeOnly(service);
  });

  group('service source pins', () {
    test('create restore map carries show_watch_live', () {
      final restore = _region(
        serviceCode,
        'final extended = <String, dynamic>{',
        'for (final e in extended.entries)',
      );
      expect(
        restore,
        contains("'show_watch_live': row['show_watch_live']"),
      );
    });

    test('update extendedKeys carries show_watch_live', () {
      final keys = _region(
        serviceCode,
        'const extendedKeys = {',
        '};',
      );
      expect(keys, contains("'show_watch_live'"));
    });

    test('stale v2013 "NO show_watch_live" guards are gone', () {
      expect(serviceCode, isNot(contains('NO show_watch_live')));
    });
  });

}
