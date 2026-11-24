// FIX 10 (2026-11-21, user order from the My Team screenshot
// 1000049118_47_39rz.jpg): the roster showed FIREBASE UIDs
// ("UID: 3y6MsvtXFIWCYHP60X..." / "UID: UijzqxXKuAU7z4j3rdo5F...")
// because _memberCard fell back to the Firebase UID when a member
// had no game_uid saved. Sameer: "Firebase UID dikh rahi hai, aisa
// nahi hona chahiye — game ki jo ID hai na wo wali dikhni chahiye."
//
// These tests pin the three pure helpers that now own the UID
// logic in lib/screens/pro_features.dart:
//   rosterGameUid — the game UID from a profile row, '' when none
//     saved (NEVER the Firebase UID — it takes no uid argument).
//   rosterUidLine — the full roster line _memberCard renders:
//     'UID: <game UID>' when saved, a placeholder when not.
//   editProfilePatch — the Edit Profile save patch (full + minimal
//     retry): game_uid rides in both, never silently dropped.
//
// What is NOT covered here (needs the phone / live backend): the
// rendered roster pixels, and the actual Supabase write — the
// column's live existence was verified by a read-only REST probe
// on 2026-11-21 (profiles.game_uid EXISTS; both sampled rows NULL,
// which is exactly why the roster fell back to Firebase UIDs).
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/pro_features.dart';

void main() {
  group('rosterGameUid', () {
    test('returns the saved game UID', () {
      expect(
        rosterGameUid({'firebase_uid': '3y6MsvtXFIWCYHP60Xabc', 'game_uid': '5123456789'}),
        '5123456789',
      );
    });

    test('reads the camelCase gameUid key too (normProfile shape)', () {
      expect(
        rosterGameUid({'firebase_uid': 'fb-uid', 'gameUid': '987654321'}),
        '987654321',
      );
    });

    test('trims surrounding whitespace', () {
      expect(rosterGameUid({'game_uid': '  5123456789  '}), '5123456789');
    });

    test('empty when game_uid is missing — NEVER the Firebase UID', () {
      final profile = {'firebase_uid': '3y6MsvtXFIWCYHP60Xabc', 'display_name': 'sameer'};
      final result = rosterGameUid(profile);
      expect(result, isEmpty);
      expect(result, isNot(contains('3y6MsvtXFIWCYHP60X')));
    });

    test('empty when game_uid is null or blank — NEVER the Firebase UID', () {
      expect(rosterGameUid({'firebase_uid': 'UijzqxXKuAU7z4j3rdo5F', 'game_uid': null}), isEmpty);
      expect(rosterGameUid({'firebase_uid': 'UijzqxXKuAU7z4j3rdo5F', 'game_uid': '   '}), isEmpty);
      expect(rosterGameUid({}), isEmpty);
    });
  });

  group('rosterUidLine (what _memberCard renders)', () {
    test('shows the game UID when saved', () {
      expect(
        rosterUidLine({'game_uid': '5123456789'}),
        'UID: 5123456789',
      );
    });

    test('shows the placeholder when game_uid is empty', () {
      expect(
        rosterUidLine({'firebase_uid': '3y6MsvtXFIWCYHP60Xabc'}),
        'Game UID not set',
      );
    });

    test('placeholder never contains the Firebase UID', () {
      const fbUid = 'UijzqxXKuAU7z4j3rdo5Fxyz';
      final line = rosterUidLine({'firebase_uid': fbUid, 'game_uid': null});
      expect(line, isNot(contains(fbUid)));
      expect(line, isNot(contains('UijzqxX')));
    });

    test('custom empty label is honoured (Urdu placeholder)', () {
      expect(
        rosterUidLine({'firebase_uid': 'fb-uid'}, emptyLabel: 'Game UID set nahi hai'),
        'Game UID set nahi hai',
      );
    });
  });

  group('editProfilePatch (Edit Profile save)', () {
    test('full patch includes game_uid when the player typed one', () {
      final patch = editProfilePatch(
        displayName: 'sameer',
        username: 'sameer',
        playerId: '5123456789',
        country: 'Pakistan',
        game: 'PUBG Mobile',
        bio: 'hello',
      );
      expect(patch['game_uid'], '5123456789');
      expect(patch['display_name'], 'sameer');
      expect(patch['country'], 'Pakistan');
      expect(patch['favorite_game'], 'PUBG Mobile');
      expect(patch['bio'], 'hello');
    });

    test('minimal retry patch ALSO includes game_uid (never dropped)', () {
      final patch = editProfilePatch(
        displayName: 'sameer',
        playerId: '5123456789',
        country: 'Pakistan',
        game: 'PUBG Mobile',
        bio: 'hello',
        minimal: true,
      );
      expect(patch['game_uid'], '5123456789');
      // Minimal omits only country / game / bio.
      expect(patch.containsKey('country'), isFalse);
      expect(patch.containsKey('favorite_game'), isFalse);
      expect(patch.containsKey('bio'), isFalse);
    });

    test('game_uid is trimmed', () {
      final patch = editProfilePatch(displayName: 'x', playerId: '  5123456789  ');
      expect(patch['game_uid'], '5123456789');
    });

    test('game_uid omitted (not empty string) when the field is blank', () {
      expect(
        editProfilePatch(displayName: 'x', playerId: '').containsKey('game_uid'),
        isFalse,
      );
      expect(
        editProfilePatch(displayName: 'x', playerId: '   ').containsKey('game_uid'),
        isFalse,
      );
    });

    test('in_game_name rides in both patches when the column exists', () {
      final full = editProfilePatch(displayName: 'x', ign: 'admin', hasIgnColumn: true);
      final minimal = editProfilePatch(displayName: 'x', ign: 'admin', hasIgnColumn: true, minimal: true);
      expect(full['in_game_name'], 'admin');
      expect(minimal['in_game_name'], 'admin');
    });

    test('in_game_name omitted when the column does not exist', () {
      final patch = editProfilePatch(displayName: 'x', ign: 'admin', hasIgnColumn: false);
      expect(patch.containsKey('in_game_name'), isFalse);
    });
  });
}
