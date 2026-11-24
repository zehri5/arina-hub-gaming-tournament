// FIX 10 follow-up — evidence-screenshot watermark label.
// Sameer's order: Firebase UID must never show user-facing; the game
// UID is what players should see. The watermark prefers the game UID
// and falls back to the Firebase UID ONLY when no game UID is saved
// (anti-fraud traceability — the admin traces by the account key).
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/home_screens.dart';

void main() {
  test('prefers the game UID when saved', () {
    expect(
      resultWatermarkLabel(
        gameUid: '5123456789',
        firebaseUid: 'UijzqxXKuAU7z4j3rdo5FIGCcas2',
      ),
      'Game UID: 5123456789',
    );
  });

  test('falls back to the Firebase UID when no game UID is saved', () {
    expect(
      resultWatermarkLabel(
        gameUid: null,
        firebaseUid: 'UijzqxXKuAU7z4j3rdo5FIGCcas2',
      ),
      'UID: UijzqxXKuAU7z4j3rdo5FIGCcas2',
    );
    expect(
      resultWatermarkLabel(gameUid: '', firebaseUid: 'abc123'),
      'UID: abc123',
    );
    expect(
      resultWatermarkLabel(gameUid: '   ', firebaseUid: 'abc123'),
      'UID: abc123',
    );
  });

  test('trims whitespace around the game UID', () {
    expect(
      resultWatermarkLabel(gameUid: '  5123456789  ', firebaseUid: 'abc123'),
      'Game UID: 5123456789',
    );
  });
}
