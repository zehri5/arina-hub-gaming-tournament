// Player Stats fix (2026-11-20) regression tests — mockup #25.
// Covers the pure helpers only (the page itself loads live data):
//   1. team-name fragment rule (production team_name 'jii' hidden)
//   2. the four mockup badge assets are bundled and non-trivial.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/player_stats.dart';

void main() {
  test('team-name fragment rule: short fragments hidden', () {
    // Production evidence: the user's only registration carries
    // team_name 'jii' — a stray fragment, never shown.
    expect(cleanTeamName('jii'), '');
    expect(cleanTeamName('jjs'), '');
    expect(cleanTeamName(''), '');
    // Real team names (>= 4 chars) pass through untouched.
    expect(cleanTeamName('Team Alpha'), 'Team Alpha');
    expect(cleanTeamName('Alpha'), 'Alpha');
    expect(cleanTeamName('Abcd'), 'Abcd');
  });

  testWidgets('mockup badge assets are bundled', (_) async {
    const badges = [
      'assets/images/badge_mvp.png',
      'assets/images/badge_slayer.png',
      'assets/images/badge_survivor.png',
      'assets/images/badge_deadshot.png',
    ];
    for (final a in badges) {
      final data = await rootBundle.load(a);
      expect(data.lengthInBytes, greaterThan(10000),
          reason: '$a must be a real cropped badge, not an empty file');
    }
  });
}
