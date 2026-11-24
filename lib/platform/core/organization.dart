import 'package:protournament_user/utils.dart';

/// Organizations + organizer applications (ChatGPT blueprint §7;
/// backend guide §4 `organizations` / `organization_members` tables
/// and §7 `organizer_applications` table).
///
/// Field names in [Organization.toMap] / [OrganizerApplication.toMap]
/// are the guide's snake_case column names, so later workstreams can
/// send these maps straight to Supabase. [fromMap] is lenient and
/// also accepts camelCase keys (in-memory / legacy shapes).

String _str(dynamic v, [String fallback = '']) {
  if (v == null) return fallback;
  final s = v.toString();
  return s.isEmpty ? fallback : s;
}

bool _bool(dynamic v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.toLowerCase() == 'true' || v == '1';
  return fallback;
}

DateTime? _date(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  if (v is num) {
    final ms = v.toDouble().abs() < 100000000000
        ? (v.toDouble() * 1000).round()
        : v.toDouble().round();
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }
  return DateTime.tryParse(v.toString());
}

String? _iso(DateTime? d) => d?.toUtc().toIso8601String();

String _norm(String? raw) =>
    (raw ?? '').toLowerCase().replaceAll(RegExp(r'[_\-\s]'), '');

/// SaaS tiers for organizers (blueprint §7; guide §4 `organizations.tier`).
/// NO prices anywhere — pricing is decided at launch (guide §7 gap #6).
enum OrganizationTier {
  starter,
  professional,
  enterprise;

  String get label => switch (this) {
        OrganizationTier.starter => tr('Starter', 'Starter'),
        OrganizationTier.professional => tr('Professional', 'Professional'),
        OrganizationTier.enterprise => tr('Enterprise', 'Enterprise'),
      };

  /// Short description — no prices, no feature-count promises.
  String get description => switch (this) {
        OrganizationTier.starter => tr(
            'Run your first tournaments on the platform.',
            'Platform par apne pehle tournaments chalayen.'),
        OrganizationTier.professional => tr(
            'More tournaments, branding and reports.',
            'Zyada tournaments, branding aur reports.'),
        OrganizationTier.enterprise => tr(
            'Full platform access for large organizers.',
            'Bare organizers ke liye poora platform access.'),
      };

  static OrganizationTier fromString(String? raw,
          [OrganizationTier fallback = OrganizationTier.starter]) {
    final n = _norm(raw);
    for (final t in OrganizationTier.values) {
      if (_norm(t.name) == n) return t;
    }
    return fallback;
  }
}

/// Organization lifecycle (guide §4 `organizations.status`).
enum OrganizationStatus {
  pending,
  active,
  suspended;

  String get label => switch (this) {
        OrganizationStatus.pending => tr('Pending', 'Pending'),
        OrganizationStatus.active => tr('Active', 'Active'),
        OrganizationStatus.suspended => tr('Suspended', 'Suspended'),
      };

  static OrganizationStatus fromString(String? raw,
          [OrganizationStatus fallback = OrganizationStatus.pending]) {
    final n = _norm(raw);
    for (final s in OrganizationStatus.values) {
      if (_norm(s.name) == n) return s;
    }
    return fallback;
  }
}

/// Roles inside one organization (guide §4 `organization_members.role`).
enum OrganizationMemberRole {
  owner,
  admin,
  staff,
  referee;

  String get label => switch (this) {
        OrganizationMemberRole.owner => tr('Owner', 'Owner'),
        OrganizationMemberRole.admin => tr('Admin', 'Admin'),
        OrganizationMemberRole.staff => tr('Staff', 'Staff'),
        OrganizationMemberRole.referee => tr('Referee', 'Referee'),
      };

  static OrganizationMemberRole fromString(String? raw,
          [OrganizationMemberRole fallback =
              OrganizationMemberRole.staff]) {
    final n = _norm(raw);
    for (final r in OrganizationMemberRole.values) {
      if (_norm(r.name) == n) return r;
    }
    return fallback;
  }
}

/// An organizer's organization — the multi-tenancy unit. Every
/// tenant-scoped row (tournaments, registrations, results, financial
/// records) carries this [id] as `organization_id` (guide §4/§10).
class Organization {
  final String id;
  final String name;

  /// URL-safe unique handle (guide §4 `slug`, unique).
  final String slug;
  final String logoUrl;
  final String description;

  /// ISO country code, e.g. 'PK' (guide §4 `country_code`).
  final String countryCode;

  /// Firebase UID of the owner (guide §4 `owner_firebase_uid`).
  final String ownerUid;

  /// App-side verified badge. NOTE: the guide's `organizations` table
  /// has no `verified` column — server-side truth is [status]; this
  /// flag is UI-only until the backend adds the column.
  final bool verified;
  final OrganizationStatus status;
  final OrganizationTier tier;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const Organization({
    required this.id,
    required this.name,
    this.slug = '',
    this.logoUrl = '',
    this.description = '',
    this.countryCode = 'PK',
    required this.ownerUid,
    this.verified = false,
    this.status = OrganizationStatus.pending,
    this.tier = OrganizationTier.starter,
    this.createdAt,
    this.updatedAt,
  });

  factory Organization.fromMap(Map<String, dynamic> map) => Organization(
        id: _str(map['id']),
        name: _str(map['name']),
        slug: _str(map['slug']),
        logoUrl: _str(map['logo_url'] ?? map['logoUrl']),
        description: _str(map['description']),
        countryCode: _str(map['country_code'] ?? map['countryCode'], 'PK'),
        ownerUid: _str(map['owner_firebase_uid'] ??
            map['owner_uid'] ??
            map['ownerUid']),
        verified: _bool(map['verified']),
        status: OrganizationStatus.fromString(_str(map['status'])),
        tier: OrganizationTier.fromString(_str(map['tier'])),
        createdAt: _date(map['created_at'] ?? map['createdAt']),
        updatedAt: _date(map['updated_at'] ?? map['updatedAt']),
      );

  /// Keys are the guide's `organizations` column names.
  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'slug': slug,
        'logo_url': logoUrl,
        'description': description,
        'country_code': countryCode,
        'owner_firebase_uid': ownerUid,
        'verified': verified,
        'status': status.name,
        'tier': tier.name,
        'created_at': _iso(createdAt),
        'updated_at': _iso(updatedAt),
      };
}

/// Status of an organizer application (guide §7
/// `organizer_applications.status`: `applied` / `under_review` /
/// `approved` / `rejected`).
///
/// The Dart value is named `pending` (first step of the workflow) but
/// its wire value is the guide's `applied` — [fromString] accepts
/// both spellings, [toMap] writes `applied`.
enum OrganizerApplicationStatus {
  pending,
  underReview,
  approved,
  rejected;

  String get label => switch (this) {
        OrganizerApplicationStatus.pending => tr('Applied', 'Applied'),
        OrganizerApplicationStatus.underReview =>
          tr('Under review', 'Review mein hai'),
        OrganizerApplicationStatus.approved => tr('Approved', 'Approved'),
        OrganizerApplicationStatus.rejected => tr('Rejected', 'Rejected'),
      };

  /// Server wire value (guide §7).
  String get wireValue => switch (this) {
        OrganizerApplicationStatus.pending => 'applied',
        OrganizerApplicationStatus.underReview => 'under_review',
        OrganizerApplicationStatus.approved => 'approved',
        OrganizerApplicationStatus.rejected => 'rejected',
      };

  static OrganizerApplicationStatus fromString(String? raw,
      [OrganizerApplicationStatus fallback =
          OrganizerApplicationStatus.pending]) {
    final n = _norm(raw);
    if (n == 'applied') return OrganizerApplicationStatus.pending;
    for (final s in OrganizerApplicationStatus.values) {
      if (_norm(s.name) == n) return s;
    }
    return fallback;
  }
}

/// A "Become an Organizer" application (blueprint §7, 12-step
/// workflow; guide §7 `organizer_applications` table). Approval
/// creates the [Organization] + the owner's member row (server RPC
/// `approve_organizer`).
class OrganizerApplication {
  final String id;
  final String orgName;
  final String logoUrl;
  final String description;
  final String countryCode;

  /// Firebase UID of the applicant (guide §7 `firebase_uid`).
  final String applicantUid;
  final OrganizerApplicationStatus status;
  final DateTime? submittedAt;
  final DateTime? reviewedAt;

  /// Review note / rejection reason (guide §7 `rejection_reason`).
  final String reviewNote;

  const OrganizerApplication({
    required this.id,
    required this.orgName,
    this.logoUrl = '',
    this.description = '',
    this.countryCode = 'PK',
    required this.applicantUid,
    this.status = OrganizerApplicationStatus.pending,
    this.submittedAt,
    this.reviewedAt,
    this.reviewNote = '',
  });

  factory OrganizerApplication.fromMap(Map<String, dynamic> map) =>
      OrganizerApplication(
        id: _str(map['id']),
        orgName: _str(map['organization_name'] ?? map['orgName']),
        logoUrl: _str(map['logo_url'] ?? map['logoUrl']),
        description: _str(map['description']),
        countryCode: _str(map['country_code'] ?? map['countryCode'], 'PK'),
        applicantUid: _str(map['firebase_uid'] ??
            map['applicant_uid'] ??
            map['applicantUid']),
        status: OrganizerApplicationStatus.fromString(_str(map['status'])),
        submittedAt:
            _date(map['created_at'] ?? map['submitted_at'] ?? map['submittedAt']),
        reviewedAt: _date(map['reviewed_at'] ?? map['reviewedAt']),
        reviewNote: _str(map['rejection_reason'] ??
            map['review_note'] ??
            map['reviewNote']),
      );

  /// Keys are the guide's `organizer_applications` column names.
  /// `submittedAt` maps to `created_at` (the guide has no separate
  /// submitted column); `reviewNote` maps to `rejection_reason`.
  Map<String, dynamic> toMap() => {
        'id': id,
        'firebase_uid': applicantUid,
        'organization_name': orgName,
        'logo_url': logoUrl,
        'description': description,
        'country_code': countryCode,
        'status': status.wireValue,
        'created_at': _iso(submittedAt),
        'reviewed_at': _iso(reviewedAt),
        'rejection_reason': reviewNote,
      };
}
