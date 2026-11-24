// TEAMS FIXES 5 + 7 (2026-11-21, user order from the My Team
// screenshot 1000049110_40_2z5i.jpg):
//
// 5a — the team card read as BLACK. The header/list/invite/roster
// cards were already MockupCard (verified by pixel sampling the
// screenshot: the card fill IS the #1D2029 -> #15181F gradient);
// the black slab was the stats strip inside the header, filled
// with kField (#10131A). The strip now carries the kCard gradient.
// These tests pin the header card as a MockupCard and pin that no
// kField-filled container survives inside it.
// 5b — "TEAM HISTORY" ran OUTSIDE its button on the right. Fix:
// smaller font (13) + tighter padding (12) + a FittedBox inside
// _goldOutlineBtn, so the label shrinks instead of overflowing.
// Labels stay EXACTLY "EDIT TEAM" / "TEAM HISTORY".
// 7 — team photo upload (captain only). No `photo_url` column
// exists on `teams` in the code's reads/writes, so the URL is
// persisted device-locally (SharedPreferences, keyed by team id)
// and the resolver prefers the server value once the backend adds
// the column (BACKEND ADDENDUM: `photo_url` text on `teams`).
//
// What is NOT covered here (needs the phone / live backend): the
// actual gallery pick + ImgBB upload + server write in
// _changeTeamPhoto, and the rendered photo pixels — the resolver,
// the prefs round-trip, the captain gating and the overflow
// behaviour are what is unit-testable.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/cached_image.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _teamRow({String? photoUrl}) => {
      'id': 'team-1',
      'name': 'my team 1',
      'tag': 'MT1',
      'game': 'PUBG Mobile',
      'is_clan': false,
      'captain_uid': 'captain-uid',
      'captain_name': 'sameer',
      'invite_code': 'C6POF3',
      if (photoUrl != null) 'photo_url': photoUrl,
    };

/// Pumps [TeamDetailPage] and lets its defensive _load finish
/// (every SupaDb getter swallows errors, so with no backend the
/// page renders the header with an empty roster). No pumpAndSettle
/// — MockupCard's shine controllers repeat forever.
Future<void> _pumpTeamDetail(WidgetTester tester, {required String uid, Map<String, dynamic>? team}) async {
  await tester.pumpWidget(
    MaterialApp(home: TeamDetailPage(team: team ?? _teamRow(), uid: uid)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('FIX 7 — resolveTeamPhotoUrl', () {
    test('prefers the server value over the local fallback', () {
      expect(
        resolveTeamPhotoUrl(serverUrl: 'https://i.ibb.co/server.jpg', localUrl: 'https://i.ibb.co/local.jpg'),
        'https://i.ibb.co/server.jpg',
      );
    });

    test('falls back to the local URL when the server has none', () {
      expect(resolveTeamPhotoUrl(serverUrl: '', localUrl: 'https://i.ibb.co/local.jpg'), 'https://i.ibb.co/local.jpg');
      expect(resolveTeamPhotoUrl(localUrl: 'https://i.ibb.co/local.jpg'), 'https://i.ibb.co/local.jpg');
    });

    test('empty when neither exists', () {
      expect(resolveTeamPhotoUrl(), '');
      expect(resolveTeamPhotoUrl(serverUrl: '', localUrl: ''), '');
    });

    test('prefs key is namespaced per team', () {
      expect(teamPhotoPrefsKey('team-1'), 'team_photo_team-1');
      expect(teamPhotoPrefsKey('team-2'), isNot(teamPhotoPrefsKey('team-1')));
    });
  });

  group('FIX 7 — device-local photo persistence', () {
    test('save/load round-trip keyed by team id', () async {
      await saveTeamPhotoLocal('team-1', 'https://i.ibb.co/team1.jpg');
      expect(await loadTeamPhotoLocal('team-1'), 'https://i.ibb.co/team1.jpg');
      // Another team is untouched.
      expect(await loadTeamPhotoLocal('team-2'), '');
    });

    test('unknown team loads empty, never throws', () async {
      expect(await loadTeamPhotoLocal('no-such-team'), '');
      expect(await loadTeamPhotoLocal(''), '');
    });
  });

  group('FIX 5b — TeamActionButtons fit at phone widths', () {
    Future<List<FlutterErrorDetails>> pumpRow(WidgetTester tester, double width, {bool isCaptain = true}) async {
      final errors = <FlutterErrorDetails>[];
      final oldOnError = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = oldOnError);
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              // Same insets as the real detail page: 16 page padding
              // + 14 card padding around the buttons row.
              padding: const EdgeInsets.all(16),
              child: MockupCard(
                padding: const EdgeInsets.all(14),
                animate: false,
                sparks: false,
                child: TeamActionButtons(isCaptain: isCaptain, onEdit: () {}, onHistory: () {}),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return errors;
    }

    for (final width in [360.0, 400.0]) {
      testWidgets('both labels fully visible, no overflow at ${width.toInt()}dp', (tester) async {
        final errors = await pumpRow(tester, width);
        expect(find.text('EDIT TEAM'), findsOneWidget);
        expect(find.text('TEAM HISTORY'), findsOneWidget);
        final overflows = errors.where((e) => e.exception.toString().contains('overflowed')).toList();
        expect(overflows, isEmpty, reason: 'no RenderFlex overflow may be reported at ${width.toInt()}dp');
      });
    }

    testWidgets('labels use the smaller 13sp font (fit by shrinking, not by shortening)', (tester) async {
      await pumpRow(tester, 360);
      expect(tester.widget<Text>(find.text('EDIT TEAM')).style?.fontSize, 13);
      expect(tester.widget<Text>(find.text('TEAM HISTORY')).style?.fontSize, 13);
      // Labels unchanged, exactly as the user ordered.
      expect(find.text('EDIT TEAM'), findsOneWidget);
      expect(find.text('TEAM HISTORY'), findsOneWidget);
    });

    testWidgets('EDIT TEAM is disabled for non-captains, HISTORY stays open', (tester) async {
      await pumpRow(tester, 360, isCaptain: false);
      final editBtn = tester.widget<OutlinedButton>(
        find.ancestor(of: find.text('EDIT TEAM'), matching: find.byType(OutlinedButton)),
      );
      final historyBtn = tester.widget<OutlinedButton>(
        find.ancestor(of: find.text('TEAM HISTORY'), matching: find.byType(OutlinedButton)),
      );
      expect(editBtn.onPressed, isNull);
      expect(historyBtn.onPressed, isNotNull);
    });
  });

  group('FIX 7 — TeamPhotoBadge', () {
    Future<void> pumpBadge(WidgetTester tester, {String? photoUrl, required bool isCaptain, bool busy = false}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TeamPhotoBadge(photoUrl: photoUrl, isCaptain: isCaptain, onChangePhoto: () {}, busy: busy),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('captain sees the camera affordance, non-captain does not', (tester) async {
      await pumpBadge(tester, isCaptain: true);
      expect(find.byIcon(Icons.camera_alt), findsOneWidget);
      await pumpBadge(tester, isCaptain: false);
      expect(find.byIcon(Icons.camera_alt), findsNothing);
    });

    testWidgets('no photo yet shows the gold shield, no image widget', (tester) async {
      await pumpBadge(tester, isCaptain: false);
      expect(find.byIcon(Icons.shield), findsOneWidget);
      expect(find.byType(ArenaCachedImage), findsNothing);
    });

    testWidgets('uploaded photo renders the cached image with the photo URL', (tester) async {
      await pumpBadge(tester, photoUrl: 'https://i.ibb.co/team1.jpg', isCaptain: false);
      final img = tester.widget<ArenaCachedImage>(find.byType(ArenaCachedImage));
      expect(img.imageUrl, 'https://i.ibb.co/team1.jpg');
      expect(img.placeholderIcon, Icons.shield);
    });

    testWidgets('busy swaps the camera icon for a spinner', (tester) async {
      await pumpBadge(tester, isCaptain: true, busy: true);
      expect(find.byIcon(Icons.camera_alt), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('FIX 5a + 7 — TeamDetailPage header', () {
    testWidgets('header card is a MockupCard and no kField (near-black) fill survives inside it', (tester) async {
      await _pumpTeamDetail(tester, uid: 'captain-uid');
      expect(find.text('my team 1'), findsOneWidget);
      final headerCards = find.ancestor(of: find.text('my team 1'), matching: find.byType(MockupCard));
      expect(headerCards, findsOneWidget);
      // Every Container inside the header card: none may carry the
      // near-black kField fill (the old stats strip did).
      final containers = tester.widgetList<Container>(
        find.descendant(of: headerCards, matching: find.byType(Container)),
      );
      for (final c in containers) {
        final d = c.decoration;
        if (d is BoxDecoration) {
          expect(d.color, isNot(kField), reason: 'no near-black kField fill inside the team card');
        }
      }
      // The stats strip (ancestor of the Members label) carries
      // the FIX 23 item-23 card gradient now (purple fill at
      // 0.48 opacity — the old kCard greys are gone).
      final strip = tester.widgetList<Container>(
        find.ancestor(of: find.text('Members'), matching: find.byType(Container)),
      );
      expect(
        strip.any((c) {
          final d = c.decoration;
          return d is BoxDecoration &&
              d.gradient is LinearGradient &&
              (d.gradient as LinearGradient)
                  .colors
                  .contains(kCardPurpleTop.withValues(alpha: kCardFillOpacity)) &&
              (d.gradient as LinearGradient).colors.contains(
                  kCardPurpleBottom.withValues(alpha: kCardFillOpacity));
        }),
        isTrue,
        reason: 'stats strip uses the item-23 card gradient',
      );
    });

    testWidgets('captain sees the photo-change affordance on the header', (tester) async {
      await _pumpTeamDetail(tester, uid: 'captain-uid');
      expect(find.text('my team 1'), findsOneWidget);
      expect(find.byIcon(Icons.camera_alt), findsOneWidget);
    });

    testWidgets('non-captain member sees no photo-change affordance', (tester) async {
      await _pumpTeamDetail(tester, uid: 'someone-else');
      expect(find.text('my team 1'), findsOneWidget);
      expect(find.byIcon(Icons.camera_alt), findsNothing);
    });

    testWidgets('server photo_url in the team row shows the photo on the header', (tester) async {
      await _pumpTeamDetail(tester, uid: 'captain-uid', team: _teamRow(photoUrl: 'https://i.ibb.co/server.jpg'));
      expect(find.text('my team 1'), findsOneWidget);
      final img = tester.widget<ArenaCachedImage>(find.byType(ArenaCachedImage));
      expect(img.imageUrl, 'https://i.ibb.co/server.jpg');
    });
  });
}
