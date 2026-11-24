// ARENA HUB #10 AUDIO — GROUP 7 LISTENERS DATA: unit tests for
// LiveListeners (lib/services/live_listeners.dart).
//
// Fake LiveKitParticipantInfo maps only — no LiveKit connection,
// no Supabase, no room screen. The service takes participants +
// seat occupants + resolvers as inputs, so every behaviour here
// is testable in isolation.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/live_listeners.dart';
import 'package:protournament_user/services/livekit_voice_service.dart';

LiveKitParticipantInfo _p(String identity, [String name = '']) =>
    LiveKitParticipantInfo(
      identity: identity,
      name: name,
      muted: true,
      speaking: false,
    );

Map<String, LiveKitParticipantInfo> _room(Map<String, String> uidToName) =>
    {for (final e in uidToName.entries) e.key: _p(e.key, e.value)};

/// Controllable clock: tests advance time explicitly so
/// first-seen / sorting behaviour is deterministic.
class _FakeClock {
  DateTime now = DateTime(2026, 11, 22, 19, 0);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  group('LiveListeners — participants minus seats', () {
    test('listeners = participants MINUS seat occupants', () {
      final clock = _FakeClock();
      final ll = LiveListeners(now: clock.call);
      ll.update(_room({'host': 'Host', 'guest': 'Guest', 'l1': 'A', 'l2': 'B'}),
          {'host', 'guest'});
      expect(ll.listenerCount, 2);
      expect(ll.listeners.map((l) => l.uid), containsAll(['l1', 'l2']));
      expect(ll.listeners.map((l) => l.uid), isNot(contains('host')));
      expect(ll.listeners.map((l) => l.uid), isNot(contains('guest')));
      ll.dispose();
    });

    test('host on a seat is excluded', () {
      final clock = _FakeClock();
      final ll = LiveListeners(now: clock.call);
      ll.update(_room({'host': 'Host', 'l1': 'A'}), {'host'});
      expect(ll.listenerCount, 1);
      expect(ll.listeners.single.uid, 'l1');
      ll.dispose();
    });

    test('seat uid NOT in the room is harmless', () {
      final clock = _FakeClock();
      final ll = LiveListeners(now: clock.call);
      ll.update(_room({'l1': 'A'}), {'ghost-seat-uid'});
      expect(ll.listenerCount, 1);
      ll.dispose();
    });
  });

  group('LiveListeners — first-seen clock', () {
    test('first-seen timestamps stick across updates', () {
      final clock = _FakeClock();
      final ll = LiveListeners(now: clock.call);
      ll.update(_room({'l1': 'A'}), {});
      final first = ll.listeners.single.listeningSince;
      expect(first, clock.now);
      clock.advance(const Duration(minutes: 5));
      ll.update(_room({'l1': 'A', 'l2': 'B'}), {});
      clock.advance(const Duration(minutes: 5));
      ll.update(_room({'l1': 'A', 'l2': 'B'}), {});
      final l1 =
          ll.listeners.singleWhere((l) => l.uid == 'l1').listeningSince;
      expect(l1, first, reason: 'a stayer keeps the ORIGINAL listeningSince');
      ll.dispose();
    });

    test('leaving removes the listener; rejoining restarts the clock', () {
      final clock = _FakeClock();
      final ll = LiveListeners(now: clock.call);
      ll.update(_room({'l1': 'A'}), {});
      final first = ll.listeners.single.listeningSince;
      clock.advance(const Duration(minutes: 10));
      ll.update(_room({}), {});
      expect(ll.listenerCount, 0);
      clock.advance(const Duration(minutes: 2));
      ll.update(_room({'l1': 'A'}), {});
      expect(ll.listenerCount, 1);
      expect(ll.listeners.single.listeningSince, clock.now);
      expect(ll.listeners.single.listeningSince, isNot(first));
      ll.dispose();
    });

    test('taking a seat removes the listener; leaving the seat restarts the clock',
        () {
      final clock = _FakeClock();
      final ll = LiveListeners(now: clock.call);
      ll.update(_room({'l1': 'A'}), {});
      final first = ll.listeners.single.listeningSince;
      clock.advance(const Duration(minutes: 3));
      ll.update(_room({'l1': 'A'}), {'l1'});
      expect(ll.listenerCount, 0);
      clock.advance(const Duration(minutes: 4));
      ll.update(_room({'l1': 'A'}), {});
      expect(ll.listenerCount, 1);
      expect(ll.listeners.single.listeningSince, clock.now);
      expect(ll.listeners.single.listeningSince, isNot(first));
      ll.dispose();
    });

    test('listeners sorted longest-listening first', () {
      final clock = _FakeClock();
      final ll = LiveListeners(now: clock.call);
      ll.update(_room({'l1': 'A'}), {});
      clock.advance(const Duration(minutes: 5));
      ll.update(_room({'l1': 'A', 'l2': 'B'}), {});
      clock.advance(const Duration(minutes: 5));
      ll.update(_room({'l1': 'A', 'l2': 'B', 'l3': 'C'}), {});
      expect(
        ll.listeners.map((l) => l.uid).toList(),
        ['l1', 'l2', 'l3'],
        reason: 'earliest listeningSince first',
      );
      ll.dispose();
    });
  });

  group('LiveListeners — session peak', () {
    test('peak tracks the max live count and survives drops', () {
      final clock = _FakeClock();
      final ll = LiveListeners(now: clock.call);
      ll.update(_room({'l1': 'A'}), {});
      expect(ll.peakListeners, 1);
      ll.update(_room({'l1': 'A', 'l2': 'B', 'l3': 'C'}), {});
      expect(ll.peakListeners, 3);
      ll.update(_room({'l1': 'A'}), {});
      expect(ll.listenerCount, 1);
      expect(ll.peakListeners, 3,
          reason: 'peak survives the drop — it is the session max');
      ll.dispose();
    });

    test('empty room -> 0 listeners, peak 0', () {
      final clock = _FakeClock();
      final ll = LiveListeners(now: clock.call);
      ll.update(_room({}), {});
      expect(ll.listenerCount, 0);
      expect(ll.listeners, isEmpty);
      expect(ll.peakListeners, 0);
      ll.dispose();
    });

    test('reset() clears state + peak', () {
      final clock = _FakeClock();
      final ll = LiveListeners(now: clock.call);
      ll.update(_room({'l1': 'A', 'l2': 'B'}), {});
      expect(ll.peakListeners, 2);
      ll.reset();
      expect(ll.listenerCount, 0);
      expect(ll.listeners, isEmpty);
      expect(ll.peakListeners, 0);
      // After reset, a returning listener starts a fresh clock.
      clock.advance(const Duration(minutes: 1));
      ll.update(_room({'l1': 'A'}), {});
      expect(ll.listeners.single.listeningSince, clock.now);
      expect(ll.peakListeners, 1);
      ll.dispose();
    });
  });

  group('LiveListeners — names and avatars', () {
    test('name resolver used when provided, LiveKit name otherwise, identity last',
        () async {
      final clock = _FakeClock();
      final ll = LiveListeners(
        now: clock.call,
        nameResolver: (uid) async =>
            uid == 'l1' ? 'Profile Name' : '', // l2: no profile name
        avatarResolver: (uid) async =>
            uid == 'l1' ? 'https://example.com/l1.png' : null,
      );
      // l3 has an EMPTY LiveKit name -> identity fallback.
      ll.update(_room({'l1': 'LK One', 'l2': 'LK Two', 'l3': ''}), {});
      // update() is synchronous: before the background resolution
      // lands, LiveKit names are shown.
      expect(
        ll.listeners.singleWhere((l) => l.uid == 'l1').displayName,
        'LK One',
      );
      // Let the background resolutions land.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final byUid = {for (final l in ll.listeners) l.uid: l};
      expect(byUid['l1']!.displayName, 'Profile Name');
      expect(byUid['l1']!.avatarUrl, 'https://example.com/l1.png');
      expect(byUid['l2']!.displayName, 'LK Two',
          reason: 'empty resolver result -> LiveKit name');
      expect(byUid['l2']!.avatarUrl, isNull);
      expect(byUid['l3']!.displayName, 'l3',
          reason: 'no resolver name + empty LiveKit name -> identity');
      ll.dispose();
    });

    test('without resolvers, LiveKit name then identity; avatars null', () {
      final clock = _FakeClock();
      final ll = LiveListeners(now: clock.call);
      ll.update(_room({'l1': 'LK One', 'l2': ''}), {});
      final byUid = {for (final l in ll.listeners) l.uid: l};
      expect(byUid['l1']!.displayName, 'LK One');
      expect(byUid['l2']!.displayName, 'l2');
      expect(byUid['l1']!.avatarUrl, isNull);
      expect(byUid['l2']!.avatarUrl, isNull);
      ll.dispose();
    });

    test('background resolution notifies listeners when it lands', () async {
      final clock = _FakeClock();
      final gate = Completer<String>();
      final ll = LiveListeners(
        now: clock.call,
        nameResolver: (_) => gate.future,
      );
      var notified = 0;
      ll.addListener(() => notified++);
      ll.update(_room({'l1': 'LK One'}), {});
      final afterUpdate = notified;
      expect(afterUpdate, 1);
      expect(ll.listeners.single.displayName, 'LK One');
      gate.complete('Resolved Name');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ll.listeners.single.displayName, 'Resolved Name');
      expect(notified, greaterThan(afterUpdate),
          reason: 'resolution landing notifies the panel to re-render');
      ll.dispose();
    });

    test('resolution landing after the listener left is dropped', () async {
      final clock = _FakeClock();
      final gate = Completer<String>();
      final ll = LiveListeners(
        now: clock.call,
        nameResolver: (_) => gate.future,
      );
      ll.update(_room({'l1': 'LK One'}), {});
      ll.update(_room({}), {});
      gate.complete('Too Late');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ll.listenerCount, 0);
      // And a rejoin does NOT inherit the stale resolved name.
      ll.update(_room({'l1': 'LK One'}), {});
      expect(ll.listeners.single.displayName, 'LK One');
      ll.dispose();
    });

    test('resolver failure is swallowed, fallbacks stay', () async {
      final clock = _FakeClock();
      final ll = LiveListeners(
        now: clock.call,
        nameResolver: (_) async => throw StateError('profile lookup down'),
      );
      ll.update(_room({'l1': 'LK One'}), {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ll.listeners.single.displayName, 'LK One');
      ll.dispose();
    });
  });

  group('LiveListeners — notifications', () {
    test('update() notifies on list change, stays quiet on no-op updates', () {
      final clock = _FakeClock();
      final ll = LiveListeners(now: clock.call);
      var notified = 0;
      ll.addListener(() => notified++);
      ll.update(_room({'l1': 'A'}), {});
      expect(notified, 1);
      ll.update(_room({'l1': 'A'}), {});
      expect(notified, 1, reason: 'identical update must not re-notify');
      ll.update(_room({'l1': 'A', 'l2': 'B'}), {});
      expect(notified, 2);
      ll.dispose();
    });

    test('update() after dispose() is a safe no-op', () {
      final clock = _FakeClock();
      final ll = LiveListeners(now: clock.call);
      ll.update(_room({'l1': 'A'}), {});
      ll.dispose();
      ll.update(_room({'l1': 'A', 'l2': 'B'}), {});
      expect(ll.listenerCount, 0);
    });
  });
}
