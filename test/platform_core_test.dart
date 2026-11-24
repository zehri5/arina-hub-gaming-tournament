// PLATFORM CORE (workstream A — foundation) — unit tests for
// lib/platform/core/*.dart. Contracts pinned here are BINDING for
// the later workstreams: do not change a pinned value without
// updating the workstream briefs.
//
// SCORING NOTE: the DEFAULT template is the decided model
// (1st = 10 + 1/kill); the live 022 server table (1st = 15) is kept
// as kLegacy022ScoringTemplate until the backend updates 022.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/platform/core/exceptions.dart';
import 'package:protournament_user/platform/core/lifecycle.dart';
import 'package:protournament_user/platform/core/local_store.dart';
import 'package:protournament_user/platform/core/organization.dart';
import 'package:protournament_user/platform/core/regions.dart';
import 'package:protournament_user/platform/core/roles.dart';
import 'package:protournament_user/platform/core/scoring.dart';
import 'package:protournament_user/platform/core/screens/country_select_page.dart';
import 'package:protournament_user/platform/core/screens/language_settings_page.dart';
import 'package:protournament_user/platform/core/tournament_enums.dart';
import 'package:protournament_user/utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    // Language tests flip the global notifier — always reset.
    langUrduNotifier.value = false;
  });

  group('scoring', () {
    test('default template: 1st + 12 kills = 22 (decided model)', () {
      expect(
          calculateMatchPoints(placement: 1, kills: 12), 22);
      expect(
          calculateMatchPoints(
              placement: 1, kills: 12, template: kDefaultScoringTemplate),
          22);
    });

    test('legacy 022 template: 1st + 12 kills = 27 (live server)', () {
      expect(
          calculateMatchPoints(
              placement: 1, kills: 12, template: kLegacy022ScoringTemplate),
          27);
    });

    test('default table matches the decided standard table (Sameer 2026-11-21 02:20: 1st=10, 2nd=7, 3rd=5, 4th+=0)', () {
      expect(kDefaultScoringTemplate.placementPoints,
          {1: 10, 2: 7, 3: 5});
      expect(kDefaultScoringTemplate.killPoints, 1);
      expect(kDefaultScoringTemplate.isOfficialStyle, isTrue);
    });

    test('legacy 022 table matches migration 022 exactly', () {
      expect(kLegacy022ScoringTemplate.placementPoints,
          {1: 15, 2: 12, 3: 10, 4: 8, 5: 6, 6: 4, 7: 2, 8: 2});
      expect(kLegacy022ScoringTemplate.killPoints, 1);
    });

    test('9th place scores kills only, both templates', () {
      expect(calculateMatchPoints(placement: 9, kills: 5), 5);
      expect(
          calculateMatchPoints(
              placement: 9, kills: 5, template: kLegacy022ScoringTemplate),
          5);
    });

    test('placement <= 0 scores 0', () {
      expect(calculateMatchPoints(placement: 0, kills: 10), 0);
      expect(calculateMatchPoints(placement: -2, kills: 10), 0);
    });

    test('negative kills count as 0 (placement only)', () {
      expect(calculateMatchPoints(placement: 1, kills: -5), 10);
      expect(
          calculateMatchPoints(
              placement: 3, kills: -1, template: kLegacy022ScoringTemplate),
          10);
    });

    test('custom template starts empty (kills only)', () {
      expect(
          calculateMatchPoints(
              placement: 1, kills: 3, template: kCustomScoringTemplate),
          3);
    });

    test('ScoringTemplate fromMap/toMap round-trip', () {
      const t = ScoringTemplate(
        id: 't1',
        organizationId: 'org-1',
        name: 'Test',
        placementPoints: {1: 10, 2: 6},
        killPoints: 2,
        bonusRules: ['win streak'],
        penalties: ['late -5'],
        tieBreakers: ['kills'],
        disqualifyOn: ['cheating'],
        isOfficialStyle: true,
      );
      final back = ScoringTemplate.fromMap(t.toMap());
      expect(back.id, 't1');
      expect(back.organizationId, 'org-1');
      expect(back.name, 'Test');
      expect(back.placementPoints, {1: 10, 2: 6});
      expect(back.killPoints, 2);
      expect(back.bonusRules, ['win streak']);
      expect(back.penalties, ['late -5']);
      expect(back.tieBreakers, ['kills']);
      expect(back.disqualifyOn, ['cheating']);
      expect(back.isOfficialStyle, isTrue);
      // toMap uses the guide's snake_case column names.
      expect(t.toMap()['placement_points'], {'1': 10, '2': 6});
      expect(t.toMap()['is_official_style'], isTrue);
    });

    test('Season fromMap/toMap round-trip, weighting defaults to 1.0', () {
      const s = Season(
        id: 's1',
        organizationId: null,
        name: 'Season 1',
        status: SeasonStatus.active,
        weighting: 1.5,
      );
      final back = Season.fromMap(s.toMap());
      expect(back.id, 's1');
      expect(back.organizationId, isNull);
      expect(back.name, 'Season 1');
      expect(back.status, SeasonStatus.active);
      expect(back.weighting, 1.5);
      expect(Season.fromMap({'id': 's2', 'name': 'S2'}).weighting, 1.0);
      expect(Season.fromMap({'id': 's3', 'name': 'S3'}).status,
          SeasonStatus.upcoming);
    });
  });

  group('roles', () {
    test('superAdmin can do everything', () {
      const r = AppRole.superAdmin;
      expect(RoleService.canCreateTournament(r), isTrue);
      expect(RoleService.canVerifyResults(r), isTrue);
      expect(RoleService.canManageOrganizers(r), isTrue);
      expect(RoleService.canManageCountry(r), isTrue);
      expect(RoleService.canViewFinancials(r), isTrue);
      expect(RoleService.canModerate(r), isTrue);
    });

    test('player can do nothing privileged', () {
      const r = AppRole.player;
      expect(RoleService.canCreateTournament(r), isFalse);
      expect(RoleService.canVerifyResults(r), isFalse);
      expect(RoleService.canManageOrganizers(r), isFalse);
      expect(RoleService.canManageCountry(r), isFalse);
      expect(RoleService.canViewFinancials(r), isFalse);
      expect(RoleService.canModerate(r), isFalse);
    });

    test('organizer: create + verify + financials only', () {
      const r = AppRole.organizer;
      expect(RoleService.canCreateTournament(r), isTrue);
      expect(RoleService.canVerifyResults(r), isTrue);
      expect(RoleService.canManageOrganizers(r), isFalse);
      expect(RoleService.canManageCountry(r), isFalse);
      expect(RoleService.canViewFinancials(r), isTrue);
      expect(RoleService.canModerate(r), isFalse);
    });

    test('regionalAdmin: everything except nothing', () {
      const r = AppRole.regionalAdmin;
      expect(RoleService.canCreateTournament(r), isTrue);
      expect(RoleService.canVerifyResults(r), isTrue);
      expect(RoleService.canManageOrganizers(r), isTrue);
      expect(RoleService.canManageCountry(r), isTrue);
      expect(RoleService.canViewFinancials(r), isTrue);
      expect(RoleService.canModerate(r), isTrue);
    });

    test('roleOf resolves profile fields', () {
      expect(RoleService.roleOf({}), AppRole.player);
      expect(RoleService.roleOf({'role': 'organizer'}), AppRole.organizer);
      expect(RoleService.roleOf({'role': 'regional_admin'}),
          AppRole.regionalAdmin);
      expect(RoleService.roleOf({'role': 'regionalAdmin'}),
          AppRole.regionalAdmin);
      expect(RoleService.roleOf({'is_organizer': true}), AppRole.organizer);
      expect(RoleService.roleOf({'is_regional_admin': true}),
          AppRole.regionalAdmin);
    });

    test('superAdmin only via the flag, never from a profile string', () {
      expect(RoleService.roleOf({'role': 'super_admin'}), AppRole.player);
      expect(RoleService.roleOf({'role': 'superAdmin'}), AppRole.player);
      expect(RoleService.roleOf({}, isSuperAdmin: true), AppRole.superAdmin);
      expect(RoleService.roleOf({'role': 'player'}, isSuperAdmin: true),
          AppRole.superAdmin);
    });

    test('AppRole wire values are the guide snake_case strings', () {
      expect(AppRole.regionalAdmin.wireValue, 'regional_admin');
      expect(AppRole.superAdmin.wireValue, 'super_admin');
      expect(AppRole.fromString('super_admin'), AppRole.superAdmin);
      expect(AppRole.fromString('nonsense'), AppRole.player);
    });
  });

  group('countries', () {
    test('PK first, 12 countries, unique codes', () {
      expect(kSupportedCountries.length, 12);
      expect(kSupportedCountries.first.code, 'PK');
      final codes = kSupportedCountries.map((c) => c.code).toList();
      expect(codes.toSet().length, codes.length);
      expect(
          codes,
          containsAll(
              ['PK', 'SA', 'AE', 'IN', 'BD', 'GB', 'US', 'DE', 'FR', 'TR', 'ID', 'MY']));
    });

    test('every country has timezone, currency and is enabled', () {
      for (final c in kSupportedCountries) {
        expect(c.timezone, isNotEmpty, reason: c.code);
        expect(c.currencyCode, isNotEmpty, reason: c.code);
        expect(c.currencySymbol, isNotEmpty, reason: c.code);
        expect(c.languageCodes, isNotEmpty, reason: c.code);
        expect(c.enabled, isTrue, reason: c.code);
      }
    });

    test('Country fromMap/toMap uses guide column names', () {
      final pk = kSupportedCountries.first;
      final map = pk.toMap();
      expect(map['code'], 'PK');
      expect(map['default_currency'], 'PKR');
      expect(map['default_timezone'], 'Asia/Karachi');
      expect(map['default_language'], 'en');
      final back = Country.fromMap(map);
      expect(back.code, 'PK');
      expect(back.currencyCode, 'PKR');
      expect(back.currencySymbol, 'Rs');
      expect(back.timezone, 'Asia/Karachi');
      expect(back.enabled, isTrue);
    });
  });

  group('regions service', () {
    test('formatCurrency: 0 decimals for PKR, 2 for USD', () {
      final pk = RegionService.countryFor('PK');
      final us = RegionService.countryFor('US');
      expect(RegionService.formatCurrency(1000, pk), 'Rs 1000');
      expect(RegionService.formatCurrency(25.5, us), '\$ 25.50');
    });

    test('formatInTimezone shows UTC time + zone name', () {
      final out = RegionService.formatInTimezone(
          DateTime.utc(2026, 11, 21, 14, 30), 'Asia/Karachi');
      expect(out, '14:30 UTC (Asia/Karachi)');
    });

    test('country selection persists, unknown codes ignored', () async {
      expect(await RegionService.getSelectedCountryCode(), 'PK');
      expect(await RegionService.setSelectedCountryCode('IN'), isTrue);
      expect(await RegionService.getSelectedCountryCode(), 'IN');
      expect(await RegionService.setSelectedCountryCode('XX'), isFalse);
      expect(await RegionService.getSelectedCountryCode(), 'IN');
    });

    test('language reuses the app_language key + notifier', () async {
      expect(await RegionService.getLanguageCode(), 'en');
      expect(await RegionService.setLanguageCode('ur'), isTrue);
      expect(await RegionService.getLanguageCode(), 'ur');
      expect(langUrduNotifier.value, isTrue);
      // The value lives under the EXISTING key, not a new one.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_language'), 'ur');
      expect(await RegionService.setLanguageCode('en'), isTrue);
      expect(langUrduNotifier.value, isFalse);
    });
  });

  group('organization', () {
    test('Organization fromMap/toMap round-trip', () {
      const org = Organization(
        id: 'org-1',
        name: 'Quetta Esports',
        slug: 'quetta-esports',
        logoUrl: 'https://x/logo.png',
        description: 'Best org',
        countryCode: 'PK',
        ownerUid: 'uid-1',
        verified: true,
        status: OrganizationStatus.active,
        tier: OrganizationTier.professional,
      );
      final back = Organization.fromMap(org.toMap());
      expect(back.id, 'org-1');
      expect(back.name, 'Quetta Esports');
      expect(back.slug, 'quetta-esports');
      expect(back.logoUrl, 'https://x/logo.png');
      expect(back.description, 'Best org');
      expect(back.countryCode, 'PK');
      expect(back.ownerUid, 'uid-1');
      expect(back.verified, isTrue);
      expect(back.status, OrganizationStatus.active);
      expect(back.tier, OrganizationTier.professional);
      expect(org.toMap()['owner_firebase_uid'], 'uid-1');
      expect(org.toMap()['country_code'], 'PK');
    });

    test('OrganizerApplication round-trip; pending wires as applied', () {
      const app = OrganizerApplication(
        id: 'app-1',
        orgName: 'Quetta Esports',
        countryCode: 'PK',
        applicantUid: 'uid-1',
        status: OrganizerApplicationStatus.pending,
      );
      expect(app.toMap()['status'], 'applied');
      expect(app.toMap()['firebase_uid'], 'uid-1');
      expect(app.toMap()['organization_name'], 'Quetta Esports');
      final back = OrganizerApplication.fromMap(app.toMap());
      expect(back.status, OrganizerApplicationStatus.pending);
      expect(back.applicantUid, 'uid-1');
      // The guide's 'applied' value parses to pending.
      expect(OrganizerApplicationStatus.fromString('applied'),
          OrganizerApplicationStatus.pending);
    });

    test('OrganizationMemberRole + status parsing', () {
      expect(OrganizationMemberRole.fromString('referee'),
          OrganizationMemberRole.referee);
      expect(OrganizationMemberRole.fromString('owner'),
          OrganizationMemberRole.owner);
      expect(OrganizationStatus.fromString('suspended'),
          OrganizationStatus.suspended);
      expect(OrganizationTier.fromString('enterprise'),
          OrganizationTier.enterprise);
    });
  });

  group('lifecycle', () {
    test('NotificationEvent has exactly 10 values', () {
      expect(NotificationEvent.values.length, 10);
    });

    test('notificationContent returns title + body for every event', () {
      for (final e in NotificationEvent.values) {
        final c = notificationContent(e, {'tournament': 'Cup 1'});
        expect(c.title, isNotEmpty, reason: e.name);
        expect(c.body, isNotEmpty, reason: e.name);
        expect(c.body, contains('Cup 1'), reason: e.name);
      }
    });

    test('CheckInStatus is exactly checkedIn/absent/late', () {
      expect(CheckInStatus.values.length, 3);
      expect(CheckInStatus.fromString('checked_in'), CheckInStatus.checkedIn);
      expect(CheckInStatus.checkedIn.wireValue, 'checked_in');
    });

    test('CheckInWindow is notOpened/open/closed', () {
      expect(CheckInWindow.values.length, 3);
      expect(CheckInWindow.fromString('open'), CheckInWindow.open);
    });

    test('WaitlistStatus round-trips', () {
      for (final s in WaitlistStatus.values) {
        expect(WaitlistStatus.fromString(s.wireValue), s);
      }
    });
  });

  group('exceptions', () {
    test('ExceptionType has exactly 8 kinds incl. other', () {
      expect(ExceptionType.values.length, 8);
      expect(ExceptionType.values, contains(ExceptionType.other));
      expect(ExceptionType.fromString('fake_evidence'),
          ExceptionType.fakeEvidence);
      expect(ExceptionType.cheating.severity, ExceptionSeverity.high);
      expect(ExceptionType.other.severity, ExceptionSeverity.low);
    });

    test('DisputeStatus is exactly open/underReview/resolved/rejected', () {
      expect(DisputeStatus.values.length, 4);
      expect(DisputeStatus.fromString('under_review'),
          DisputeStatus.underReview);
      expect(DisputeStatus.underReview.wireValue, 'under_review');
    });

    test('ActionItem fromMap/toMap round-trip', () {
      const item = ActionItem(
        id: 'a1',
        type: ExceptionType.fakeEvidence,
        title: 'Fake screenshot',
        detail: 'Edited image',
        tournamentId: 't1',
        targetUid: 'uid-9',
        status: DisputeStatus.open,
      );
      final back = ActionItem.fromMap(item.toMap());
      expect(back.id, 'a1');
      expect(back.type, ExceptionType.fakeEvidence);
      expect(back.title, 'Fake screenshot');
      expect(back.tournamentId, 't1');
      expect(back.targetUid, 'uid-9');
      expect(back.status, DisputeStatus.open);
      expect(item.toMap()['kind'], 'fake_evidence');
    });
  });

  group('tournament enums', () {
    test('fromString round-trips every value', () {
      for (final v in TournamentVisibility.values) {
        expect(TournamentVisibility.fromString(v.wireValue), v);
      }
      for (final v in EntryModel.values) {
        expect(EntryModel.fromString(v.wireValue), v);
      }
      for (final v in PaymentStatus.values) {
        expect(PaymentStatus.fromString(v.wireValue), v);
      }
      for (final v in GameMode.values) {
        expect(GameMode.fromString(v.wireValue), v);
      }
      for (final v in Perspective.values) {
        expect(Perspective.fromString(v.wireValue), v);
      }
      for (final v in TeamMode.values) {
        expect(TeamMode.fromString(v.wireValue), v);
      }
      for (final v in TournamentFormat.values) {
        expect(TournamentFormat.fromString(v.wireValue), v);
      }
      for (final v in EliminationType.values) {
        expect(EliminationType.fromString(v.wireValue), v);
      }
      for (final v in StageType.values) {
        expect(StageType.fromString(v.wireValue), v);
      }
      for (final v in MatchFormat.values) {
        expect(MatchFormat.fromString(v.wireValue), v);
      }
      for (final v in RegistrationMode.values) {
        expect(RegistrationMode.fromString(v.wireValue), v);
      }
      for (final v in TeamAllocationMode.values) {
        expect(TeamAllocationMode.fromString(v.wireValue), v);
      }
      for (final v in LeaderboardScope.values) {
        expect(LeaderboardScope.fromString(v.wireValue), v);
      }
    });

    test('guide aliases parse', () {
      expect(StageType.fromString('final'), StageType.finalStage);
      expect(MatchFormat.fromString('cumulative'),
          MatchFormat.cumulativePoints);
      expect(TeamAllocationMode.fromString('country'),
          TeamAllocationMode.countryBased);
      expect(TeamAllocationMode.fromString('performance'),
          TeamAllocationMode.performanceBased);
      expect(TournamentVisibility.fromString('country_only'),
          TournamentVisibility.countryOnly);
      expect(EntryModel.fromString('organizer_funded'),
          EntryModel.organizerFunded);
      expect(PaymentStatus.fromString('under_review'),
          PaymentStatus.underReview);
    });

    test('unknown values fall back instead of throwing', () {
      expect(TournamentVisibility.fromString('nope'),
          TournamentVisibility.worldwide);
      expect(EntryModel.fromString(null), EntryModel.free);
      expect(TeamMode.fromString(''), TeamMode.squad);
    });
  });

  group('local store', () {
    test('draft save/load/delete round-trip', () async {
      expect(await PlatformLocalStore.loadDraft('builder', 'd1'), isNull);
      expect(
          await PlatformLocalStore.saveDraft(
              'builder', 'd1', {'title': 'Cup', 'n': 3}),
          isTrue);
      expect(await PlatformLocalStore.loadDraft('builder', 'd1'),
          {'title': 'Cup', 'n': 3});
      expect(await PlatformLocalStore.deleteDraft('builder', 'd1'), isTrue);
      expect(await PlatformLocalStore.loadDraft('builder', 'd1'), isNull);
    });

    test('list save/load round-trip, missing list is []', () async {
      expect(await PlatformLocalStore.loadList('waitlist', 't1'), isEmpty);
      expect(
          await PlatformLocalStore.saveList('waitlist', 't1', [
            {'uid': 'a', 'pos': 1},
            {'uid': 'b', 'pos': 2},
          ]),
          isTrue);
      expect(await PlatformLocalStore.loadList('waitlist', 't1'),
          [
            {'uid': 'a', 'pos': 1},
            {'uid': 'b', 'pos': 2},
          ]);
    });
  });

  group('screens smoke', () {
    testWidgets('CountrySelectPage lists countries; tap persists selection',
        (tester) async {
      await tester.pumpWidget(
          const MaterialApp(home: CountrySelectPage()));
      await tester.pumpAndSettle();
      expect(find.text('Select Country'), findsOneWidget);
      expect(find.text('Pakistan'), findsWidgets);
      expect(find.text('India'), findsOneWidget);
      await tester.tap(find.text('India'));
      await tester.pumpAndSettle();
      expect(await RegionService.getSelectedCountryCode(), 'IN');
    });

    testWidgets('LanguageSettingsPage shows both languages',
        (tester) async {
      await tester.pumpWidget(
          const MaterialApp(home: LanguageSettingsPage()));
      await tester.pumpAndSettle();
      expect(find.text('Language'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('Urdu (Roman)'), findsOneWidget);
    });
  });
}
