// F15 + F23 (Child F, 2026-11-22) — unit tests for the PURE helpers
// behind the server-first organizer wiring. No Supabase, no network, no
// SharedPreferences: these tests only check that the server payloads
// are built with the guide's column names and that the local-only
// ids / columns that must never reach the server are stripped
// (id, Organization.verified, OrganizationMember.invited_at).
// FIX 32 (2026-11-24): the Sponsor/Subscription/Region admin-service
// groups were removed with the admin panel; only the OrganizerService
// groups remain.
//
// The live behaviour (insert/update/delete round-trips as anon) is
// covered by the staging validation runs, not here.
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/platform/core/organization.dart';
import 'package:protournament_user/platform/organizer/organizer_service.dart';

const _uuid = '662239d8-e3d1-4e8d-9d41-9d810d217b1a';


void main() {
  group('OrganizerService server rows', () {
    test('organizationServerRow drops id and verified', () {
      final row = OrganizerService.organizationServerRow(Organization(
        id: 'org_user-1_123',
        name: 'Quetta Esports Club',
        slug: 'quetta-esports-club',
        logoUrl: 'https://example.com/logo.png',
        description: 'Test org',
        countryCode: 'PK',
        ownerUid: 'user-1',
        verified: true,
        status: OrganizationStatus.active,
        tier: OrganizationTier.starter,
      ));
      expect(row.containsKey('id'), isFalse);
      expect(row.containsKey('verified'), isFalse,
          reason: 'organizations has no verified column');
      expect(row['name'], 'Quetta Esports Club');
      expect(row['slug'], 'quetta-esports-club');
      expect(row['logo_url'], 'https://example.com/logo.png');
      expect(row['owner_firebase_uid'], 'user-1');
      expect(row['status'], 'active');
      expect(row['tier'], 'starter');
    });

    test('applicationServerRow drops id, uses applied wire value', () {
      final row = OrganizerService.applicationServerRow(
          OrganizerApplication(
        id: 'app_user-1_123',
        orgName: 'Quetta Esports Club',
        countryCode: 'PK',
        applicantUid: 'user-1',
        status: OrganizerApplicationStatus.pending,
      ));
      expect(row.containsKey('id'), isFalse);
      expect(row['firebase_uid'], 'user-1');
      expect(row['organization_name'], 'Quetta Esports Club');
      expect(row['country_code'], 'PK');
      expect(row['status'], 'applied');
    });

    test('memberServerRow drops invited_at, keeps invited_by', () {
      final member = OrganizationMember(
        organizationId: _uuid,
        uid: 'user-1',
        role: OrganizationMemberRole.owner,
        status: OrganizationMemberStatus.active,
        invitedAt: DateTime.utc(2026, 11, 22),
      );
      final row = OrganizerService.memberServerRow(member);
      expect(row.containsKey('invited_at'), isFalse,
          reason: 'organization_members has no invited_at column');
      expect(row['organization_id'], _uuid);
      expect(row['firebase_uid'], 'user-1');
      expect(row['role'], 'owner');
      expect(row['status'], 'active');
      expect(row['invited_by'], isNull);
      expect(
          OrganizerService.memberServerRow(member, invitedBy: 'admin-1')[
              'invited_by'],
          'admin-1');
    });
  });

  group('OrganizerService slug helpers', () {
    test('slugify lowercases and hyphenates', () {
      expect(OrganizerService.slugify('Quetta Esports Club'),
          'quetta-esports-club');
      expect(OrganizerService.slugify('  A&B  '), 'a-b');
      expect(OrganizerService.slugify(''), 'organizer');
    });

    test('uniqueSlug appends -2, -3 on collision', () {
      expect(OrganizerService.uniqueSlug('quetta', {}), 'quetta');
      expect(
          OrganizerService.uniqueSlug('quetta', {'quetta'}), 'quetta-2');
      expect(
          OrganizerService.uniqueSlug('quetta', {'quetta', 'quetta-2'}),
          'quetta-3');
    });
  });
}
