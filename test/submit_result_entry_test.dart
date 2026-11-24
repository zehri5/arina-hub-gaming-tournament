// SUBMIT RESULT entry points (2026-11-21): the UploadResultPage
// existed but was reachable only from the Room ID dialog, so players
// could not find it. The three new entry points (tournament detail,
// match details, My Matches card) all share one rule —
// [canSubmitResultFor] — tested here as a matrix. Widget-level
// visibility follows the same rule at each call site; the page
// itself still enforces registration + start-time on submit.
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/home_screens.dart';

void main() {
  final now = DateTime.now().millisecondsSinceEpoch;
  final past = now - 60 * 60 * 1000; // started 1 hour ago
  final future = now + 60 * 60 * 1000; // starts in 1 hour

  group('canSubmitResultFor', () {
    test('completed + registered shows the button', () {
      expect(
        canSubmitResultFor(joined: true, status: 'completed', startMs: past),
        isTrue,
      );
    });

    test('result status + registered shows the button', () {
      expect(
        canSubmitResultFor(joined: true, status: 'result', startMs: past),
        isTrue,
      );
    });

    test('completed with no start time still shows the button', () {
      expect(
        canSubmitResultFor(joined: true, status: 'completed', startMs: 0),
        isTrue,
      );
    });

    test('upcoming but start time passed shows the button (status is '
        'never flipped to completed live)', () {
      expect(
        canSubmitResultFor(joined: true, status: 'upcoming', startMs: past),
        isTrue,
      );
    });

    test('ongoing with start time passed shows the button', () {
      expect(
        canSubmitResultFor(joined: true, status: 'ongoing', startMs: past),
        isTrue,
      );
    });

    test('upcoming + not started hides the button', () {
      expect(
        canSubmitResultFor(joined: true, status: 'upcoming', startMs: future),
        isFalse,
      );
    });

    test('upcoming with no start time hides the button', () {
      expect(
        canSubmitResultFor(joined: true, status: 'upcoming', startMs: 0),
        isFalse,
      );
    });

    test('cancelled never shows the button, even after start', () {
      expect(
        canSubmitResultFor(joined: true, status: 'cancelled', startMs: past),
        isFalse,
      );
    });

    test('not registered never shows the button, even when completed', () {
      expect(
        canSubmitResultFor(joined: false, status: 'completed', startMs: past),
        isFalse,
      );
      expect(
        canSubmitResultFor(joined: false, status: 'result', startMs: past),
        isFalse,
      );
    });
  });
}
