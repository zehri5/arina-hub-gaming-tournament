// SMART TOURNAMENT BUILDER (workstream B) — unit tests for
// lib/platform/builder/*.dart.
//
// Covers: all 9 validation checks (pass + fail), draft
// toMap/fromMap round-trip incl. the elimination merge/split +
// registration mapping, schedule-kind wire values, rules-change
// impact text, the approved_paid gate, and entry-model wire values.
//
// NOTE: validation messages go through tr() — these tests run in
// English (langUrduNotifier defaults to false) and assert on the
// issue FIELDS, not the message text, so they stay green in
// either language.
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/platform/builder/builder_validation.dart';
import 'package:protournament_user/platform/builder/rules_impact.dart';
import 'package:protournament_user/platform/builder/schedule_kind.dart';
import 'package:protournament_user/platform/builder/tournament_draft.dart';
import 'package:protournament_user/platform/core/scoring.dart';
import 'package:protournament_user/platform/core/tournament_enums.dart';

TournamentDraft validDraft() {
  final now = DateTime.now().toUtc();
  return TournamentDraft(
    title: 'Weekly Cup',
    description: 'A weekly PUBG Mobile cup.',
    organizerName: 'Arena Hub',
    category: 'Weekly',
    visibility: TournamentVisibility.worldwide,
    countryCode: 'PK',
    timezone: 'Asia/Karachi',
    rules: 'No cheating. No teaming.',
    prizePool: 10000,
    perKillPrize: 50,
    gameMode: GameMode.classic,
    perspective: Perspective.tpp,
    teamMode: TeamMode.squad,
    mapPool: const ['Erangel', 'Miramar'],
    serverRegion: 'Asia',
    maxTeams: 16,
    matchCount: 3,
    stages: const [StageType.qualifier, StageType.finalStage],
    format: TournamentFormat.league,
    matchFormat: MatchFormat.cumulativePoints,
    registrationMode: RegistrationMode.teamCaptain,
    registrationStart: now.add(const Duration(days: 1)),
    registrationEnd: now.add(const Duration(days: 3)),
    minTeams: 8,
    waitlistEnabled: true,
    entryModel: EntryModel.free,
    scheduleItems: [
      ScheduleItem(
        kind: ScheduleKind.registration,
        startsAt: now.add(const Duration(days: 1)),
        endsAt: now.add(const Duration(days: 3)),
      ),
      ScheduleItem(
        kind: ScheduleKind.checkIn,
        startsAt: now.add(const Duration(days: 4)),
      ),
      ScheduleItem(
        kind: ScheduleKind.match,
        startsAt: now.add(const Duration(days: 5)),
      ),
      ScheduleItem(
        kind: ScheduleKind.results,
        startsAt: now.add(const Duration(days: 6)),
      ),
      ScheduleItem(
        kind: ScheduleKind.verificationDeadline,
        startsAt: now.add(const Duration(days: 7)),
      ),
      ScheduleItem(
        kind: ScheduleKind.leaderboardPublish,
        startsAt: now.add(const Duration(days: 8)),
      ),
    ],
    scoringTemplateId: 'default',
    scoringTemplate: kDefaultScoringTemplate,
  );
}

bool hasBlocking(List<ValidationIssue> issues, String field) =>
    issues.any((i) => i.blocking && i.field == field);

void main() {
  group('validation — valid draft passes everything', () {
    test('valid draft has no blocking issues and is publishable', () {
      final d = validDraft();
      expect(validateForPublish(d).where((i) => i.blocking), isEmpty);
      expect(d.isPublishable, isTrue);
    });

    test('publish checklist is all-pass for a valid draft', () {
      final items = publishChecklist(validDraft());
      expect(items.length, 9);
      expect(items.every((i) => i.passed), isTrue);
    });
  });

  group('validation — the 9 checks, fail cases', () {
    test('1. dates: registration end before start blocks', () {
      final d = validDraft()
        ..registrationStart = DateTime.utc(2026, 12, 5)
        ..registrationEnd = DateTime.utc(2026, 12, 1);
      expect(hasBlocking(validateForPublish(d), 'dates'), isTrue);
      expect(d.isPublishable, isFalse);
    });

    test('1. dates: match before registration closes blocks', () {
      final d = validDraft();
      d.scheduleItem(ScheduleKind.match)!.startsAt =
          d.registrationEnd!.subtract(const Duration(hours: 1));
      expect(hasBlocking(validateForPublish(d), 'dates'), isTrue);
    });

    test('1. dates: missing registration window blocks', () {
      final d = validDraft()
        ..registrationStart = null
        ..registrationEnd = null;
      expect(hasBlocking(validateForPublish(d), 'dates'), isTrue);
    });

    test('2. maps: empty map pool blocks', () {
      final d = validDraft()..mapPool = [];
      expect(hasBlocking(validateForPublish(d), 'mapPool'), isTrue);
    });

    test('3. scoring: empty template id / empty table blocks', () {
      final noId = validDraft()..scoringTemplateId = '';
      expect(
          hasBlocking(validateForPublish(noId), 'scoring'), isTrue);
      final noTable = validDraft()
        ..scoringTemplateId = 'custom'
        ..scoringTemplate = kCustomScoringTemplate;
      expect(
          hasBlocking(validateForPublish(noTable), 'scoring'), isTrue);
    });

    test('4. capacity: maxTeams below 2 blocks', () {
      final d = validDraft()..maxTeams = 1;
      expect(hasBlocking(validateForPublish(d), 'maxTeams'), isTrue);
      final zero = validDraft()..maxTeams = 0;
      expect(
          hasBlocking(validateForPublish(zero), 'maxTeams'), isTrue);
    });

    test('5. rules: empty rules block', () {
      final d = validDraft()..rules = '   ';
      expect(hasBlocking(validateForPublish(d), 'rules'), isTrue);
    });

    test('6. schedule: missing required kind blocks', () {
      final d = validDraft()
        ..scheduleItems.removeWhere(
            (s) => s.kind == ScheduleKind.checkIn);
      expect(hasBlocking(validateForPublish(d), 'schedule'), isTrue);
    });

    test('6. schedule: missing optional kinds are warnings only', () {
      final d = validDraft()
        ..scheduleItems.removeWhere((s) =>
            s.kind == ScheduleKind.verificationDeadline ||
            s.kind == ScheduleKind.leaderboardPublish);
      final issues = validateForPublish(d);
      expect(hasBlocking(issues, 'schedule'), isFalse);
      expect(
          issues
              .where((i) => !i.blocking && i.field == 'schedule')
              .length,
          2);
      expect(d.isPublishable, isTrue);
    });

    test('7. region/server: country-scoped without server region blocks',
        () {
      final d = validDraft()
        ..visibility = TournamentVisibility.countryOnly
        ..serverRegion = '';
      expect(
          hasBlocking(validateForPublish(d), 'serverRegion'), isTrue);
    });

    test('7. region/server: selected countries without a country blocks',
        () {
      final d = validDraft()
        ..visibility = TournamentVisibility.selectedCountries
        ..allowedCountryCodes = [];
      expect(hasBlocking(validateForPublish(d), 'allowedCountryCodes'),
          isTrue);
    });

    test('7. region/server: worldwide without server region passes', () {
      final d = validDraft()
        ..visibility = TournamentVisibility.worldwide
        ..serverRegion = '';
      expect(
          hasBlocking(validateForPublish(d), 'serverRegion'), isFalse);
    });

    test('8. prize: zero prize pool blocks', () {
      final d = validDraft()..prizePool = 0;
      expect(hasBlocking(validateForPublish(d), 'prizePool'), isTrue);
    });

    test('9. policies: free entry needs no policies', () {
      final d = validDraft()
        ..entryModel = EntryModel.free
        ..refundPolicy = ''
        ..cancellationPolicy = ''
        ..postponementPolicy = '';
      final issues = validateForPublish(d);
      expect(hasBlocking(issues, 'refundPolicy'), isFalse);
      expect(hasBlocking(issues, 'cancellationPolicy'), isFalse);
      expect(hasBlocking(issues, 'postponementPolicy'), isFalse);
    });

    test('9. policies: approvedPaid without policies blocks', () {
      final d = validDraft()
        ..entryModel = EntryModel.approvedPaid
        ..entryFee = 20
        ..paidApprovedAt = DateTime.now().toUtc()
        ..paidApprovedBy = 'super-admin-uid'
        ..refundPolicy = ''
        ..cancellationPolicy = ''
        ..postponementPolicy = '';
      final issues = validateForPublish(d);
      expect(hasBlocking(issues, 'refundPolicy'), isTrue);
      expect(hasBlocking(issues, 'cancellationPolicy'), isTrue);
      expect(hasBlocking(issues, 'postponementPolicy'), isTrue);
    });

    test('title: empty title blocks', () {
      final d = validDraft()..title = '';
      expect(hasBlocking(validateForPublish(d), 'title'), isTrue);
    });
  });

  group('approved_paid gate', () {
    test('blocked without approval flags', () {
      final d = validDraft()
        ..entryModel = EntryModel.approvedPaid
        ..entryFee = 20
        ..refundPolicy = 'Full refund before check-in.'
        ..cancellationPolicy = 'Full refund if cancelled.'
        ..postponementPolicy = 'Fee carries to the new date.';
      expect(hasBlocking(validateForPublish(d), 'entryModel'), isTrue);
      expect(d.isPublishable, isFalse);
      final checklist = publishChecklist(d);
      expect(checklist.length, 10);
      expect(
          checklist
              .firstWhere((c) => c.key == 'paidApproval')
              .passed,
          isFalse);
    });

    test('allowed with approval flags + fee + policies', () {
      final d = validDraft()
        ..entryModel = EntryModel.approvedPaid
        ..entryFee = 20
        ..paidApprovedAt = DateTime.now().toUtc()
        ..paidApprovedBy = 'super-admin-uid'
        ..refundPolicy = 'Full refund before check-in.'
        ..cancellationPolicy = 'Full refund if cancelled.'
        ..postponementPolicy = 'Fee carries to the new date.';
      expect(validateForPublish(d).where((i) => i.blocking), isEmpty);
      expect(d.isPublishable, isTrue);
      expect(
          publishChecklist(d)
              .firstWhere((c) => c.key == 'paidApproval')
              .passed,
          isTrue);
    });

    test('blocked with approval flags but no fee', () {
      final d = validDraft()
        ..entryModel = EntryModel.approvedPaid
        ..entryFee = 0
        ..paidApprovedAt = DateTime.now().toUtc()
        ..paidApprovedBy = 'super-admin-uid'
        ..refundPolicy = 'r'
        ..cancellationPolicy = 'c'
        ..postponementPolicy = 'p';
      expect(hasBlocking(validateForPublish(d), 'entryFee'), isTrue);
    });
  });

  group('draft toMap/fromMap round-trip', () {
    test('all fields survive a round-trip', () {
      final d = validDraft()
        ..id = 'draft-1'
        ..serverId = 'srv-1'
        ..status = 'published'
        ..organizationId = 'org-1'
        ..logoUrl = 'https://example.com/logo.png'
        ..bannerUrl = 'https://example.com/banner.png'
        ..allowedCountryCodes = ['PK', 'SA']
        ..language = 'ur'
        ..contactInfo = 'admin@example.com'
        ..supportInfo = 'support@example.com'
        ..substituteLimit = 1
        ..rosterLockAt = DateTime.utc(2026, 12, 4, 12)
        ..substitutePolicy = 'One substitute per team.'
        ..waitlistEnabled = true
        ..verificationRequired = true;
      final back = TournamentDraft.fromMap(d.toMap());
      expect(back.id, 'draft-1');
      expect(back.serverId, 'srv-1');
      expect(back.status, 'published');
      expect(back.organizationId, 'org-1');
      expect(back.title, 'Weekly Cup');
      expect(back.logoUrl, 'https://example.com/logo.png');
      expect(back.bannerUrl, 'https://example.com/banner.png');
      expect(back.allowedCountryCodes, ['PK', 'SA']);
      expect(back.language, 'ur');
      expect(back.contactInfo, 'admin@example.com');
      expect(back.supportInfo, 'support@example.com');
      expect(back.prizePool, 10000);
      expect(back.perKillPrize, 50);
      expect(back.mapPool, ['Erangel', 'Miramar']);
      expect(back.maxTeams, 16);
      expect(back.maxPlayers, 64);
      expect(back.substituteLimit, 1);
      expect(back.rosterLockAt, DateTime.utc(2026, 12, 4, 12));
      expect(back.substitutePolicy, 'One substitute per team.');
      expect(back.waitlistEnabled, isTrue);
      expect(back.verificationRequired, isTrue);
      expect(back.scheduleItems.length, 6);
      expect(back.scheduleItems[2].kind, ScheduleKind.match);
      expect(back.scoringTemplateId, 'default');
      expect(back.scoringTemplate.placementPoints[1], 10);
      expect(back.scoringTemplate.killPoints, 1);
    });

    test('elimination merge: knockout writes single/double', () {
      final d = validDraft()
        ..format = TournamentFormat.knockout
        ..elimination = EliminationType.double
        ..matchFormat = MatchFormat.swiss;
      expect(d.toMap()['elimination'], 'double');
      final back = TournamentDraft.fromMap(d.toMap());
      expect(back.elimination, EliminationType.double);
      // The non-authoritative side falls back to its default.
      expect(back.matchFormat, MatchFormat.cumulativePoints);
    });

    test('elimination merge: league writes the match format', () {
      final d = validDraft()
        ..format = TournamentFormat.league
        ..elimination = EliminationType.double
        ..matchFormat = MatchFormat.roundRobin;
      expect(d.toMap()['elimination'], 'round_robin');
      final back = TournamentDraft.fromMap(d.toMap());
      expect(back.matchFormat, MatchFormat.roundRobin);
      expect(back.elimination, EliminationType.single);
    });

    test('elimination split: cumulative wire value restores match format',
        () {
      final back = TournamentDraft.fromMap({
        'elimination': 'cumulative',
        'format': 'league',
      });
      expect(back.matchFormat, MatchFormat.cumulativePoints);
      expect(back.elimination, EliminationType.single);
    });

    test('registration mapping: teamCaptain -> team + captain', () {
      final d = validDraft()
        ..registrationMode = RegistrationMode.teamCaptain;
      final map = d.toMap();
      expect(map['registration_type'], 'team');
      expect(map['registrant'], 'captain');
      final back = TournamentDraft.fromMap(map);
      expect(back.registrationMode, RegistrationMode.teamCaptain);
    });

    test('registration mapping: individual -> individual + each_player',
        () {
      final d = validDraft()
        ..registrationMode = RegistrationMode.individual;
      final map = d.toMap();
      expect(map['registration_type'], 'individual');
      expect(map['registrant'], 'each_player');
      final back = TournamentDraft.fromMap(map);
      expect(back.registrationMode, RegistrationMode.individual);
    });

    test('registration mapping: fromMap falls back to registrant', () {
      final back = TournamentDraft.fromMap({'registrant': 'captain'});
      expect(back.registrationMode, RegistrationMode.teamCaptain);
    });
  });

  group('schedule kinds', () {
    test('wire values match the guide', () {
      expect(ScheduleKind.registration.wireValue, 'registration');
      expect(ScheduleKind.checkIn.wireValue, 'check_in');
      expect(ScheduleKind.match.wireValue, 'match');
      expect(ScheduleKind.results.wireValue, 'results');
      expect(ScheduleKind.verificationDeadline.wireValue,
          'verification_deadline');
      expect(ScheduleKind.leaderboardPublish.wireValue,
          'leaderboard_publish');
    });

    test('fromString parses wire values and falls back', () {
      expect(ScheduleKind.fromString('check_in'), ScheduleKind.checkIn);
      expect(ScheduleKind.fromString('verification_deadline'),
          ScheduleKind.verificationDeadline);
      expect(ScheduleKind.fromString('nonsense'), ScheduleKind.match);
    });

    test('required kinds are registration, check-in, match, results', () {
      expect(kRequiredScheduleKinds, [
        ScheduleKind.registration,
        ScheduleKind.checkIn,
        ScheduleKind.match,
        ScheduleKind.results,
      ]);
    });
  });

  group('rules-change impact', () {
    test('0 registrations -> empty', () {
      expect(
          rulesChangeImpact(
            registrationCount: 0,
            verifiedResultsCount: 0,
            scoringChanged: true,
            scheduleChanged: true,
          ),
          isEmpty);
    });

    test('registrations but no change -> empty', () {
      expect(
          rulesChangeImpact(
            registrationCount: 12,
            verifiedResultsCount: 3,
            scoringChanged: false,
            scheduleChanged: false,
          ),
          isEmpty);
    });

    test('registrations + scoring change -> warns, verified results safe',
        () {
      final text = rulesChangeImpact(
        registrationCount: 12,
        verifiedResultsCount: 3,
        scoringChanged: true,
        scheduleChanged: false,
      );
      expect(text, isNotEmpty);
      expect(text, contains('12'));
      expect(text, contains('3'));
      expect(text, contains('NOT be rescored'));
      expect(text, contains('future matches only'));
    });

    test('schedule change -> tells organizer to inform teams', () {
      final text = rulesChangeImpact(
        registrationCount: 5,
        verifiedResultsCount: 0,
        scoringChanged: false,
        scheduleChanged: true,
      );
      expect(text, contains('5'));
      expect(text, contains('new times'));
    });
  });

  group('entry-model wire values', () {
    test('all four models map to the guide strings', () {
      expect(EntryModel.free.wireValue, 'free');
      expect(EntryModel.sponsored.wireValue, 'sponsored');
      expect(EntryModel.organizerFunded.wireValue, 'organizer_funded');
      expect(EntryModel.approvedPaid.wireValue, 'approved_paid');
    });

    test('fromString parses approved_paid', () {
      expect(EntryModel.fromString('approved_paid'),
          EntryModel.approvedPaid);
    });
  });
}
