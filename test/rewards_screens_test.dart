// Community Rewards #35 (mockup 973914189) — 2026-11-21 rework.
//
// Pins the mockup side-by-side fixes (user voice call 2026-11-21
// ~22:43 PKT): the level ring is REAL progress against the OD-03
// curve (level x 100 PTS) — 0 points is an EMPTY ring, never a full
// one; "Next Lv. N+1 at X PTS" under the ring; the three named
// milestone badges (Elite / Squad Champion / Master) with states
// from real stats; challenge/achievement rows from the real catalogs
// with Claim wired to the real claim_reward RPC only.
//
// Pure math tests run with NO network. Widget tests pump the real
// page against SupaDb.testFixtures (the FIX 6 seam) — no Supabase
// connection is needed; getPointsTotal falls back to 0 in tests
// because the uninitialised client throws inside its try/catch.
// No pumpAndSettle: ArenaEmberDots + MockupCard repeat forever, so
// tests pump manually and assert takeException() is null (that is
// also the no-overflow / no-cut check — a RenderFlex overflow
// surfaces as an exception here).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:protournament_user/screens/rewards_screens.dart';
import 'package:protournament_user/services/supabase_db.dart';

void main() {
  tearDown(() {
    SupaDb.testFixtures = null;
  });

  group('communityLevelTarget / communityNextLevel (OD-03 curve)', () {
    test('next level needs level x 100 PTS', () {
      expect(communityLevelTarget(1), 100);
      expect(communityLevelTarget(2), 200);
      expect(communityLevelTarget(5), 500);
      // Level 0 / negative is not a real level — clamps to level 1.
      expect(communityLevelTarget(0), 100);
      expect(communityLevelTarget(-3), 100);
    });

    test('next level is level + 1', () {
      expect(communityNextLevel(1), 2);
      expect(communityNextLevel(5), 6);
      expect(communityNextLevel(0), 2);
    });
  });

  group('communityLevelProgress — ring fill', () {
    test('0 points is an EMPTY ring (the reported bug)', () {
      expect(communityLevelProgress(0, 1), 0.0);
      expect(communityLevelProgress(0, 5), 0.0);
    });

    test('partial and full progress', () {
      expect(communityLevelProgress(50, 1), 0.5);
      expect(communityLevelProgress(100, 1), 1.0);
      expect(communityLevelProgress(50, 2), 0.25);
    });

    test('over-target clamps to a full ring', () {
      expect(communityLevelProgress(250, 1), 1.0);
      expect(communityLevelProgress(9999, 3), 1.0);
    });
  });

  group('milestoneProgress — badge states', () {
    test('0 of goal is Locked', () {
      final s = milestoneProgress(0, 10);
      expect(s.unlocked, isFalse);
      expect(s.inProgress, isFalse);
      expect(s.pct, 0);
      expect(s.label, 'Locked');
    });

    test('partial progress shows the real %', () {
      final s = milestoneProgress(4, 5);
      expect(s.unlocked, isFalse);
      expect(s.inProgress, isTrue);
      expect(s.pct, 80);
      expect(s.label, 'In progress | 80%');
    });

    test('at goal is Unlocked', () {
      final s = milestoneProgress(5, 5);
      expect(s.unlocked, isTrue);
      expect(s.pct, 100);
      expect(s.label, 'Unlocked');
    });

    test('over goal stays Unlocked at 100%', () {
      final s = milestoneProgress(12, 10);
      expect(s.unlocked, isTrue);
      expect(s.pct, 100);
    });
  });

  group('LevelRingPainter', () {
    test('carries the real progress; repaint only on progress change', () {
      const p0 = LevelRingPainter(progress: 0.0);
      expect(p0.progress, 0.0);
      expect(p0.shouldRepaint(const LevelRingPainter(progress: 0.0)), isFalse);
      expect(p0.shouldRepaint(const LevelRingPainter(progress: 0.5)), isTrue);
    });
  });

  group('CommunityRewardsPage widget', () {
    Future<void> pumpPage(WidgetTester tester) async {
      // Tall viewport so the whole ListView (hero + both lists +
      // milestones grid) builds without scrolling.
      tester.view.physicalSize = const Size(800, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: CommunityRewardsPage(uid: 'u1'),
        ),
      );
      // Futures resolve on microtasks; a few manual pumps (never
      // pumpAndSettle — the ember dots + card shines repeat).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('empty catalogs: empty states only, Next Lv line, 3 locked badges, no overflow',
        (tester) async {
      SupaDb.testFixtures = {
        'profiles': [
          {'firebase_uid': 'u1', 'level': 1, 'photo_url': '', 'totalMatches': 0, 'wonMatches': 0},
        ],
        'challenges': [],
        'achievements': [],
        'user_achievements': [],
        'challenge_progress': [],
        'match_history': [],
      };
      await pumpPage(tester);
      expect(tester.takeException(), isNull);

      // Header: title present (FittedBox + gap keep it off the avatar).
      expect(find.text('COMMUNITY REWARDS'), findsOneWidget);
      // Hero: real 0 total, real level, OD-03 target for level 1.
      expect(find.text('0 POINTS'), findsOneWidget);
      expect(find.text('LEVEL'), findsOneWidget);
      expect(find.text('Next Lv. 2 at 100 PTS'), findsOneWidget);
      // The ring painter got the real (empty) progress.
      final ringPainters = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).where(
            (p) => p.painter is LevelRingPainter,
          );
      expect(ringPainters.length, 1);
      expect((ringPainters.single.painter as LevelRingPainter).progress, 0.0);
      // Empty states only because the catalogs are truly empty.
      expect(find.text('No challenges yet'), findsOneWidget);
      expect(find.text('No achievements yet'), findsOneWidget);
      // Milestones ALWAYS render (real stats, not the catalog):
      // all three named badges, full names, all Locked at 0 stats.
      expect(find.text('PARTICIPATION MILESTONES'), findsOneWidget);
      expect(find.text('Elite Badge'), findsOneWidget);
      expect(find.text('Squad Champion'), findsOneWidget);
      expect(find.text('Master Badge'), findsOneWidget);
      expect(find.text('Locked'), findsNWidgets(3));
      expect(find.text('Unlocked'), findsNothing);
    });

    testWidgets('real stats drive milestone states (Elite unlocked, Squad Champion 80%, Master locked)',
        (tester) async {
      SupaDb.testFixtures = {
        'profiles': [
          {'firebase_uid': 'u1', 'level': 1, 'photo_url': '', 'totalMatches': 12, 'wonMatches': 4},
        ],
        'challenges': [],
        'achievements': [],
        'user_achievements': [],
        'challenge_progress': [],
        'match_history': [
          for (var i = 0; i < 12; i++)
            {'firebase_uid': 'u1', 'rank': i < 4 ? 1 : 3, 'kills': 2},
        ],
      };
      await pumpPage(tester);
      expect(tester.takeException(), isNull);

      // 12 matches >= 10 -> Elite unlocked (gold, glowing).
      expect(find.text('Elite Badge'), findsOneWidget);
      // 4 wins of 5 -> Squad Champion in progress at 80% — the %
      // shows BOTH in the status line AND on the badge itself.
      expect(find.text('Squad Champion'), findsOneWidget);
      expect(find.text('In progress | 80%'), findsOneWidget);
      expect(find.text('80%'), findsOneWidget);
      // 0 points < 1,000 -> Master locked (grey shield + lock).
      expect(find.text('Master Badge'), findsOneWidget);
      expect(find.text('Unlocked'), findsOneWidget);
      expect(find.text('Locked'), findsOneWidget);
    });

    testWidgets('challenge + achievement rows render real progress; Claim fails gracefully while RPC held',
        (tester) async {
      final todayKey = SupaDb.periodKeyFor(DateTime.now(), 'daily');
      SupaDb.testFixtures = {
        'profiles': [
          {'firebase_uid': 'u1', 'level': 1, 'photo_url': '', 'totalMatches': 0, 'wonMatches': 0},
        ],
        'challenges': [
          {'id': 'ch1', 'key': 'daily_first_match', 'title': 'Play Your First Match Today', 'points': 50, 'goal': 1, 'period': 'daily', 'created_at': '2026-11-21T00:00:00.000Z'},
          {'id': 'ch2', 'key': 'daily_five_kills', 'title': 'Score 5 Kills Today', 'points': 100, 'goal': 5, 'period': 'daily', 'created_at': '2026-11-21T01:00:00.000Z'},
        ],
        'challenge_progress': [
          {'firebase_uid': 'u1', 'challenge_id': 'ch1', 'period_key': todayKey, 'progress': 1, 'claimed': false},
          {'firebase_uid': 'u1', 'challenge_id': 'ch2', 'period_key': todayKey, 'progress': 2, 'claimed': false},
        ],
        'achievements': [
          {'id': 'a1', 'key': 'first_victory', 'title': 'First Victory', 'points': 300, 'created_at': '2026-11-21T00:00:00.000Z'},
        ],
        'user_achievements': [
          {'firebase_uid': 'u1', 'achievement_key': 'first_victory'},
        ],
        'match_history': [],
      };
      await pumpPage(tester);
      expect(tester.takeException(), isNull);

      // Challenge rows: real titles + points + progress + pills.
      expect(find.text('Play Your First Match Today'), findsOneWidget);
      expect(find.text('Score 5 Kills Today'), findsOneWidget);
      expect(find.text('+50 PTS'), findsOneWidget);
      expect(find.text('+100 PTS'), findsOneWidget);
      expect(find.text('1/1'), findsOneWidget);
      expect(find.text('2/5'), findsOneWidget);
      expect(find.text('In Progress'), findsOneWidget);
      expect(find.text('Claim'), findsOneWidget);
      // Achievement row: unlocked via the real user_achievements row.
      expect(find.text('First Victory'), findsOneWidget);
      expect(find.text('+300 PTS'), findsOneWidget);
      expect(find.text('Unlocked'), findsOneWidget);

      // Claim goes through the REAL claim flow only: claim_reward is
      // HELD (JWT bridge), so the tap must fail gracefully — honest
      // error, never a fake success.
      await tester.tap(find.text('Claim'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Claim nahi ho saka — thori der baad koshish karein.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
