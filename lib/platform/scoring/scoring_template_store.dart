import 'package:protournament_user/platform/core/local_store.dart';
import 'package:protournament_user/platform/core/scoring.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Admin-configurable placement-points template (Sameer 2026-11-21
/// 02:20: the 10/7/5 template must be changeable from the admin
/// panel without a new build).
///
/// Precedence — [loadEffectiveTemplate] returns the first that
/// exists and is valid:
///   1. the device-local override (SharedPreferences via
///      [PlatformLocalStore]) — an admin's explicit choice on
///      THIS device wins;
///   2. the shared server row in `scoring_templates`
///      (is_official_style row first) — so a change made on one
///      admin device reaches every device;
///   3. [kDefaultScoringTemplate] (the decided 10/7/5).
///
/// The server table EXISTS (live since 2026-11-20, one row
/// "Official-style (OD-02)" = {1:10, 2:7, 3:5}, kill_points 1) —
/// an older comment here said it did not. The admin Scoring screen
/// writes BOTH the device override and the server row
/// ([saveServerTemplate]); a failed server write never blocks the
/// local save, but the screen must say so honestly.
///
/// The server RPC remains the authority for credited points; this
/// template only changes the APP's display/preview template
/// (scoped leaderboards, points breakdowns, `recomputeLeaderboard`).
///
/// Nothing here ever throws: storage/server failure means "fall
/// back to the next source" (never a crash, never a fake value).
/// NOTE: this file talks to Supabase directly instead of through
/// SupaDb — SupaDb imports this store, so going through it would
/// be an import cycle.
class ScoringTemplateStore {
  static const String _area = 'scoring';
  static const String _key = 'placement_template_override';

  /// Server-template cache: the `scoring_templates` row changes
  /// rarely, and [loadEffectiveTemplate] is called on every
  /// leaderboard load — one read per 5 minutes is enough.
  static ScoringTemplate? _serverCache;
  static DateTime? _serverCacheAt;
  static const _serverCacheTtl = Duration(minutes: 5);

  /// The template the app should use: device override, else the
  /// server row, else [kDefaultScoringTemplate].
  static Future<ScoringTemplate> loadEffectiveTemplate() async {
    try {
      final raw = await PlatformLocalStore.loadDraft(_area, _key);
      if (raw != null) {
        final stored = ScoringTemplate.fromMap(raw);
        if (_isValidOverride(stored)) {
          return ScoringTemplate(
            id: 'admin-override',
            name: 'Admin Override',
            placementPoints: stored.placementPoints,
            killPoints: 1,
            isOfficialStyle: false,
          );
        }
      }
    } catch (_) {
      // Storage failure: fall through to the server row.
    }
    return (await loadServerTemplate()) ?? kDefaultScoringTemplate;
  }

  /// The shared server template from `scoring_templates`
  /// (is_official_style row first), or null when the table is
  /// unreachable, empty, or has no valid row. Never throws.
  /// Cached for 5 minutes; [saveServerTemplate] invalidates it.
  static Future<ScoringTemplate?> loadServerTemplate() async {
    final cachedAt = _serverCacheAt;
    if (_serverCache != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _serverCacheTtl) {
      return _serverCache;
    }
    try {
      final rows = await Supabase.instance.client
          .from('scoring_templates')
          .select()
          .order('created_at', ascending: false)
          .limit(5);
      final valid = (rows as List)
          .map((r) =>
              ScoringTemplate.fromMap(Map<String, dynamic>.from(r as Map)))
          .where(_isValidOverride)
          .toList();
      if (valid.isEmpty) return null;
      final server =
          valid.firstWhere((t) => t.isOfficialStyle, orElse: () => valid.first);
      _serverCache = server;
      _serverCacheAt = DateTime.now();
      return server;
    } catch (_) {
      return null;
    }
  }

  /// Saves the admin template to the server row too, so every
  /// device uses it (not just this one). Updates the official row
  /// when one exists, otherwise creates it. Returns false when
  /// the server write fails — the caller must say so honestly
  /// (the device-local save is unaffected).
  static Future<bool> saveServerTemplate({
    required int first,
    required int second,
    required int third,
  }) async {
    if (first < 0 || second < 0 || third < 0) return false;
    try {
      final client = Supabase.instance.client;
      final points = {'1': first, '2': second, '3': third};
      final existing = await client
          .from('scoring_templates')
          .select('id')
          .eq('is_official_style', true)
          .limit(1);
      final list = existing as List;
      if (list.isNotEmpty) {
        await client.from('scoring_templates').update({
          'placement_points': points,
          'kill_points': 1,
        }).eq('id', (list.first as Map)['id']);
      } else {
        await client.from('scoring_templates').insert({
          'name': 'Official-style (OD-02)',
          'placement_points': points,
          'kill_points': 1,
          'is_official_style': true,
        });
      }
      _serverCache = null; // re-read next time
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Resets the server row to the decided default (10/7/5). Used
  /// by the admin Reset action — without it, clearing the device
  /// override would fall back to the custom server values instead
  /// of the default. Returns false when the server write fails.
  static Future<bool> resetServerTemplate() =>
      saveServerTemplate(first: 10, second: 7, third: 3);

  /// An override is valid when it has at least one placement and
  /// every value is a non-negative integer. Anything else falls
  /// back to the default (never a half-broken table).
  static bool _isValidOverride(ScoringTemplate t) {
    if (t.placementPoints.isEmpty) return false;
    for (final v in t.placementPoints.values) {
      if (v < 0) return false;
    }
    return true;
  }

  /// Saves an admin override for placements 1–3 (4th and below
  /// always score 0 — the decided model). Returns false when the
  /// values are invalid or the save failed. Device-local only —
  /// pair with [saveServerTemplate] for all devices.
  static Future<bool> saveOverride({
    required int first,
    required int second,
    required int third,
  }) async {
    if (first < 0 || second < 0 || third < 0) return false;
    final template = ScoringTemplate(
      id: 'admin-override',
      name: 'Admin Override',
      placementPoints: {1: first, 2: second, 3: third},
      killPoints: 1,
    );
    return PlatformLocalStore.saveDraft(_area, _key, template.toMap());
  }

  /// Clears the override — the app returns to the server row or
  /// [kDefaultScoringTemplate]. Pair with [resetServerTemplate]
  /// when the admin means "back to default everywhere".
  static Future<bool> clearOverride() =>
      PlatformLocalStore.deleteDraft(_area, _key);

  /// True when an override is stored (valid or not — validity is
  /// decided by [loadEffectiveTemplate]).
  static Future<bool> hasOverride() async {
    final raw = await PlatformLocalStore.loadDraft(_area, _key);
    return raw != null;
  }
}
