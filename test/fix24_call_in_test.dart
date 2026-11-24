// FIX 24 — LIVE CALL-IN / CO-HOST tests (2026-11-23).
//
// While live hosting, the RJ panel shows the 6 mic seats; the host
// picks one mic -> that person goes LIVE with the host (radio
// live-call style). VERIFIED FIRST (see the fix24 report): a mic
// occupant's voice ALREADY reaches all listeners today on both
// engines (occupants publish their mic track; listeners subscribe
// to all tracks — LiveKit autoSubscribe defaults true, the mesh
// plays remote tracks on add; no app-side remote-track gating
// exists anywhere). So the feature is SELECTION/SPOTLIGHT: the
// panel list + host pick + guest strip + guest-speech ducking of
// the mix music — no subscription fix was needed.
//
// Tests: the pure seat-assignment rule (same algorithm as the
// stage), the guest-pick rule, and the panel widget (section
// renders, tap selects, tap again deselects, empty seats are
// inert, the MIC ON/OFF button fires).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/room_screen.dart';
import 'package:protournament_user/services/radio_mixer.dart';
import 'package:protournament_user/widgets/rj_studio_panel.dart';

Map<String, Map<String, dynamic>> _peer(
  String uid, {
  int? seatNo,
  String? name,
  String? displayName,
  bool muted = false,
}) =>
    {
      uid: {
        if (seatNo != null) 'seat_no': seatNo,
        if (name != null) 'name': name,
        if (displayName != null) 'display_name': displayName,
        'muted': muted,
      }
    };

Map<String, Map<String, dynamic>> _peers(
        List<Map<String, Map<String, dynamic>>> rows) =>
    {for (final r in rows) ...r};

void main() {
  group('fix24 — callInSeatAssignments (pure seat rule)', () {
    test('empty peers = all seats empty', () {
      final seats = callInSeatAssignments(peers: {}, usable: 6);
      expect(seats.length, 6);
      expect(seats.every((s) => !s.occupied), isTrue);
      expect(seats.map((s) => s.seatNo).toList(), [1, 2, 3, 4, 5, 6]);
    });

    test('assigned seat_no renders in exactly that cell', () {
      final seats = callInSeatAssignments(
        peers: _peers([
          _peer('uid-a', seatNo: 3, name: 'Ali'),
          _peer('uid-b', seatNo: 1, name: 'Bina'),
        ]),
        usable: 6,
      );
      expect(seats[0].uid, 'uid-b');
      expect(seats[2].uid, 'uid-a');
      expect(seats[1].occupied, isFalse);
    });

    test('unassigned peers fill the earliest free cells in order', () {
      final seats = callInSeatAssignments(
        peers: _peers([
          _peer('uid-a', seatNo: 2, name: 'Ali'),
          _peer('uid-b', name: 'Bina'),
          _peer('uid-c', name: 'Cid'),
        ]),
        usable: 6,
      );
      // Cell 2 is taken; Bina -> 1, Cid -> 3.
      expect(seats[0].uid, 'uid-b');
      expect(seats[1].uid, 'uid-a');
      expect(seats[2].uid, 'uid-c');
    });

    test('leftovers past the mic count never appear', () {
      final seats = callInSeatAssignments(
        peers: _peers([
          for (var i = 0; i < 8; i++) _peer('uid-$i', name: 'P$i'),
        ]),
        usable: 6,
      );
      expect(seats.length, 6);
      expect(seats.every((s) => s.occupied), isTrue);
      // The 7th/8th peers are listeners, not seats.
      expect(seats.map((s) => s.uid), isNot(contains('uid-6')));
      expect(seats.map((s) => s.uid), isNot(contains('uid-7')));
    });

    test('out-of-range seat_no falls back to join-order fill', () {
      final seats = callInSeatAssignments(
        peers: _peers([
          _peer('uid-a', seatNo: 99, name: 'Ali'),
        ]),
        usable: 6,
      );
      expect(seats[0].uid, 'uid-a');
    });

    test('duplicate seat_no: first wins, second fills free', () {
      final seats = callInSeatAssignments(
        peers: _peers([
          _peer('uid-a', seatNo: 1, name: 'Ali'),
          _peer('uid-b', seatNo: 1, name: 'Bina'),
        ]),
        usable: 6,
      );
      expect(seats[0].uid, 'uid-a');
      expect(seats[1].uid, 'uid-b');
    });

    test('name rule: display_name, then name, then Player', () {
      final seats = callInSeatAssignments(
        peers: _peers([
          _peer('uid-a', seatNo: 1, name: 'Ali', displayName: 'Ali D'),
          _peer('uid-b', seatNo: 2, name: 'Bina'),
          _peer('uid-c', seatNo: 3),
        ]),
        usable: 6,
      );
      expect(seats[0].name, 'Ali D');
      expect(seats[1].name, 'Bina');
      expect(seats[2].name, 'Player');
    });

    test('muted flag carries through', () {
      final seats = callInSeatAssignments(
        peers: _peers([
          _peer('uid-a', seatNo: 1, name: 'Ali', muted: true),
          _peer('uid-b', seatNo: 2, name: 'Bina', muted: false),
        ]),
        usable: 6,
      );
      expect(seats[0].muted, isTrue);
      expect(seats[1].muted, isFalse);
    });
  });

  group('fix24 — rjCallInGuestUid (guest-pick rule)', () {
    test('selected guest wins when still seated', () {
      expect(
        rjCallInGuestUid(
          selectedUid: 'uid-b',
          seatUids: ['uid-a', 'uid-b'],
          hostUid: 'host',
        ),
        'uid-b',
      );
    });

    test('selected guest gone = auto-pick first non-host', () {
      expect(
        rjCallInGuestUid(
          selectedUid: 'uid-gone',
          seatUids: ['uid-a', 'uid-b'],
          hostUid: 'host',
        ),
        'uid-a',
      );
    });

    test('no selection = auto-pick first non-host', () {
      expect(
        rjCallInGuestUid(
          seatUids: ['host', 'uid-a'],
          hostUid: 'host',
        ),
        'uid-a',
      );
    });

    test('host only seated = null', () {
      expect(
        rjCallInGuestUid(seatUids: ['host'], hostUid: 'host'),
        isNull,
      );
    });

    test('no seats = null', () {
      expect(
        rjCallInGuestUid(seatUids: [], hostUid: 'host'),
        isNull,
      );
    });
  });

  group('fix24 — call-in panel widget', () {
    void setTallSurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(390, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    const seats = <RjCallInSeat>[
      RjCallInSeat(seatNo: 1, uid: 'uid-a', name: 'Ali', muted: false),
      RjCallInSeat(seatNo: 2, uid: 'uid-b', name: 'Bina', muted: true),
      RjCallInSeat(seatNo: 3),
      RjCallInSeat(seatNo: 4),
      RjCallInSeat(seatNo: 5),
      RjCallInSeat(seatNo: 6),
    ];

    Future<void> pumpPanel(
      WidgetTester tester, {
      List<RjCallInSeat> callInSeats = seats,
      String? selectedCallInUid,
      ValueChanged<String?>? onCallInSelected,
      bool micLinkOn = true,
      ValueChanged<bool>? onMicLinkChanged,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RjStudioPanel(
            // No DSP: the panel builds regardless (fix22 item 6) —
            // the call-in section + faders are not DSP-gated.
            isHost: true,
            hostName: 'RJ Sameer',
            onGoLivePressed: () {},
            onMutePressed: () {},
            micLinkOn: micLinkOn,
            onMicLinkChanged: onMicLinkChanged,
            callInSeats: callInSeats,
            selectedCallInUid: selectedCallInUid,
            onCallInSelected: onCallInSelected,
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('call-in section renders all 6 seats + names',
        (tester) async {
      setTallSurface(tester);
      await pumpPanel(tester);

      expect(find.byKey(const Key('call-in-section')), findsOneWidget);
      expect(find.text('LIVE CALL-IN'), findsOneWidget);
      expect(find.text('Ali'), findsOneWidget);
      expect(find.text('Bina'), findsOneWidget);
      expect(find.text('khaali'), findsNWidgets(4));
      for (var i = 1; i <= 6; i++) {
        expect(find.byKey(Key('call-in-seat-$i')), findsOneWidget);
      }
    });

    testWidgets('no seats = no call-in section', (tester) async {
      setTallSurface(tester);
      await pumpPanel(tester, callInSeats: const []);

      expect(find.byKey(const Key('call-in-section')), findsNothing);
      expect(find.text('LIVE CALL-IN'), findsNothing);
    });

    testWidgets('tapping an occupied seat selects it', (tester) async {
      setTallSurface(tester);
      String? picked;
      await pumpPanel(tester, onCallInSelected: (uid) => picked = uid);

      await tester.tap(find.byKey(const Key('call-in-seat-1')));
      await tester.pump();
      expect(picked, 'uid-a');
    });

    testWidgets('tapping the selected seat again deselects it',
        (tester) async {
      setTallSurface(tester);
      String? picked = 'sentinel';
      await pumpPanel(
        tester,
        selectedCallInUid: 'uid-a',
        onCallInSelected: (uid) => picked = uid,
      );

      // The selected seat shows the LIVE badge.
      expect(find.text('LIVE'), findsOneWidget);
      await tester.tap(find.byKey(const Key('call-in-seat-1')));
      await tester.pump();
      expect(picked, isNull);
    });

    testWidgets('tapping an empty seat does nothing', (tester) async {
      setTallSurface(tester);
      var called = false;
      await pumpPanel(tester, onCallInSelected: (_) => called = true);

      await tester.tap(find.byKey(const Key('call-in-seat-3')));
      await tester.pump();
      expect(called, isFalse);
    });

    testWidgets('switching seats picks the new guest', (tester) async {
      setTallSurface(tester);
      String? picked;
      await pumpPanel(
        tester,
        selectedCallInUid: 'uid-a',
        onCallInSelected: (uid) => picked = uid,
      );

      await tester.tap(find.byKey(const Key('call-in-seat-2')));
      await tester.pump();
      expect(picked, 'uid-b');
    });

    testWidgets('MIC ON/OFF button renders + fires', (tester) async {
      setTallSurface(tester);
      bool? flipped;
      await pumpPanel(tester, onMicLinkChanged: (v) => flipped = v);

      expect(find.byKey(const Key('rj-mic-link-toggle')), findsOneWidget);
      expect(find.text('MIC ON'), findsOneWidget);
      await tester.tap(find.byKey(const Key('rj-mic-link-toggle')));
      await tester.pump();
      expect(flipped, isFalse);
    });

    testWidgets('MIC OFF state renders MIC OFF', (tester) async {
      setTallSurface(tester);
      await pumpPanel(tester, micLinkOn: false);

      expect(find.text('MIC OFF'), findsOneWidget);
      expect(find.text('MIC ON'), findsNothing);
      // The MIC fader still renders (dimmed, not removed).
      expect(find.byKey(const Key('fader-mic')), findsOneWidget);
    });
  });
}
