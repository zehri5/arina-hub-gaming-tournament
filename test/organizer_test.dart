// ORGANIZER MARKETPLACE + SUPER ADMIN (workstream E) — unit tests
// for lib/platform/organizer/organizer_service.dart and the tier model
// (lib/platform/core/organization.dart).
// FIX 32 (2026-11-24): the country-toggle group (CountryAdminService,
// admin panel) was removed with the panel.
//
// Everything here runs against mocked SharedPreferences
// (PlatformLocalStore) — no Supabase, no network.
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/platform/core/organization.dart';
import 'package:protournament_user/platform/organizer/organizer_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

OrganizerApplication _app({
  String uid = 'user-1',
  String orgName = 'Quetta Esports Club',
  String countryCode = 'PK',
  OrganizerApplicationStatus status = OrganizerApplicationStatus.pending,
  String reviewNote = '',
}) =>
    OrganizerApplication(
      id: 'app_$uid',
      orgName: orgName,
      countryCode: countryCode,
      applicantUid: uid,
      status: status,
      submittedAt: DateTime.utc(2026, 11, 21),
      reviewNote: reviewNote,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('application validation', () {
    test('org name is required', () {
      final errors =
          OrganizerService.validateApplication(_app(orgName: '   '));
      expect(errors, isNotEmpty);
      expect(errors.any((e) => e.toLowerCase().contains('name')), isTrue);
    });

    test('country is required', () {
      final errors =
          OrganizerService.validateApplication(_app(countryCode: ''));
      expect(errors, isNotEmpty);
      expect(errors.any((e) => e.toLowerCase().contains('country')), isTrue);
    });

    test('valid application has no errors', () {
      expect(OrganizerService.validateApplication(_app()), isEmpty);
    });

    test('missing applicant UID is an error', () {
      final errors =
          OrganizerService.validateApplication(_app(uid: ''));
      expect(errors, isNotEmpty);
    });
  });

  group('application status flow', () {
    test('save + getMyApplication round-trip; wire value is applied', () async {
      const service = OrganizerService();
      expect(await service.saveApplication(_app()), isTrue);
      final loaded = await service.getMyApplication('user-1');
      expect(loaded, isNotNull);
      expect(loaded!.orgName, 'Quetta Esports Club');
      expect(loaded.status, OrganizerApplicationStatus.pending);
      // The Dart value is `pending`; the wire value is the guide's
      // `applied` (organizer_applications.status).
      expect(loaded.toMap()['status'], 'applied');
      expect(await service.getMyApplication('nobody'), isNull);
    });

    test('pending -> under review, and only from pending', () async {
      const service = OrganizerService();
      await service.saveApplication(_app());
      final app = (await service.getMyApplication('user-1'))!;
      expect(await service.markApplicationUnderReview(app), isTrue);
      final updated = (await service.getMyApplication('user-1'))!;
      expect(updated.status, OrganizerApplicationStatus.underReview);
      // A second move is rejected (already under review).
      expect(await service.markApplicationUnderReview(updated), isFalse);
    });

    test('applied -> approved creates the organization + owner row', () async {
      const service = OrganizerService();
      await service.saveApplication(_app());
      final app = (await service.getMyApplication('user-1'))!;
      final org =
          await service.approveApplication(app, reviewerUid: 'admin-1');
      expect(org, isNotNull);
      expect(org!.name, 'Quetta Esports Club');
      expect(org.slug, 'quetta-esports-club');
      expect(org.status, OrganizationStatus.active);
      expect(org.tier, OrganizationTier.starter);
      expect(org.ownerUid, 'user-1');
      expect(org.countryCode, 'PK');

      final updatedApp = (await service.getMyApplication('user-1'))!;
      expect(updatedApp.status, OrganizerApplicationStatus.approved);
      expect(updatedApp.reviewedAt, isNotNull);

      final myOrg = await service.getMyOrganization('user-1');
      expect(myOrg, isNotNull);
      expect(myOrg!.id, org.id);

      final staff = await service.listStaff(org.id);
      expect(staff.length, 1);
      expect(staff.first.uid, 'user-1');
      expect(staff.first.role, OrganizationMemberRole.owner);
      expect(staff.first.status, OrganizationMemberStatus.active);
    });

    test('rejected keeps the reason on the row', () async {
      const service = OrganizerService();
      await service.saveApplication(_app());
      final app = (await service.getMyApplication('user-1'))!;
      expect(
          await service.rejectApplication(app, 'Incomplete verification info',
              reviewerUid: 'admin-1'),
          isTrue);
      final updated = (await service.getMyApplication('user-1'))!;
      expect(updated.status, OrganizerApplicationStatus.rejected);
      expect(updated.reviewNote, 'Incomplete verification info');
      expect(updated.toMap()['rejection_reason'],
          'Incomplete verification info');
      // No organization was created by a rejection.
      expect(await service.getMyOrganization('user-1'), isNull);
    });

    test('re-applying after rejection replaces the old row', () async {
      const service = OrganizerService();
      await service.saveApplication(_app());
      final app = (await service.getMyApplication('user-1'))!;
      await service.rejectApplication(app, 'No logo', reviewerUid: 'admin-1');
      await service.saveApplication(_app(orgName: 'Quetta Esports Club v2'));
      final apps = await service.listApplications();
      expect(apps.where((a) => a.applicantUid == 'user-1').length, 1);
      final again = (await service.getMyApplication('user-1'))!;
      expect(again.status, OrganizerApplicationStatus.pending);
      expect(again.orgName, 'Quetta Esports Club v2');
    });
  });

  group('tier model', () {
    test('exactly 3 tiers, no prices anywhere', () {
      expect(OrganizationTier.values.length, 3);
      expect(
          OrganizationTier.values.map((t) => t.name).toList(),
          ['starter', 'professional', 'enterprise']);
      // No price field exists on the tier model: the only public
      // surface is name / label / description — and none of the
      // user-facing text carries a price, currency or amount.
      for (final tier in OrganizationTier.values) {
        final text = '${tier.label} ${tier.description}';
        expect(text.contains(RegExp(r'[0-9\$€£₹]')), isFalse,
            reason: '${tier.name} text must not contain digits or currency: $text');
        // 'Rs' as a standalone currency token (not the 'rs' inside
        // ordinary words like 'first' or 'organizers').
        expect(RegExp(r'\brs\b', caseSensitive: false).hasMatch(text),
            isFalse,
            reason: '${tier.name} text must not contain an Rs amount: $text');
        expect(text.toLowerCase().contains('pkr'), isFalse);
        expect(text.toLowerCase().contains('price'), isFalse);
      }
      // The organization row carries no price column either.
      const org = Organization(id: 'o1', name: 'X', ownerUid: 'u1');
      expect(org.toMap().keys.any((k) => k.contains('price')), isFalse);
    });
  });

  group('staff invite', () {
    test('invite writes a pending row with the picked role', () async {
      const service = OrganizerService();
      await service.saveApplication(_app());
      final app = (await service.getMyApplication('user-1'))!;
      final org =
          await service.approveApplication(app, reviewerUid: 'admin-1');
      expect(
          await service.inviteStaff(
              org!.id, 'ref-9', OrganizationMemberRole.referee),
          isTrue);
      final staff = await service.listStaff(org.id);
      final invited = staff.where((m) => m.uid == 'ref-9').single;
      expect(invited.role, OrganizationMemberRole.referee);
      expect(invited.status, OrganizationMemberStatus.pending);
      expect(invited.organizationId, org.id);
      // Guide column names on the wire map.
      expect(invited.toMap()['firebase_uid'], 'ref-9');
      expect(invited.toMap()['organization_id'], org.id);
    });

    test('cannot invite an owner, and cannot invite an empty UID', () async {
      const service = OrganizerService();
      expect(
          await service.inviteStaff(
              'org-x', 'u2', OrganizationMemberRole.owner),
          isFalse);
      expect(
          await service.inviteStaff(
              'org-x', '  ', OrganizationMemberRole.staff),
          isFalse);
    });

    test('remove staff works; owner can never be removed', () async {
      const service = OrganizerService();
      await service.saveApplication(_app());
      final app = (await service.getMyApplication('user-1'))!;
      final org =
          await service.approveApplication(app, reviewerUid: 'admin-1');
      await service.inviteStaff(
          org!.id, 'staff-1', OrganizationMemberRole.staff);
      expect(await service.removeStaff(org.id, 'user-1'), isFalse);
      expect(await service.removeStaff(org.id, 'staff-1'), isTrue);
      final staff = await service.listStaff(org.id);
      expect(staff.any((m) => m.uid == 'staff-1'), isFalse);
      expect(staff.any((m) => m.uid == 'user-1'), isTrue);
    });
  });

  group('organization suspend / active toggle', () {
    test('suspend then re-activate round-trips', () async {
      const service = OrganizerService();
      await service.saveApplication(_app());
      final app = (await service.getMyApplication('user-1'))!;
      final org =
          await service.approveApplication(app, reviewerUid: 'admin-1');
      expect(
          await service.setOrganizationStatus(
              org!.id, OrganizationStatus.suspended),
          isTrue);
      expect((await service.getOrganization(org.id))!.status,
          OrganizationStatus.suspended);
      expect(
          await service.setOrganizationStatus(
              org.id, OrganizationStatus.active),
          isTrue);
      expect((await service.getOrganization(org.id))!.status,
          OrganizationStatus.active);
    });

    test('toggle on a missing org returns false', () async {
      const service = OrganizerService();
      expect(
          await service.setOrganizationStatus(
              'missing', OrganizationStatus.suspended),
          isFalse);
    });
  });

  group('branding + slugs', () {
    test('updateBranding changes logo + description', () async {
      const service = OrganizerService();
      await service.saveApplication(_app());
      final app = (await service.getMyApplication('user-1'))!;
      final org =
          await service.approveApplication(app, reviewerUid: 'admin-1');
      expect(
          await service.updateBranding(
              org!.id, 'https://example.com/logo.png', 'Best club in Quetta'),
          isTrue);
      final updated = (await service.getOrganization(org.id))!;
      expect(updated.logoUrl, 'https://example.com/logo.png');
      expect(updated.description, 'Best club in Quetta');
      expect(await service.updateBranding('missing', '', ''), isFalse);
    });

    test('slugify', () {
      expect(OrganizerService.slugify('Quetta Esports Club'),
          'quetta-esports-club');
      expect(OrganizerService.slugify('  A & B  '), 'a-b');
      expect(OrganizerService.slugify(''), 'organizer');
    });
  });
}
