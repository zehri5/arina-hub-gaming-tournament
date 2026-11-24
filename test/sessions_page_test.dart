// SessionsPage (#31, 2026-11-22) — tests.
//
// Proves, with NO network and NO real Supabase (SupaDb.testFixtures
// seam + SharedPreferences mock):
//   1. a session row whose device_id matches this install gets the
//      gold "This Device" pill; other rows do not;
//   2. recorded device_name / device_type / location / last_active_at
//      render; a legacy row without the 078 columns degrades honestly
//      to "Unknown device" / "Unknown location" (never invented);
//   3. zero rows render the honest empty state, not a crash.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/sessions_page.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'device_id': 'dev-this'});
  });

  tearDown(() {
    SupaDb.testFixtures = null;
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SessionsPage(uid: 'u1')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('matching device_id gets the This Device pill; legacy row degrades honestly',
      (tester) async {
    SupaDb.testFixtures = {
      'login_sessions': [
        {
          'firebase_uid': 'u1',
          'device_id': 'dev-this',
          'device_name': 'android 12',
          'device_type': 'android',
          'location': 'Karachi, Pakistan',
          'last_active_at': '2026-11-22T10:00:00.000Z',
          'created_at': '2026-11-22T10:00:00.000Z',
        },
        {
          'firebase_uid': 'u1',
          'created_at': '2026-11-21T09:00:00.000Z',
        },
      ],
    };
    await pumpPage(tester);
    expect(find.text('LOGIN SESSIONS'), findsOneWidget);
    expect(find.text('This Device'), findsOneWidget);
    expect(find.text('android 12'), findsOneWidget);
    expect(find.text('android • Karachi, Pakistan'), findsOneWidget);
    expect(find.text('Unknown device'), findsOneWidget);
    expect(find.text('Unknown location'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('zero sessions render the honest empty state', (tester) async {
    SupaDb.testFixtures = {'login_sessions': []};
    await pumpPage(tester);
    expect(
      find.text(
        'No previous logins recorded yet — logins from now on will appear here.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
