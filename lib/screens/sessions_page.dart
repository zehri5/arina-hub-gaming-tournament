import 'package:flutter/material.dart';
import '../services/device_ban_gate.dart';
import '../services/supabase_db.dart';
import '../utils.dart'; // also re-exports theme.dart (kGold, MockupCard, …)

/// Login Sessions page (#31, 2026-11-22).
///
/// Lists the real `login_sessions` rows for this user, newest first
/// (written at every sign-in by `AuthScreen._recordLoginSession`):
/// "This Device" + other sessions, with the device name/type,
/// location and last-active time the writer recorded.
///
/// Honest degradation (never invented values):
/// * device_name / device_type / location are shown only when the
///   row carries them — older rows (pre-078 writer) show
///   "Unknown device" / "Unknown location".
/// * last_active_at falls back to created_at; a row with neither
///   shows "N/A" via [fmtDate].
/// * ip is NEVER shown here — it is sensitive data with no in-app
///   use; the column exists only for admin-side review.
/// * "This Device" is badged only when a row's device_id matches
///   this install's id ([DeviceBanGate.localDeviceId]); without a
///   match no row is guessed to be this device. The header card
///   always shows the local device label ([SupaDb.deviceLabel])
///   as "This Device (Active)".
///
/// NAV ENTRY MISSING (blocked, 2026-11-22): this page has no route
/// into it yet — the entry belongs in `AccountSecurityPage`
/// (more_screens.dart, "Login Activity" card), which another agent
/// owns. Do not add the entry here; the page is unreachable until
/// that agent (or a later batch) wires it.
class SessionsPage extends StatefulWidget {
  final String uid;
  const SessionsPage({super.key, required this.uid});

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  bool _loading = true;
  String _localDeviceId = '';
  List<Map<String, dynamic>> _sessions = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final deviceId = await DeviceBanGate.localDeviceId();
    final rows = await SupaDb.getList(
      'login_sessions',
      eqCol: 'firebase_uid',
      eqVal: widget.uid,
      orderBy: 'created_at',
      ascending: false,
      limit: 50,
    );
    if (mounted) {
      setState(() {
        _localDeviceId = deviceId;
        _sessions = rows;
        _loading = false;
      });
    }
  }

  bool _isThisDevice(Map<String, dynamic> s) {
    final id = SupaDb.strOf(s['device_id']);
    return id.isNotEmpty && _localDeviceId.isNotEmpty && id == _localDeviceId;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: kGold, size: 26),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text(
          'LOGIN SESSIONS',
          style: TextStyle(
            color: kText,
            fontSize: 20,
            fontWeight: FontWeight.w900,
            fontStyle: FontStyle.italic,
          ),
        ),
        centerTitle: true,
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: kGold))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                // This Device (Active) — the local install, always
                // shown, even when no login_sessions row matches it
                // yet (e.g. first login after the writer landed).
                MockupCard(
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: kGold, width: 1.5),
                        ),
                        child: Icon(Icons.smartphone, color: kGold, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            RichText(
                              text: TextSpan(
                                style: TextStyle(
                                  color: kText,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                                children: [
                                  const TextSpan(text: 'This Device '),
                                  TextSpan(
                                    text: '(Active)',
                                    style: TextStyle(color: kGold),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              SupaDb.deviceLabel().isEmpty
                                  ? 'Signed in on this device'
                                  : SupaDb.deviceLabel(),
                              style: TextStyle(color: kMuted, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        'Active Now',
                        style: TextStyle(
                          color: kGold,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'RECENT LOGINS',
                  style: TextStyle(
                    color: kGold,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                if (_sessions.isEmpty)
                  MockupCard(
                    child: Text(
                      'No previous logins recorded yet — logins from now on will appear here.',
                      style: TextStyle(color: kMuted, fontSize: 13),
                    ),
                  )
                else
                  for (final s in _sessions) _sessionCard(s),
              ],
            ),
    );
  }

  Widget _sessionCard(Map<String, dynamic> s) {
    final name = SupaDb.strOf(s['device_name']);
    final type = SupaDb.strOf(s['device_type']);
    final location = SupaDb.strOf(s['location']);
    final lastActive = s['last_active_at'] ?? s['created_at'];
    final isMine = _isThisDevice(s);
    final icon = type.toLowerCase().contains('ios') ||
            type.toLowerCase().contains('iphone')
        ? Icons.phone_iphone
        : Icons.smartphone;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: MockupCard(
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: kGold, width: 1.5),
              ),
              child: Icon(icon, color: kGold, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name.isEmpty ? 'Unknown device' : name,
                          style: TextStyle(
                            color: kText,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (isMine)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: kGold,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            'This Device',
                            style: TextStyle(
                              color: Color(0xFF0A0A0F),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (type.isNotEmpty) type,
                      location.isEmpty ? 'Unknown location' : location,
                    ].join(' • '),
                    style: TextStyle(color: kMuted, fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Last active: ${fmtDate(lastActive)}',
                    style: TextStyle(color: kMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
