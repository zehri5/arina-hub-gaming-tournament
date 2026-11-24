// WORKSTREAM C — competition automation (blueprint §5-1..§5-4):
// registration validation, waitlist, check-in, team allocation,
// room release. All services are local-store backed (SharedPreferences
// mock here); the backend tables/RPCs are the eventual home.
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/platform/competition/checkin_service.dart';
import 'package:protournament_user/platform/competition/registration_validation.dart';
import 'package:protournament_user/platform/competition/room_release.dart';
import 'package:protournament_user/platform/competition/team_allocation.dart';
import 'package:protournament_user/platform/competition/waitlist_service.dart';
import 'package:protournament_user/platform/core/exceptions.dart';
import 'package:protournament_user/platform/core/lifecycle.dart';
import 'package:protournament_user/platform/core/tournament_enums.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('registration validation', () {
    test('duplicate UID: same UID twice fails, unique UIDs pass', () {
      expect(duplicateUidError(['u1', 'u2', 'u1']), isNotNull);
      expect(duplicateUidError(['u1', 'u2', 'u3']), isNull);
      expect(duplicateUidError([]), isNull);
    });

    test('roster size: solo=1, duo=2, squad=4 (matches SupaDb.teamSizeOf)', () {
      expect(rosterSizeError(size: 1, mode: TeamMode.solo), isNull);
      expect(rosterSizeError(size: 2, mode: TeamMode.solo), isNotNull);
      expect(rosterSizeError(size: 2, mode: TeamMode.duo), isNull);
      expect(rosterSizeError(size: 3, mode: TeamMode.duo), isNotNull);
      expect(rosterSizeError(size: 4, mode: TeamMode.squad), isNull);
      expect(rosterSizeError(size: 3, mode: TeamMode.squad), isNotNull);
      expect(expectedRosterSize(TeamMode.solo), 1);
      expect(expectedRosterSize(TeamMode.duo), 2);
      expect(expectedRosterSize(TeamMode.squad), 4);
    });

    test('eligibility: country + level, each pass and fail', () {
      // Eligible: allowed country + level met.
      expect(
          eligibilityError(
              playerCountry: 'PK',
              allowedCountries: ['PK', 'IN'],
              playerLevel: 30,
              levelRequired: 20),
          isNull);
      // Country blocked.
      expect(
          eligibilityError(
              playerCountry: 'US',
              allowedCountries: ['PK', 'IN'],
              playerLevel: 30,
              levelRequired: 20),
          isNotNull);
      // Level too low.
      expect(
          eligibilityError(
              playerCountry: 'PK',
              allowedCountries: ['PK'],
              playerLevel: 5,
              levelRequired: 20),
          isNotNull);
      // No restrictions at all = eligible.
      expect(
          eligibilityError(
              playerCountry: 'US',
              allowedCountries: [],
              playerLevel: 1,
              levelRequired: 0),
          isNull);
      // Country match is case-insensitive.
      expect(
          eligibilityError(
              playerCountry: 'pk',
              allowedCountries: ['PK'],
              playerLevel: 99,
              levelRequired: 0),
          isNull);
    });
  });

  group('waitlist', () {
    const t = 't-waitlist';

    test('join returns 1-based positions; same UID re-join is idempotent',
        () async {
      const service = WaitlistService();
      expect(await service.joinWaitlist(t, 'u1'), 1);
      expect(await service.joinWaitlist(t, 'u2'), 2);
      expect(await service.joinWaitlist(t, 'u3'), 3);
      expect(await service.joinWaitlist(t, 'u1'), 1); // No duplicate row.
      final queue = await service.getWaitlist(t);
      expect(queue.map((e) => e.uid).toList(), ['u1', 'u2', 'u3']);
      expect(queue.map((e) => e.position).toList(), [1, 2, 3]);
    });

    test('promoteNext promotes the first and re-numbers the rest',
        () async {
      const service = WaitlistService();
      await service.joinWaitlist(t, 'u1');
      await service.joinWaitlist(t, 'u2');
      await service.joinWaitlist(t, 'u3');
      final promoted = await service.promoteNext(t);
      expect(promoted, isNotNull);
      expect(promoted!.uid, 'u1');
      expect(promoted.status, WaitlistStatus.promoted);
      final queue = await service.getWaitlist(t);
      expect(queue.map((e) => e.uid).toList(), ['u2', 'u3']);
      expect(queue.map((e) => e.position).toList(), [1, 2]);
      expect(await service.promoteNext('empty-tournament'), isNull);
    });

    test('cancel removes the entry and re-numbers', () async {
      const service = WaitlistService();
      await service.joinWaitlist(t, 'u1');
      await service.joinWaitlist(t, 'u2');
      await service.joinWaitlist(t, 'u3');
      expect(await service.cancelEntry(t, 'u2'), isTrue);
      final queue = await service.getWaitlist(t);
      expect(queue.map((e) => e.uid).toList(), ['u1', 'u3']);
      expect(queue.map((e) => e.position).toList(), [1, 2]);
      expect(await service.cancelEntry(t, 'nobody'), isFalse);
    });

    test('expire marks expired and re-numbers', () async {
      const service = WaitlistService();
      await service.joinWaitlist(t, 'u1');
      await service.joinWaitlist(t, 'u2');
      expect(await service.expireEntry(t, 'u1'), isTrue);
      final queue = await service.getWaitlist(t);
      expect(queue.map((e) => e.uid).toList(), ['u2']);
      expect(queue.first.position, 1);
      final all = await service.getAllEntries(t);
      expect(
          all
              .firstWhere((e) => e.uid == 'u1')
              .status,
          WaitlistStatus.expired);
    });
  });

  group('check-in', () {
    const t = 't-checkin';

    test('captain check-in fails while window not open', () async {
      final service = CheckInService();
      final error =
          await service.captainCheckIn(t, 'team-a', 'captain-a');
      expect(error, isNotNull);
      expect(await service.getWindow(t), CheckInWindow.notOpened);
    });

    test('open window, check in, re-check is idempotent', () async {
      final service = CheckInService();
      await service.openWindow(
          t, DateTime.now().add(const Duration(hours: 1)));
      expect(await service.getWindow(t), CheckInWindow.open);
      expect(
          await service.captainCheckIn(t, 'team-a', 'captain-a'), isNull);
      expect(
          await service.captainCheckIn(t, 'team-a', 'captain-a'), isNull);
      final entry = await service.getEntryFor(t, 'team-a');
      expect(entry?.status, CheckInStatus.checkedIn);
      expect(entry?.captainUid, 'captain-a');
    });

    test('check-in after the deadline is refused', () async {
      final service = CheckInService();
      final deadline = DateTime.now().add(const Duration(minutes: 5));
      await service.openWindow(t, deadline);
      final error = await service.captainCheckIn(t, 'team-a', 'captain-a',
          now: deadline.add(const Duration(minutes: 1)));
      expect(error, isNotNull);
    });

    test('markLate records late and counts as present at close', () async {
      final service = CheckInService();
      await service.openWindow(
          t, DateTime.now().add(const Duration(hours: 1)));
      await service.markLate(t, 'team-late', 'captain-late');
      final result =
          await service.closeCheckIn(t, ['team-late', 'team-missing']);
      expect(result.absentTeamIds, ['team-missing']);
    });

    test(
        'closeCheckIn: absent marking + waitlist promotion + window locked + exception report',
        () async {
      const waitlist = WaitlistService();
      final service = CheckInService(waitlist: waitlist);
      await service.openWindow(
          t, DateTime.now().add(const Duration(hours: 1)));
      // team-a checks in; team-b and team-c never do.
      await service.captainCheckIn(t, 'team-a', 'captain-a');
      // Two waitlist entries wait for freed slots.
      await waitlist.joinWaitlist(t, 'w1', teamId: 'team-w1');
      await waitlist.joinWaitlist(t, 'w2', teamId: 'team-w2');
      await waitlist.joinWaitlist(t, 'w3', teamId: 'team-w3');

      final result = await service.closeCheckIn(
          t, ['team-a', 'team-b', 'team-c']);

      // Absent marking: only the no-shows.
      expect(result.absentTeamIds, ['team-b', 'team-c']);
      final entries = await service.getEntries(t);
      expect(
          entries
              .firstWhere((e) => e.teamId == 'team-b')
              .status,
          CheckInStatus.absent);
      expect(
          entries
              .firstWhere((e) => e.teamId == 'team-a')
              .status,
          CheckInStatus.checkedIn);
      // Waitlist promotion: 2 freed slots -> first 2 promoted, in order.
      expect(result.promoted.map((e) => e.uid).toList(), ['w1', 'w2']);
      final queue = await waitlist.getWaitlist(t);
      expect(queue.map((e) => e.uid).toList(), ['w3']);
      expect(queue.first.position, 1);
      // Window locked.
      expect(result.window, CheckInWindow.closed);
      expect(await service.getWindow(t), CheckInWindow.closed);
      expect(
          await service.captainCheckIn(t, 'team-d', 'captain-d'),
          isNotNull);
      // Exception report: one item per no-show, kind OTHER (never
      // cheating/misconduct), with the forfeit rule in the detail.
      expect(result.exceptions.length, 2);
      for (final item in result.exceptions) {
        expect(item.type, ExceptionType.other);
        expect(item.detail, contains('No-show'));
        expect(item.detail, contains('forfeit'));
        expect(item.status, DisputeStatus.open);
      }
      // Persisted for the admin to review later.
      final stored = await service.getExceptions(t);
      expect(stored.length, 2);
    });

    test('no-show rule text states grace, forfeit, no refund', () {
      expect(kCheckInNoShowGraceMinutes, 10);
      expect(kNoShowRuleText, contains('10'));
      expect(kNoShowRuleText.toLowerCase(), contains('forfeit'));
      expect(kNoShowRuleText.toLowerCase(), contains('no refund'));
    });
  });

  group('team allocation', () {
    const teams = ['team-a', 'team-b', 'team-c', 'team-d'];

    test('random with seed is deterministic; slots 1..n unique', () {
      final first = allocateTeams(
          teamIds: teams,
          method: TeamAllocationMode.random,
          randomSeed: 42);
      final second = allocateTeams(
          teamIds: teams,
          method: TeamAllocationMode.random,
          randomSeed: 42);
      expect(
          first.map((s) => s.teamId).toList(),
          second.map((s) => s.teamId).toList());
      expect(first.map((s) => s.slot).toList(), [1, 2, 3, 4]);
      expect(first.map((s) => s.teamId).toSet().length, 4);
    });

    test('seeded order follows seeds ascending; unseeded last', () {
      final slots = allocateTeams(
        teamIds: teams,
        method: TeamAllocationMode.seeded,
        seeds: {'team-c': 1, 'team-a': 2},
      );
      expect(slots.map((s) => s.teamId).toList(),
          ['team-c', 'team-a', 'team-b', 'team-d']);
      expect(slots.first.seed, 1);
      expect(slots[1].seed, 2);
      expect(slots[2].seed, isNull);
    });

    test('country spread separates same-country teams', () {
      final slots = allocateTeams(
        teamIds: ['pk-1', 'pk-2', 'pk-3', 'in-1', 'in-2'],
        method: TeamAllocationMode.countryBased,
        teamCountries: {
          'pk-1': 'PK',
          'pk-2': 'PK',
          'pk-3': 'PK',
          'in-1': 'IN',
          'in-2': 'IN',
        },
      );
      // Round-robin: PK, IN, PK, IN, PK.
      expect(slots.map((s) => s.teamId).toList(),
          ['pk-1', 'in-1', 'pk-2', 'in-2', 'pk-3']);
    });

    test('performance order follows ratings descending', () {
      final slots = allocateTeams(
        teamIds: teams,
        method: TeamAllocationMode.performanceBased,
        teamRatings: {
          'team-a': 100,
          'team-b': 300,
          'team-c': 200,
        },
      );
      expect(slots.map((s) => s.teamId).toList(),
          ['team-b', 'team-c', 'team-a', 'team-d']);
    });

    test('manual order is input order', () {
      final slots = allocateTeams(
          teamIds: teams, method: TeamAllocationMode.manual);
      expect(slots.map((s) => s.teamId).toList(), teams);
      expect(slots.map((s) => s.slot).toList(), [1, 2, 3, 4]);
    });

    test('manual override swaps and keeps slots unique', () {
      final slots = allocateTeams(
          teamIds: teams, method: TeamAllocationMode.manual);
      final moved = applyManualOverride(slots, 'team-d', 1);
      expect(moved.map((s) => s.teamId).toList(),
          ['team-d', 'team-b', 'team-c', 'team-a']);
      expect(moved.map((s) => s.slot).toList(), [1, 2, 3, 4]);
      // Unknown team / out-of-range slot: unchanged / clamped.
      expect(applyManualOverride(slots, 'nope', 1),
          hasLength(slots.length));
      final clamped = applyManualOverride(slots, 'team-a', 99);
      expect(clamped.last.teamId, 'team-a');
      expect(clamped.map((s) => s.slot).toSet().length, 4);
    });
  });

  group('room release', () {
    const m = 'match-1';

    test('release before releaseAt returns empty; never early', () async {
      const service = RoomReleaseService();
      final releaseAt = DateTime.now().add(const Duration(hours: 1));
      await service.setCredentials(
          m, 'ROOM-123', 'pass-456', releaseAt, 'admin-uid');
      final tooEarly = await service.releaseRoom(
          m, ['team-a'], DateTime.now());
      expect(tooEarly, isEmpty);
      final stored = await service.getRelease(m);
      expect(stored?.isReleased, isFalse);
    });

    test('release at/after releaseAt goes only to checked-in teams',
        () async {
      const service = RoomReleaseService();
      final releaseAt = DateTime.now().subtract(const Duration(minutes: 1));
      await service.setCredentials(
          m, 'ROOM-123', 'pass-456', releaseAt, 'admin-uid');
      final released = await service.releaseRoom(
          m, ['team-a', 'team-b'], DateTime.now());
      expect(released, ['team-a', 'team-b']);
      final stored = await service.getRelease(m);
      expect(stored?.isReleased, isTrue);
      expect(stored?.roomId, 'ROOM-123');
      expect(stored?.roomPassword, 'pass-456');
      expect(await service.isReleasedTo(m, 'team-a'), isTrue);
      expect(await service.isReleasedTo(m, 'team-not-checked-in'), isFalse);
    });

    test('release with no credentials set returns empty', () async {
      const service = RoomReleaseService();
      expect(await service.releaseRoom('no-match', ['team-a'],
          DateTime.now()), isEmpty);
      expect(await service.getRelease('no-match'), isNull);
    });

    test('release log records credentials-set and release actions',
        () async {
      const service = RoomReleaseService();
      final releaseAt = DateTime.now().subtract(const Duration(minutes: 1));
      await service.setCredentials(
          m, 'ROOM-123', 'pass-456', releaseAt, 'admin-uid');
      await service.releaseRoom(m, ['team-a'], DateTime.now());
      final log = await service.getReleaseLog(m);
      expect(log.map((e) => e['action']).toList(),
          ['credentials_set', 'released']);
      expect(log.last['team_ids'], ['team-a']);
    });
  });
}
