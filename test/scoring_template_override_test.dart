import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/platform/core/scoring.dart';
import 'package:protournament_user/platform/scoring/scoring_template_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Scoring update (Sameer 2026-11-21 02:20): the decided placement
/// table is 1st = 10, 2nd = 7, 3rd = 5, 4th and below = 0, +1/kill —
/// and the admin can override 10/7/5 from the admin panel
/// ([ScoringTemplateStore], device-local until the server
/// `scoring_templates` table lands).
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('decided default template (10/7/5/0)', () {
    test('1st + 0 kills = 10', () {
      expect(calculateMatchPoints(placement: 1, kills: 0), 10);
    });

    test('2nd + 1 kill = 8 (7 placement + 1 kill)', () {
      expect(calculateMatchPoints(placement: 2, kills: 1), 8);
    });

    test('3rd + 2 kills = 7 (5 placement + 2 kills)', () {
      expect(calculateMatchPoints(placement: 3, kills: 2), 7);
    });

    test('4th + 5 kills = 5 (kills only — 4th scores 0)', () {
      expect(calculateMatchPoints(placement: 4, kills: 5), 5);
    });

    test('8th + 0 kills = 0', () {
      expect(calculateMatchPoints(placement: 8, kills: 0), 0);
    });

    test('1st + 12 kills = 22 (unchanged)', () {
      expect(calculateMatchPoints(placement: 1, kills: 12), 22);
    });
  });

  group('ScoringTemplateStore override', () {
    test('no override stored -> effective template is the default', () async {
      final t = await ScoringTemplateStore.loadEffectiveTemplate();
      expect(t.id, 'default');
      expect(t.placementPoints, {1: 10, 2: 7, 3: 5});
      expect(await ScoringTemplateStore.hasOverride(), isFalse);
    });

    test('save override -> effective template is the override', () async {
      final ok = await ScoringTemplateStore.saveOverride(
          first: 20, second: 15, third: 10);
      expect(ok, isTrue);
      expect(await ScoringTemplateStore.hasOverride(), isTrue);
      final t = await ScoringTemplateStore.loadEffectiveTemplate();
      expect(t.id, 'admin-override');
      expect(t.placementPoints, {1: 20, 2: 15, 3: 10});
      expect(t.killPoints, 1);
      expect(
          calculateMatchPoints(placement: 2, kills: 1, template: t), 16);
    });

    test('clear override -> back to the default', () async {
      await ScoringTemplateStore.saveOverride(
          first: 20, second: 15, third: 10);
      expect(await ScoringTemplateStore.hasOverride(), isTrue);
      await ScoringTemplateStore.clearOverride();
      expect(await ScoringTemplateStore.hasOverride(), isFalse);
      final t = await ScoringTemplateStore.loadEffectiveTemplate();
      expect(t.id, 'default');
    });

    test('negative values are rejected, default stays', () async {
      final ok = await ScoringTemplateStore.saveOverride(
          first: 10, second: -1, third: 5);
      expect(ok, isFalse);
      expect(await ScoringTemplateStore.hasOverride(), isFalse);
      final t = await ScoringTemplateStore.loadEffectiveTemplate();
      expect(t.id, 'default');
    });
  });
}
