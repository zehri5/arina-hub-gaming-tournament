import 'package:flutter/foundation.dart';
import 'package:protournament_user/platform/core/local_store.dart';
import 'package:protournament_user/platform/core/organization.dart';
import 'package:protournament_user/services/supabase_db.dart';

/// Organizer-side data service (ChatGPT blueprint §7; backend guide
/// §4 `organizations` / `organization_members` + §7
/// `organizer_applications`).
///
/// SERVER-FIRST (F15, 2026-11-22): the tables are live (044
/// organizations + organization_members, 059 organizer_applications)
/// with permissive anon+authenticated policies. Every method reads
/// the server first and falls back to [PlatformLocalStore] (area
/// `'organizer'`) when the server is unreachable; writes go to the
/// server first and mirror to the device list. [approveApplication]
/// mirrors the guide's `approve_organizer` RPC transaction semantics
/// (organization row + owner member row + application status, one
/// logical step) — with one deliberate deviation: the RPC does NOT
/// set `logo_url` on the org row, this service does (the wizard
/// collects a logo and the local approve always kept it).
///
/// Honesty flags: the service is `const` and instantiated in many
/// places, so the last write's outcome is reported on statics —
/// [lastWriteWasLocalOnly] is true when the server write failed and
/// only the device copy changed, [lastError] carries the server
/// error. Screens read these right after awaiting a write to toast
/// honestly (a local-only approve/reject is NEVER reported as a
/// server decision). User-side callers ignore the flags; behaviour
/// strictly improves for them.
///
/// Storage layout (keys are `platform.organizer.<id>`):
///   `applications`   — list of organizer_applications rows (one per
///                      applicant UID; re-applying replaces the old row)
///   `organizations`  — list of organizations rows
///   `members.<org>`  — list of organization_members rows for one org
///
/// Loads return null / empty on failure; saves return false only
/// when NOTHING persisted (server failed AND the device save failed).
/// Callers must treat `false` as "not saved".
class OrganizerService {
  const OrganizerService();

  static const String area = 'organizer';
  static const String applicationsKey = 'applications';
  static const String organizationsKey = 'organizations';

  static String membersKey(String orgId) => 'members.$orgId';

  /// Set by the last write method (see the class doc). True when the
  /// server write failed and only the device copy changed.
  static bool lastWriteWasLocalOnly = false;

  /// The server error behind [lastWriteWasLocalOnly], if any.
  static String? lastError;

  static void _beginWrite() {
    lastWriteWasLocalOnly = false;
    lastError = null;
  }

  static void _markLocalOnly(Object e) {
    lastWriteWasLocalOnly = true;
    lastError = e.toString();
  }

  /// True when [s] is a server uuid (36-char hyphenated). Local ids
  /// are `app_<uid>_<ms>` / `org_<uid>_<ms>` — never uuids. Pure
  /// helper, unit-tested.
  static bool isServerUuid(String s) {
    final v = s.trim();
    if (v.isEmpty) return false;
    return RegExp(
            r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
        .hasMatch(v);
  }

  /// Server payload for an organization — the 044 column names,
  /// WITHOUT id (the server generates the uuid) and WITHOUT
  /// `verified` (no such column — server truth is `status`). Pure
  /// helper, unit-tested.
  static Map<String, dynamic> organizationServerRow(Organization o) {
    return {
      'name': o.name,
      'slug': o.slug,
      'logo_url': o.logoUrl,
      'description': o.description,
      'country_code': o.countryCode,
      'owner_firebase_uid': o.ownerUid,
      'status': o.status.name,
      'tier': o.tier.name,
    };
  }

  /// Server payload for an application — the 059 column names,
  /// WITHOUT id (local ids are `app_<uid>_<ms>`, not uuids) and
  /// WITHOUT `reviewed_by` (the caller adds it on review actions).
  /// Pure helper, unit-tested.
  static Map<String, dynamic> applicationServerRow(
      OrganizerApplication a) {
    return {
      'firebase_uid': a.applicantUid,
      'organization_name': a.orgName,
      'logo_url': a.logoUrl,
      'description': a.description,
      'country_code': a.countryCode,
      'status': a.status.wireValue,
      'rejection_reason': a.reviewNote,
    };
  }

  /// Server payload for a member row — the 044 column names, WITHOUT
  /// `invited_at` (no such column; the server tracks `invited_by`).
  /// Pure helper, unit-tested.
  static Map<String, dynamic> memberServerRow(OrganizationMember m,
      {String? invitedBy}) {
    return {
      'organization_id': m.organizationId,
      'firebase_uid': m.uid,
      'role': m.role.name,
      'status': m.status.name,
      'invited_by': invitedBy,
    };
  }

  /// Unique slug against [taken] (`slug`, `slug-2`, `slug-3`, ...).
  /// Pure helper, unit-tested.
  static String uniqueSlug(String base, Set<String> taken) {
    if (!taken.contains(base)) return base;
    var n = 2;
    while (taken.contains('$base-$n')) {
      n++;
    }
    return '$base-$n';
  }

  /// URL-safe slug for an organization name (guide §4 `slug`, unique).
  /// Lowercase, runs of non-alphanumerics become one `-`, trimmed.
  static String slugify(String name) {
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'organizer' : slug;
  }

  /// Application validation (used by the wizard + tests). Returns a
  /// list of problems; empty means valid. Rules: organization name
  /// required, country required (and must be a known ISO code when
  /// non-empty — the wizard only offers [kSupportedCountries], so an
  /// unknown code means corrupt local data).
  static List<String> validateApplication(OrganizerApplication app) {
    final errors = <String>[];
    if (app.orgName.trim().isEmpty) {
      errors.add('Organization name is required.');
    }
    if (app.countryCode.trim().isEmpty) {
      errors.add('Country is required.');
    }
    if (app.applicantUid.trim().isEmpty) {
      errors.add('Applicant account is missing — please sign in again.');
    }
    return errors;
  }

  // ---------- applications ----------

  Future<List<OrganizerApplication>> _loadLocalApplications() async {
    final rows = await PlatformLocalStore.loadList(area, applicationsKey);
    return rows.map(OrganizerApplication.fromMap).toList();
  }

  Future<bool> _saveLocalApplications(
      List<OrganizerApplication> apps) async {
    try {
      return await PlatformLocalStore.saveList(
          area, applicationsKey, apps.map((a) => a.toMap()).toList());
    } catch (_) {
      return false;
    }
  }

  /// Saves (inserts or replaces by applicant UID) an application.
  /// One application per user: re-applying after a rejection replaces
  /// the old row instead of stacking a second one. Server-first:
  /// the server row is looked up by `firebase_uid` (local ids are
  /// not uuids), updated when it exists, inserted otherwise.
  Future<bool> saveApplication(OrganizerApplication app) async {
    _beginWrite();
    final local = await _loadLocalApplications();
    List<OrganizerApplication> mergeLocal(OrganizerApplication saved) {
      final idx =
          local.indexWhere((a) => a.applicantUid == saved.applicantUid);
      final next = List<OrganizerApplication>.from(local);
      if (idx >= 0) {
        next[idx] = saved;
      } else {
        next.add(saved);
      }
      return next;
    }

    try {
      final row = applicationServerRow(app);
      String serverId;
      if (isServerUuid(app.id)) {
        final updated = await SupaDb.client
            .from('organizer_applications')
            .update(row)
            .eq('id', app.id)
            .select('id');
        if ((updated as List).isEmpty) {
          throw Exception('Application update nahi hui — row nahi mili.');
        }
        serverId = app.id;
      } else {
        final existing = await SupaDb.client
            .from('organizer_applications')
            .select('id')
            .eq('firebase_uid', app.applicantUid)
            .limit(1);
        if ((existing as List).isNotEmpty) {
          serverId = SupaDb.strOf((existing as List).first['id']);
          final updated = await SupaDb.client
              .from('organizer_applications')
              .update(row)
              .eq('id', serverId)
              .select('id');
          if ((updated as List).isEmpty) {
            throw Exception('Application update nahi hui — row nahi mili.');
          }
        } else {
          final inserted = await SupaDb.client
              .from('organizer_applications')
              .insert(row)
              .select('id')
              .single();
          serverId = SupaDb.strOf(inserted['id']);
          if (serverId.isEmpty) {
            throw Exception(
                'Application insert hui lekin id wapas nahi aayi.');
          }
        }
      }
      // Re-read to prove the write landed (F23 pattern).
      final after = await SupaDb.client
          .from('organizer_applications')
          .select('id')
          .eq('id', serverId)
          .limit(1);
      if ((after as List).isEmpty) {
        throw Exception(
            'Application save verify nahi hui — row dobara nahi mili.');
      }
      final saved = OrganizerApplication(
        id: serverId,
        orgName: app.orgName,
        logoUrl: app.logoUrl,
        description: app.description,
        countryCode: app.countryCode,
        applicantUid: app.applicantUid,
        status: app.status,
        submittedAt: app.submittedAt,
        reviewedAt: app.reviewedAt,
        reviewNote: app.reviewNote,
      );
      await _saveLocalApplications(mergeLocal(saved));
      return true;
    } catch (e) {
      // Honest local fallback: keep the application on the device,
      // flag it so the caller can say so.
      _markLocalOnly(e);
      return _saveLocalApplications(mergeLocal(app));
    }
  }

  Future<OrganizerApplication?> getMyApplication(String uid) async {
    if (uid.isEmpty) return null;
    final apps = await listApplications();
    for (final a in apps) {
      if (a.applicantUid == uid) return a;
    }
    return null;
  }

  /// Server-first: server rows win per applicant UID; device-only
  /// rows (an applicant the server has no row for yet) stay visible
  /// until they sync.
  Future<List<OrganizerApplication>> listApplications() async {
    final local = await _loadLocalApplications();
    try {
      final rows = await SupaDb.client
          .from('organizer_applications')
          .select()
          .order('created_at', ascending: false);
      final server = (rows as List)
          .map((r) => OrganizerApplication.fromMap(
              Map<String, dynamic>.from(r as Map)))
          .toList();
      final serverUids = server.map((a) => a.applicantUid).toSet();
      final merged = [
        ...server,
        ...local.where((a) => !serverUids.contains(a.applicantUid)),
      ];
      await _saveLocalApplications(merged);
      return merged;
    } catch (_) {
      return local;
    }
  }

  /// Marks an application `under_review` (Super Admin started the
  /// review). Only `applied` applications can move to this state.
  /// The gate is read from the SERVER row (a local-only
  /// under_review must not block a retry when the server still says
  /// `applied`); when the server is unreachable the local status
  /// gates instead and the change is kept on the device only.
  Future<bool> markApplicationUnderReview(OrganizerApplication app) async {
    _beginWrite();
    var serverSaysApplied = false;
    var serverReachable = false;
    try {
      final rows = await SupaDb.client
          .from('organizer_applications')
          .select('status')
          .eq('firebase_uid', app.applicantUid)
          .limit(1);
      serverReachable = true;
      if ((rows as List).isNotEmpty) {
        serverSaysApplied =
            SupaDb.strOf((rows as List).first['status']) == 'applied';
      } else {
        // No server row yet (local-only application) — treat as applied.
        serverSaysApplied = true;
      }
    } catch (_) {
      serverReachable = false;
    }
    if (serverReachable) {
      if (!serverSaysApplied) return false;
    } else if (app.status != OrganizerApplicationStatus.pending) {
      return false;
    }
    final updated = OrganizerApplication(
      id: app.id,
      orgName: app.orgName,
      logoUrl: app.logoUrl,
      description: app.description,
      countryCode: app.countryCode,
      applicantUid: app.applicantUid,
      status: OrganizerApplicationStatus.underReview,
      submittedAt: app.submittedAt,
      reviewedAt: app.reviewedAt,
      reviewNote: app.reviewNote,
    );
    return saveApplication(updated);
  }

  /// Approves an application — mirrors the guide §7 `approve_organizer`
  /// RPC: creates the [Organization] row (status `active`, tier
  /// `starter`) + the owner's `organization_members` row (role
  /// `owner`, status `active`) and marks the application `approved`.
  /// Returns the created organization, or null when any step fails.
  ///
  /// Server-first (F15): the org insert, the owner member insert
  /// (with org cleanup on member failure, like the RPC's transaction)
  /// and the application status update all run against the server and
  /// are verified by re-read; `profiles.role` is set to `organizer`
  /// best-effort (a failure there is logged, never fatal). The slug
  /// is made unique against the server slugs + the device list.
  /// On server failure the old local approve runs instead and
  /// [lastWriteWasLocalOnly] is set — a local-only approve stays
  /// retryable: the early return below only fires when the org for
  /// this applicant already has a SERVER id.
  Future<Organization?> approveApplication(
    OrganizerApplication app, {
    required String reviewerUid,
  }) async {
    _beginWrite();
    if (app.status == OrganizerApplicationStatus.approved) {
      final existing = await getMyOrganization(app.applicantUid);
      if (existing != null && isServerUuid(existing.id)) {
        return existing;
      }
      // Local-only approve (or none) — fall through and retry the
      // server approval instead of returning the device-only org.
    }
    final now = DateTime.now().toUtc();
    try {
      // 1) The server application row must exist before its status
      // can be updated (a local-only application has no server row).
      final appRows = await SupaDb.client
          .from('organizer_applications')
          .select('id')
          .eq('firebase_uid', app.applicantUid)
          .limit(1);
      String? serverAppId;
      if ((appRows as List).isNotEmpty) {
        serverAppId = SupaDb.strOf((appRows as List).first['id']);
      } else {
        final inserted = await SupaDb.client
            .from('organizer_applications')
            .insert(applicationServerRow(app))
            .select('id')
            .single();
        serverAppId = SupaDb.strOf(inserted['id']);
      }
      if (serverAppId.isEmpty) {
        throw Exception('Application row server par nahi mili.');
      }
      // 2) Unique slug against the server slugs (+ device slugs,
      // excluding this applicant's own local-only org — its slug is
      // the one being retried, not a competitor).
      final slugRows =
          await SupaDb.client.from('organizations').select('slug');
      final taken = (slugRows as List)
          .map((r) => SupaDb.strOf((r as Map)['slug']))
          .where((s) => s.isNotEmpty)
          .toSet();
      final localOrgs = await _loadLocalOrganizations();
      final ownLocal = localOrgs
          .where((o) =>
              o.ownerUid == app.applicantUid && !isServerUuid(o.id))
          .toList();
      for (final o in localOrgs) {
        if (!ownLocal.contains(o)) taken.add(o.slug);
      }
      final slug = uniqueSlug(slugify(app.orgName), taken);
      // 3) Organization row (the RPC does not set logo_url; this
      // service does — the wizard collects a logo).
      final orgRow = {
        ...organizationServerRow(Organization(
          id: '',
          name: app.orgName,
          slug: slug,
          logoUrl: app.logoUrl,
          description: app.description,
          countryCode: app.countryCode,
          ownerUid: app.applicantUid,
          status: OrganizationStatus.active,
          tier: OrganizationTier.starter,
        )),
      };
      final insertedOrg = await SupaDb.client
          .from('organizations')
          .insert(orgRow)
          .select('id')
          .single();
      final serverOrgId = SupaDb.strOf(insertedOrg['id']);
      if (serverOrgId.isEmpty) {
        throw Exception('Organization insert hui lekin id wapas nahi aayi.');
      }
      // 4) Owner member row — on failure delete the org again (the
      // RPC's transaction would roll back; the client mirrors it).
      try {
        final memberRes = await SupaDb.client
            .from('organization_members')
            .insert({
              'organization_id': serverOrgId,
              'firebase_uid': app.applicantUid,
              'role': 'owner',
              'status': 'active',
            })
            .select('id');
        if ((memberRes as List).isEmpty) {
          throw Exception('Owner member row insert nahi hui.');
        }
      } catch (e) {
        try {
          await SupaDb.client
              .from('organizations')
              .delete()
              .eq('id', serverOrgId);
        } catch (_) {}
        rethrow;
      }
      // 5) Application status + reviewer (059 RPC semantics).
      final appUpdated = await SupaDb.client
          .from('organizer_applications')
          .update({
            'status': 'approved',
            'reviewed_by': reviewerUid,
            'reviewed_at': now.toIso8601String(),
          })
          .eq('id', serverAppId)
          .select('id');
      if ((appUpdated as List).isEmpty) {
        throw Exception('Application approve update nahi hui.');
      }
      // 6) profiles.role = organizer — best-effort, never fatal.
      try {
        await SupaDb.client
            .from('profiles')
            .update({'role': 'organizer'})
            .eq('firebase_uid', app.applicantUid);
      } catch (e) {
        debugPrint('approveApplication: profiles.role update failed: $e');
      }
      final org = Organization(
        id: serverOrgId,
        name: app.orgName,
        slug: slug,
        logoUrl: app.logoUrl,
        description: app.description,
        countryCode: app.countryCode,
        ownerUid: app.applicantUid,
        status: OrganizationStatus.active,
        tier: OrganizationTier.starter,
        createdAt: now,
        updatedAt: now,
      );
      // Mirror to the device list (replacing this applicant's
      // local-only org, if the earlier attempt left one).
      final nextOrgs = [
        org,
        ...localOrgs.where((o) =>
            o.id != serverOrgId &&
            !(o.ownerUid == app.applicantUid && !isServerUuid(o.id))),
      ];
      await _saveLocalOrganizations(nextOrgs);
      final updatedApp = OrganizerApplication(
        id: serverAppId,
        orgName: app.orgName,
        logoUrl: app.logoUrl,
        description: app.description,
        countryCode: app.countryCode,
        applicantUid: app.applicantUid,
        status: OrganizerApplicationStatus.approved,
        submittedAt: app.submittedAt,
        reviewedAt: now,
        reviewNote: app.reviewNote,
      );
      await _saveLocalApplications([
        updatedApp,
        ...(await _loadLocalApplications())
            .where((a) => a.applicantUid != app.applicantUid),
      ]);
      return org;
    } catch (e) {
      // Honest local fallback: the old local approve (org + owner
      // member + application status on the device only) so nothing
      // is lost, flagged for the caller. Retry stays possible: the
      // early return above only fires for a server-id org.
      _markLocalOnly(e);
      final localOrgs = await _loadLocalOrganizations();
      var slug = slugify(app.orgName);
      final taken = localOrgs.map((o) => o.slug).toSet();
      final ownLocal = localOrgs
          .where((o) =>
              o.ownerUid == app.applicantUid && !isServerUuid(o.id))
          .toList();
      if (ownLocal.isNotEmpty) {
        // The earlier local-only attempt already made this org.
        return ownLocal.first;
      }
      slug = uniqueSlug(slug, taken);
      final org = Organization(
        id: 'org_${app.applicantUid}_${now.millisecondsSinceEpoch}',
        name: app.orgName,
        slug: slug,
        logoUrl: app.logoUrl,
        description: app.description,
        countryCode: app.countryCode,
        ownerUid: app.applicantUid,
        status: OrganizationStatus.active,
        tier: OrganizationTier.starter,
        createdAt: now,
        updatedAt: now,
      );
      final savedOrg = await _saveLocalOrganization(org);
      if (!savedOrg) return null;
      await _saveLocalMember(
        org.id,
        OrganizationMember(
          organizationId: org.id,
          uid: app.applicantUid,
          role: OrganizationMemberRole.owner,
          status: OrganizationMemberStatus.active,
          invitedAt: now,
        ),
      );
      final updated = OrganizerApplication(
        id: app.id,
        orgName: app.orgName,
        logoUrl: app.logoUrl,
        description: app.description,
        countryCode: app.countryCode,
        applicantUid: app.applicantUid,
        status: OrganizerApplicationStatus.approved,
        submittedAt: app.submittedAt,
        reviewedAt: now,
        reviewNote: app.reviewNote,
      );
      final savedApp = await _saveLocalApplicationRow(updated);
      if (!savedApp) return null;
      return org;
    }
  }

  /// Rejects an application. The [reason] is kept on the row
  /// (`rejection_reason`) and shown to the applicant, who may re-apply.
  /// Server-first: the server row is found by id when known, else by
  /// applicant UID; on server failure the rejection is kept on the
  /// device only ([lastWriteWasLocalOnly] is set) so the admin can
  /// retry.
  Future<bool> rejectApplication(
    OrganizerApplication app,
    String reason, {
    required String reviewerUid,
  }) async {
    _beginWrite();
    final now = DateTime.now().toUtc();
    String? serverAppId;
    try {
      if (isServerUuid(app.id)) {
        serverAppId = app.id;
      } else {
        final rows = await SupaDb.client
            .from('organizer_applications')
            .select('id')
            .eq('firebase_uid', app.applicantUid)
            .limit(1);
        if ((rows as List).isNotEmpty) {
          serverAppId = SupaDb.strOf((rows as List).first['id']);
        }
      }
      if (serverAppId == null || serverAppId.isEmpty) {
        throw Exception('Application server par nahi hai — local save.');
      }
      final upd = await SupaDb.client
          .from('organizer_applications')
          .update({
            'status': 'rejected',
            'reviewed_by': reviewerUid,
            'reviewed_at': now.toIso8601String(),
            'rejection_reason': reason.trim(),
          })
          .eq('id', serverAppId)
          .select('id');
      if ((upd as List).isEmpty) {
        throw Exception('Application reject update nahi hui.');
      }
    } catch (e) {
      _markLocalOnly(e);
    }
    final updated = OrganizerApplication(
      id: serverAppId ?? app.id,
      orgName: app.orgName,
      logoUrl: app.logoUrl,
      description: app.description,
      countryCode: app.countryCode,
      applicantUid: app.applicantUid,
      status: OrganizerApplicationStatus.rejected,
      submittedAt: app.submittedAt,
      reviewedAt: now,
      reviewNote: reason.trim(),
    );
    return _saveLocalApplicationRow(updated);
  }

  // ---------- organizations ----------

  Future<List<Organization>> _loadLocalOrganizations() async {
    final rows = await PlatformLocalStore.loadList(area, organizationsKey);
    return rows.map(Organization.fromMap).toList();
  }

  Future<bool> _saveLocalOrganizations(List<Organization> orgs) async {
    try {
      return await PlatformLocalStore.saveList(
          area, organizationsKey, orgs.map((o) => o.toMap()).toList());
    } catch (_) {
      return false;
    }
  }

  /// Local-only save of one organization (insert or replace by id).
  Future<bool> _saveLocalOrganization(Organization org) async {
    final orgs = await _loadLocalOrganizations();
    final idx = orgs.indexWhere((o) => o.id == org.id);
    if (idx >= 0) {
      orgs[idx] = org;
    } else {
      orgs.add(org);
    }
    return _saveLocalOrganizations(orgs);
  }

  /// Local-only save of one application row (insert or replace by
  /// applicant UID).
  Future<bool> _saveLocalApplicationRow(OrganizerApplication app) async {
    final apps = await _loadLocalApplications();
    final idx = apps.indexWhere((a) => a.applicantUid == app.applicantUid);
    if (idx >= 0) {
      apps[idx] = app;
    } else {
      apps.add(app);
    }
    return _saveLocalApplications(apps);
  }

  /// Server-first save of an organization. A local-only org (no
  /// server id) is matched by its unique slug — but only when the
  /// server row with that slug belongs to the SAME owner; a slug
  /// owned by someone else is a collision, not a match.
  Future<bool> saveOrganization(Organization org) async {
    _beginWrite();
    final local = await _loadLocalOrganizations();
    try {
      final row = organizationServerRow(org);
      String serverId;
      if (isServerUuid(org.id)) {
        final updated = await SupaDb.client
            .from('organizations')
            .update(row)
            .eq('id', org.id)
            .select('id');
        if ((updated as List).isEmpty) {
          throw Exception('Organization update nahi hui — row nahi mili.');
        }
        serverId = org.id;
      } else {
        final existing = await SupaDb.client
            .from('organizations')
            .select('id, owner_firebase_uid')
            .eq('slug', org.slug)
            .limit(1);
        if ((existing as List).isNotEmpty) {
          final found = (existing as List).first as Map;
          if (SupaDb.strOf(found['owner_firebase_uid']) != org.ownerUid) {
            throw Exception(
                'Slug "${org.slug}" pehle se kisi aur organization ka hai.');
          }
          serverId = SupaDb.strOf(found['id']);
          final updated = await SupaDb.client
              .from('organizations')
              .update(row)
              .eq('id', serverId)
              .select('id');
          if ((updated as List).isEmpty) {
            throw Exception('Organization update nahi hui — row nahi mili.');
          }
        } else {
          final inserted = await SupaDb.client
              .from('organizations')
              .insert(row)
              .select('id')
              .single();
          serverId = SupaDb.strOf(inserted['id']);
          if (serverId.isEmpty) {
            throw Exception(
                'Organization insert hui lekin id wapas nahi aayi.');
          }
        }
      }
      // Re-read to prove the write landed (F23 pattern).
      final after = await SupaDb.client
          .from('organizations')
          .select('id')
          .eq('id', serverId)
          .limit(1);
      if ((after as List).isEmpty) {
        throw Exception(
            'Organization save verify nahi hui — row dobara nahi mili.');
      }
      final saved = Organization(
        id: serverId,
        name: org.name,
        slug: org.slug,
        logoUrl: org.logoUrl,
        description: org.description,
        countryCode: org.countryCode,
        ownerUid: org.ownerUid,
        verified: org.verified,
        status: org.status,
        tier: org.tier,
        createdAt: org.createdAt,
        updatedAt: DateTime.now().toUtc(),
      );
      await _saveLocalOrganizations([
        saved,
        ...local.where((o) =>
            o.id != org.id && o.id != serverId && o.slug != org.slug),
      ]);
      return true;
    } catch (e) {
      _markLocalOnly(e);
      return _saveLocalOrganization(org);
    }
  }

  Future<Organization?> getOrganization(String orgId) async {
    if (orgId.isEmpty) return null;
    final orgs = await listOrganizations();
    for (final o in orgs) {
      if (o.id == orgId) return o;
    }
    return null;
  }

  Future<Organization?> getMyOrganization(String uid) async {
    if (uid.isEmpty) return null;
    final orgs = await listOrganizations();
    for (final o in orgs) {
      if (o.ownerUid == uid) return o;
    }
    return null;
  }

  /// Server-first: server rows win; device-only rows stay visible
  /// until they sync. A device row is dropped only when the server
  /// has the SAME org (same id, or same slug for the same owner) —
  /// a same-slug row owned by someone else is a different org and
  /// is kept (nothing is silently deleted).
  Future<List<Organization>> listOrganizations() async {
    final local = await _loadLocalOrganizations();
    try {
      final rows = await SupaDb.client
          .from('organizations')
          .select()
          .order('created_at', ascending: false);
      final server = (rows as List)
          .map((r) =>
              Organization.fromMap(Map<String, dynamic>.from(r as Map)))
          .toList();
      final serverIds = server.map((o) => o.id).toSet();
      final serverBySlug = {for (final o in server) o.slug: o};
      final merged = [
        ...server,
        ...local.where((o) {
          if (serverIds.contains(o.id)) return false;
          final match = serverBySlug[o.slug];
          return match == null || match.ownerUid != o.ownerUid;
        }),
      ];
      await _saveLocalOrganizations(merged);
      return merged;
    } catch (_) {
      return local;
    }
  }

  /// Super Admin suspend / re-activate (guide §8
  /// `organizations.status`). Returns false when the org is missing.
  /// Server-first when the org has a server id; a device-only org
  /// can only change locally ([lastWriteWasLocalOnly] is set).
  Future<bool> setOrganizationStatus(
      String orgId, OrganizationStatus status) async {
    _beginWrite();
    final org = await getOrganization(orgId);
    if (org == null) return false;
    final now = DateTime.now().toUtc();
    final updated = Organization(
      id: org.id,
      name: org.name,
      slug: org.slug,
      logoUrl: org.logoUrl,
      description: org.description,
      countryCode: org.countryCode,
      ownerUid: org.ownerUid,
      verified: org.verified,
      status: status,
      tier: org.tier,
      createdAt: org.createdAt,
      updatedAt: now,
    );
    if (isServerUuid(org.id)) {
      try {
        final res = await SupaDb.client
            .from('organizations')
            .update({
              'status': status.name,
              'updated_at': now.toIso8601String(),
            })
            .eq('id', org.id)
            .select('id');
        if ((res as List).isEmpty) {
          throw Exception('Organization status update nahi hui.');
        }
      } catch (e) {
        _markLocalOnly(e);
      }
    } else {
      _markLocalOnly(Exception('Organization abhi server par nahi hai.'));
    }
    return _saveLocalOrganization(updated);
  }

  /// Updates the public branding fields (logo + description).
  /// Returns false when the org is missing. Server-first when the
  /// org has a server id (see [setOrganizationStatus]).
  Future<bool> updateBranding(
      String orgId, String logoUrl, String description) async {
    _beginWrite();
    final org = await getOrganization(orgId);
    if (org == null) return false;
    final now = DateTime.now().toUtc();
    final updated = Organization(
      id: org.id,
      name: org.name,
      slug: org.slug,
      logoUrl: logoUrl.trim(),
      description: description.trim(),
      countryCode: org.countryCode,
      ownerUid: org.ownerUid,
      verified: org.verified,
      status: org.status,
      tier: org.tier,
      createdAt: org.createdAt,
      updatedAt: now,
    );
    if (isServerUuid(org.id)) {
      try {
        final res = await SupaDb.client
            .from('organizations')
            .update({
              'logo_url': logoUrl.trim(),
              'description': description.trim(),
              'updated_at': now.toIso8601String(),
            })
            .eq('id', org.id)
            .select('id');
        if ((res as List).isEmpty) {
          throw Exception('Branding update nahi hui.');
        }
      } catch (e) {
        _markLocalOnly(e);
      }
    } else {
      _markLocalOnly(Exception('Organization abhi server par nahi hai.'));
    }
    return _saveLocalOrganization(updated);
  }

  // ---------- staff (organization_members) ----------

  Future<List<OrganizationMember>> _loadLocalStaff(String orgId) async {
    final rows = await PlatformLocalStore.loadList(area, membersKey(orgId));
    return rows.map(OrganizationMember.fromMap).toList();
  }

  Future<bool> _saveLocalStaff(
      String orgId, List<OrganizationMember> members) async {
    try {
      return await PlatformLocalStore.saveList(area, membersKey(orgId),
          members.map((m) => m.toMap()).toList());
    } catch (_) {
      return false;
    }
  }

  /// Local-only save of one member row (insert or replace by UID).
  Future<bool> _saveLocalMember(
      String orgId, OrganizationMember member) async {
    final members = await _loadLocalStaff(orgId);
    final idx = members.indexWhere((m) => m.uid == member.uid);
    if (idx >= 0) {
      members[idx] = member;
    } else {
      members.add(member);
    }
    return _saveLocalStaff(orgId, members);
  }

  /// Server-first: server members win per UID; device-only rows
  /// stay visible until they sync. A device-only org has no server
  /// members at all.
  Future<List<OrganizationMember>> listStaff(String orgId) async {
    if (orgId.isEmpty) return [];
    final local = await _loadLocalStaff(orgId);
    if (!isServerUuid(orgId)) return local;
    try {
      final rows = await SupaDb.client
          .from('organization_members')
          .select()
          .eq('organization_id', orgId)
          .order('created_at', ascending: false);
      final server = (rows as List)
          .map((r) => OrganizationMember.fromMap(
              Map<String, dynamic>.from(r as Map)))
          .toList();
      final serverUids = server.map((m) => m.uid).toSet();
      final merged = [
        ...server,
        ...local.where((m) => !serverUids.contains(m.uid)),
      ];
      await _saveLocalStaff(orgId, merged);
      return merged;
    } catch (_) {
      return local;
    }
  }

  /// Invites a user to the organization (guide §7 `invite_org_member`
  /// semantics): writes a PENDING member row — the invitee accepts
  /// in-app later (accept flow is a later workstream; until then the
  /// row stays `pending` and is shown as such). Server-first when the
  /// org has a server id (upsert on the unique org+uid pair, so a
  /// retry never duplicates); a device-only org can only invite
  /// locally. Returns false for an empty UID, for the `owner` role
  /// (an organization has exactly one owner), or on storage failure.
  Future<bool> inviteStaff(
      String orgId, String uid, OrganizationMemberRole role) async {
    _beginWrite();
    if (orgId.isEmpty || uid.trim().isEmpty) return false;
    if (role == OrganizationMemberRole.owner) return false;
    final member = OrganizationMember(
      organizationId: orgId,
      uid: uid.trim(),
      role: role,
      status: OrganizationMemberStatus.pending,
      invitedAt: DateTime.now().toUtc(),
    );
    if (isServerUuid(orgId)) {
      try {
        final res = await SupaDb.client
            .from('organization_members')
            .upsert(memberServerRow(member),
                onConflict: 'organization_id,firebase_uid')
            .select('id');
        if ((res as List).isEmpty) {
          throw Exception('Member invite nahi hui.');
        }
      } catch (e) {
        _markLocalOnly(e);
      }
    } else {
      _markLocalOnly(Exception('Organization abhi server par nahi hai.'));
    }
    return _saveLocalMember(orgId, member);
  }

  /// Removes a member row. The owner row can never be removed
  /// (returns false) — ownership transfer is not in the blueprint.
  /// Server-first when the org has a server id (verified gone).
  Future<bool> removeStaff(String orgId, String uid) async {
    _beginWrite();
    if (orgId.isEmpty || uid.isEmpty) return false;
    final members = await listStaff(orgId);
    final idx = members.indexWhere((m) => m.uid == uid);
    if (idx < 0) return false;
    if (members[idx].role == OrganizationMemberRole.owner) return false;
    if (isServerUuid(orgId)) {
      try {
        await SupaDb.client
            .from('organization_members')
            .delete()
            .eq('organization_id', orgId)
            .eq('firebase_uid', uid);
        final after = await SupaDb.client
            .from('organization_members')
            .select('id')
            .eq('organization_id', orgId)
            .eq('firebase_uid', uid)
            .limit(1);
        if ((after as List).isNotEmpty) {
          throw Exception('Member remove nahi hua — row abhi bhi maujood hai.');
        }
      } catch (e) {
        _markLocalOnly(e);
      }
    } else {
      _markLocalOnly(Exception('Organization abhi server par nahi hai.'));
    }
    members.removeAt(idx);
    return _saveLocalStaff(orgId, members);
  }
}

/// Membership status inside one organization (guide §4
/// `organization_members.status` — the guide names the column but not
/// its values; `active` / `pending` follow the invite flow in §7).
enum OrganizationMemberStatus {
  active,
  pending;

  static OrganizationMemberStatus fromString(String? raw,
      [OrganizationMemberStatus fallback =
          OrganizationMemberStatus.pending]) {
    final n = (raw ?? '').toLowerCase().trim();
    if (n == 'active') return OrganizationMemberStatus.active;
    if (n == 'pending') return OrganizationMemberStatus.pending;
    return fallback;
  }
}

/// One row of `organization_members` (guide §4): a user inside one
/// organization with a role. Keys in [toMap] are the guide's column
/// names (`organization_id`, `firebase_uid`, `role`, `status`).
class OrganizationMember {
  final String organizationId;
  final String uid;
  final OrganizationMemberRole role;
  final OrganizationMemberStatus status;
  final DateTime? invitedAt;

  const OrganizationMember({
    required this.organizationId,
    required this.uid,
    required this.role,
    this.status = OrganizationMemberStatus.pending,
    this.invitedAt,
  });

  factory OrganizationMember.fromMap(Map<String, dynamic> map) {
    DateTime? date(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      return DateTime.tryParse(v.toString());
    }

    return OrganizationMember(
      organizationId:
          (map['organization_id'] ?? map['organizationId'] ?? '').toString(),
      uid: (map['firebase_uid'] ?? map['uid'] ?? '').toString(),
      role: OrganizationMemberRole.fromString(
          (map['role'] ?? '').toString()),
      status: OrganizationMemberStatus.fromString(
          (map['status'] ?? '').toString()),
      invitedAt: date(map['invited_at'] ?? map['invitedAt']),
    );
  }

  Map<String, dynamic> toMap() => {
        'organization_id': organizationId,
        'firebase_uid': uid,
        'role': role.name,
        'status': status.name,
        'invited_at': invitedAt?.toUtc().toIso8601String(),
      };
}
