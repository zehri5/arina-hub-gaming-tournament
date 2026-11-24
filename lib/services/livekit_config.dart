import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';

import 'supabase_db.dart';

/// LIVEKIT TEST-PATH CONFIG (2026-11-01, user order: build the
/// LiveKit SFU trial now, activate it when server details arrive).
///
/// Config lives ONLY in `app_settings.livekit` (migration 015 adds
/// the jsonb column; until it is applied the config is empty and
/// the test path honestly reports "not configured" instead of
/// faking a connection). NOTHING is hardcoded here and NO API key
/// or secret ever lives in the app: the app only ever holds the
/// public server URL and the token-function URL. The LiveKit API
/// secret lives ONLY in the token Edge Function's env.
///
/// Shape (admin sets this in app_settings, id = 1):
///   {
///     "activeProjectId": "cloud-1",
///     "projects": [
///       {"id": "cloud-1", "name": "LiveKit Cloud",
///        "serverUrl": "wss://xxx.livekit.cloud",
///        "tokenUrl": "https://xxx.supabase.co/functions/v1/livekit-token",
///        "secretSet": true},
///       {"id": "oracle-1", "name": "Oracle self-host",
///        "serverUrl": "wss://live.example.duckdns.org",
///        "tokenUrl": "https://xxx.supabase.co/functions/v1/livekit-token",
///        "secretSet": false}
///     ]
///   }
/// "secretSet" is a BOOLEAN ONLY — it tells the admin panel to show
/// SET / NOT SET. It is NOT a secret and must never carry one.
/// The real per-project api_key/api_secret live ONLY in
/// livekit_project_secrets (migration 016, service-role-only),
/// written via the livekit-save-secret Edge Function and read by
/// the livekit-token function for the ACTIVE project only.
///
/// FAILOVER, HONEST LIMIT: a LiveKit room lives on ONE project.
/// Switching the active project DISCONNECTS any live test session
/// and requires a fresh join — a room cannot transfer between
/// projects mid-call. The admin switch UI says exactly that.
class LiveKitProject {
  final String id;
  final String name;
  final String serverUrl;
  final String tokenUrl;
  // Boolean ONLY: true when livekit-save-secret has stored this
  // project's key/secret in livekit_project_secrets. Never holds,
  // and never must hold, a key or secret value itself.
  final bool secretSet;
  const LiveKitProject({
    required this.id,
    required this.name,
    required this.serverUrl,
    required this.tokenUrl,
    this.secretSet = false,
  });
  bool get isComplete => id.isNotEmpty && serverUrl.isNotEmpty && tokenUrl.isNotEmpty;
  LiveKitProject copyWith({String? name, String? serverUrl, String? tokenUrl, bool? secretSet}) => LiveKitProject(
        id: id,
        name: name ?? this.name,
        serverUrl: serverUrl ?? this.serverUrl,
        tokenUrl: tokenUrl ?? this.tokenUrl,
        secretSet: secretSet ?? this.secretSet,
      );
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'serverUrl': serverUrl, 'tokenUrl': tokenUrl, 'secretSet': secretSet};
  static LiveKitProject fromJson(Map<String, dynamic> m) => LiveKitProject(
        id: SupaDb.strOf(m['id']),
        name: SupaDb.strOf(m['name'], SupaDb.strOf(m['id'])),
        serverUrl: SupaDb.strOf(m['serverUrl'], SupaDb.strOf(m['server_url'])),
        tokenUrl: SupaDb.strOf(m['tokenUrl'], SupaDb.strOf(m['token_url'])),
        secretSet: m['secretSet'] == true || m['hasSecret'] == true,
      );
}

class LiveKitConfig {
  final List<LiveKitProject> projects;
  final String activeProjectId;
  const LiveKitConfig({required this.projects, required this.activeProjectId});
  bool get isConfigured => activeProject != null && activeProject!.isComplete;
  LiveKitProject? get activeProject {
    for (final p in projects) {
      if (p.id == activeProjectId) return p;
    }
    return projects.isEmpty ? null : projects.first;
  }

  static LiveKitConfig parse(dynamic raw) {
    Map<String, dynamic> m = {};
    if (raw is Map) {
      m = Map<String, dynamic>.from(raw);
    } else if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) m = Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    final list = <LiveKitProject>[];
    final rawProjects = m['projects'];
    if (rawProjects is List) {
      for (final p in rawProjects) {
        if (p is Map) {
          final proj = LiveKitProject.fromJson(Map<String, dynamic>.from(p));
          if (proj.id.isNotEmpty) list.add(proj);
        }
      }
    }
    // Single-project shorthand (no projects list): treat the object
    // itself as one project, so a minimal admin setup also works.
    if (list.isEmpty && SupaDb.strOf(m['serverUrl'], SupaDb.strOf(m['server_url'])).isNotEmpty) {
      list.add(LiveKitProject.fromJson(m));
    }
    return LiveKitConfig(
      projects: list,
      activeProjectId: SupaDb.strOf(m['activeProjectId'], SupaDb.strOf(m['active_project_id'], list.isEmpty ? '' : list.first.id)),
    );
  }

  Map<String, dynamic> toJson() => {
        'activeProjectId': activeProjectId,
        'projects': projects.map((p) => p.toJson()).toList(),
      };

  /// Reads the live config from app_settings. Returns an empty
  /// config (isConfigured == false) when the column/row is absent —
  /// callers must show "not configured", never connect anyway.
  static Future<LiveKitConfig> load() async {
    try {
      final settings = await SupaDb.getAppSettings();
      return parse(settings['livekit']);
    } catch (_) {
      return const LiveKitConfig(projects: [], activeProjectId: '');
    }
  }

  /// ADMIN-ONLY, fail closed: the caller MUST already have verified
  /// the designated admin (see the room panel's _isAdminForBroadcast
  /// guard, and the LiveKit Projects management page's entry check).
  /// Returns false when the write fails — e.g. migration 015 not
  /// applied yet — so the UI can say so honestly instead of
  /// pretending the change landed. Never stores any API key or
  /// secret: projects carry only id/name/serverUrl/tokenUrl plus
  /// the boolean secretSet flag, all non-secret. Each project's
  /// token secret lives ONLY in livekit_project_secrets
  /// (migration 016, service-role-only), written via the
  /// livekit-save-secret Edge Function; a project selected here
  /// still fails to mint tokens until its secret is saved there.
  static Future<bool> saveConfig(LiveKitConfig config) async {
    try {
      // Row-match check (audit fix 2026-11-21): the old bare update
      // returned true even when it matched NO row (e.g. the livekit
      // column missing pre-migration 015) — the admin saw "saved"
      // and nothing had changed. .select('id') proves the row landed.
      final rows = await SupaDb.client
          .from('app_settings')
          .update({'livekit': config.toJson()})
          .eq('id', 1)
          .select('id');
      if ((rows as List).isEmpty) return false;
      // Audit row (same fix): a voice-config change used to leave no
      // trace in the admin activity log. Best-effort — a failed audit
      // write never fails the save itself.
      // Direct insert (same columns as AdminDb.logAdminActivity) —
      // kept dependency-free on purpose: a failed audit write must
      // never fail the save itself. (FIX 32: the old import-cycle
      // note is obsolete — the admin login screen is gone.)
      try {
        final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
        await SupaDb.client.from('admin_activity_logs').insert({
          'admin_uid': uid,
          'action': 'update_livekit_config',
          'target_type': 'app_settings',
          'target_id': '1',
          'new_value':
              'activeProjectId=${config.activeProjectId}, projects=${config.projects.length}',
        });
      } catch (_) {}
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> setActiveProject(LiveKitConfig config, String projectId) async {
    return saveConfig(LiveKitConfig(projects: config.projects, activeProjectId: projectId));
  }

  /// Server-side mic-approval grant for the token function
  /// (migration 015 table `livekit_mic_grants`). Written by the
  /// ADMIN's phone at approval time, alongside the existing inbox
  /// mic_approved row (which the mesh flow still owns). Best-effort
  /// by design: if the table does not exist yet the grant is simply
  /// absent and the token function fail-closes the caller to
  /// subscribe-only — approval itself is never blocked by this.
  static Future<void> writeMicGrant(String roomId, String uid) async {
    try {
      final expires = DateTime.now().add(const Duration(minutes: 2)).toIso8601String();
      await SupaDb.client.from('livekit_mic_grants').insert({
        'room_id': roomId,
        'firebase_uid': uid,
        'expires_at': expires,
      });
    } catch (_) {}
  }
}
