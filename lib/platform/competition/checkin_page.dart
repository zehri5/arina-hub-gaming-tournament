import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:protournament_user/platform/competition/checkin_service.dart'
    show kNoShowRuleText; // Shared no-show rule text only — the page
// no longer uses CheckInService (local store); see the doc comment.
import 'package:protournament_user/platform/core/lifecycle.dart';
import 'package:protournament_user/platform/core/roles.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/utils.dart';

/// Check-in page (blueprint §5-2; backend guide §5-2 `check_ins`).
///
/// Captain view: window status, deadline countdown, Check In
/// button, and the no-show rule (10-minute grace, then entry fee
/// forfeit — no refund). Admin section (only when
/// [RoleService.canVerifyResults] allows the viewer's role): open/
/// close the window, close check-in (marks absences, promotes the
/// waitlist, writes the exception report), and the absent list.
///
/// NOT wired into main.dart navigation — the coordinator wires it.
/// Push it with:
/// `Navigator.push(context, MaterialPageRoute(builder: (_) =>
/// CheckInPage(tournamentId: ..., teamId: ..., captainUid: ...)))`.
/// Pass `viewerRole` so admins see the admin section.
///
/// SERVER-BACKED (Batch 3B, 2026-11-22 — was local-store only):
/// the window reads from the tournament row (`check_in_open_at` /
/// `check_in_deadline` / `check_in_locked`, written by the live
/// 050 `open_check_in` RPC); captain check-in writes the real
/// `match_checkins` table via `SupaDb.checkInToMatch` (client
/// dedupe on (tournament_id, firebase_uid)); admin open/close go
/// through the live 050 `open_check_in` / `close_check_in` RPCs.
/// The old local-store `CheckInService` is no longer used here.
class CheckInPage extends StatefulWidget {
  final String tournamentId;
  final String teamId;
  final String captainUid;

  /// Role of the viewer; admins (organizer / regional / super)
  /// see the admin section. Defaults to player.
  final AppRole viewerRole;

  const CheckInPage({
    super.key,
    required this.tournamentId,
    required this.teamId,
    required this.captainUid,
    this.viewerRole = AppRole.player,
  });

  @override
  State<CheckInPage> createState() => _CheckInPageState();
}

class _CheckInPageState extends State<CheckInPage> {
  final TextEditingController _minutesController =
      TextEditingController(text: '30');

  CheckInWindow _window = CheckInWindow.notOpened;
  DateTime? _deadline;
  CheckInStatus? _myStatus;
  List<String> _absentTeamIds = [];
  bool _loading = true;
  bool _busy = false;
  String? _message;

  bool get _isAdmin => RoleService.canVerifyResults(widget.viewerRole);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _minutesController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // Server state only: the tournament row carries the window
    // (open_check_in writes check_in_open_at / check_in_deadline /
    // check_in_locked) and match_checkins carries the entries.
    // A failed read leaves the previous state on screen and the
    // loading flag clears — the page never spins forever on a
    // dead network.
    try {
      final t = await SupaDb.getTournament(widget.tournamentId);
      final rows = await SupaDb.getMatchCheckins(widget.tournamentId);
      if (!mounted) return;
      final locked =
          t['check_in_locked'] == true || t['checkInLocked'] == true;
      final openMs =
          SupaDb.parseTs(t['check_in_open_at'] ?? t['checkInOpenAt']);
      final deadlineMs = SupaDb.parseTs(
          t['check_in_deadline'] ?? t['checkInDeadline']);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      CheckInWindow window;
      DateTime? deadline;
      if (openMs <= 0) {
        window = CheckInWindow.notOpened;
      } else if (locked || (deadlineMs > 0 && nowMs > deadlineMs)) {
        window = CheckInWindow.closed;
        if (deadlineMs > 0) {
          deadline = DateTime.fromMillisecondsSinceEpoch(deadlineMs);
        }
      } else {
        window = CheckInWindow.open;
        if (deadlineMs > 0) {
          deadline = DateTime.fromMillisecondsSinceEpoch(deadlineMs);
        }
      }
      // My entry: a tournament-level row for this captain
      // (match_id NULL rows only — a per-match row is a different
      // check-in). A row with no status (pre-050 minimal shape)
      // counts as "not checked in" until the server says otherwise.
      CheckInStatus? myStatus;
      for (final row in rows) {
        if (SupaDb.strOf(row['match_id']).isNotEmpty) continue;
        final capUid = SupaDb.strOf(row['captain_firebase_uid']);
        final fUid = SupaDb.strOf(row['firebase_uid']);
        if (capUid == widget.captainUid ||
            (capUid.isEmpty && fUid == widget.captainUid)) {
          myStatus = CheckInStatus.fromString(
              SupaDb.strOf(row['status']), CheckInStatus.absent);
          break;
        }
      }
      setState(() {
        _window = window;
        _deadline = deadline;
        _myStatus = myStatus;
        _absentTeamIds = rows
            .where((r) => SupaDb.strOf(r['status']) == 'absent')
            .map((r) {
              final teamId = SupaDb.strOf(r['team_id']);
              if (teamId.isNotEmpty) return teamId;
              return SupaDb.strOf(r['firebase_uid']);
            })
            .where((e) => e.isNotEmpty)
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _checkIn() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    // F11: server check-in with client dedupe — a second tap /
    // retry after the first insert landed returns already:true
    // instead of writing a duplicate row.
    final res = await SupaDb.checkInToMatch(
        tournamentId: widget.tournamentId, uid: widget.captainUid);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res['ok'] == true) {
        _message = res['already'] == true
            ? tr('Already checked in.', 'Check-in pehle hi ho gaya hai.')
            : tr('Checked in. Good luck!', 'Check-in ho gaya. Good luck!');
      } else {
        _message =
            'Check-in failed: ${SupaDb.strOf(res['error'], 'dobara try karen.')}';
      }
    });
    await _load();
  }

  Future<void> _openWindow() async {
    final minutes = int.tryParse(_minutesController.text.trim()) ?? 30;
    setState(() => _busy = true);
    final adminUid =
        FirebaseAuth.instance.currentUser?.uid ?? widget.captainUid;
    final res = await SupaDb.openCheckInWindow(
        tournamentId: widget.tournamentId, adminUid: adminUid);
    if (res['ok'] == true) {
      // The RPC takes its times from the 'check_in' schedule item
      // (or now() + no deadline). When it set NO deadline, apply
      // the admin's chosen window length — best-effort, never a
      // failure of the open itself.
      try {
        final result = SupaDb.asMap(res['result']);
        if (SupaDb.parseTs(result['check_in_deadline']) <= 0) {
          final openMs = SupaDb.parseTs(result['check_in_open_at']);
          final openAt = openMs > 0
              ? DateTime.fromMillisecondsSinceEpoch(openMs)
              : DateTime.now();
          await SupaDb.client.from('tournaments').update({
            'check_in_deadline': openAt
                .add(Duration(minutes: minutes))
                .toUtc()
                .toIso8601String(),
          }).eq('id', widget.tournamentId);
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = res['ok'] == true
          ? tr('Check-in window opened.', 'Check-in window khul gaya hai.')
          : 'Window open nahi hua: ${SupaDb.strOf(res['error'])}';
    });
    await _load();
  }

  Future<void> _closeWindow() async {
    setState(() => _busy = true);
    // No "close window only" RPC exists — closing the window is
    // the check_in_locked flag open_check_in itself writes. Direct
    // update on the tournaments row (001 anon_all, same as the
    // admin create/edit writes); the full close (absent + waitlist
    // promotion + exception report) is close_check_in below.
    String? error;
    try {
      await SupaDb.client
          .from('tournaments')
          .update({'check_in_locked': true}).eq('id', widget.tournamentId);
    } catch (e) {
      error = e.toString();
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = error == null
          ? tr('Check-in window closed.', 'Check-in window band hai.')
          : 'Window close nahi hua: $error';
    });
    await _load();
  }

  Future<void> _closeCheckIn() async {
    setState(() => _busy = true);
    // F11: the 050 close_check_in RPC derives the expected teams
    // from the confirmed registrations itself — every confirmed
    // registrant without a check-in row is marked absent, waitlist
    // entries are promoted, and a no-show exception row (entry fee
    // forfeit, no refund) is written per absent captain. No
    // expected-team list is typed any more.
    final adminUid =
        FirebaseAuth.instance.currentUser?.uid ?? widget.captainUid;
    final res = await SupaDb.closeCheckInWindow(
        tournamentId: widget.tournamentId, adminUid: adminUid);
    if (!mounted) return;
    if (res['ok'] != true) {
      setState(() {
        _busy = false;
        _message =
            'Check-in close nahi hua: ${SupaDb.strOf(res['error'])}';
      });
      return;
    }
    // Counts come from the RPC itself; the absent list is re-read
    // from match_checkins by _load (same source the admin sees).
    final result = SupaDb.asMap(res['result']);
    final absent = SupaDb.intOf(result['absent'], 0);
    final promoted = SupaDb.intOf(result['promoted'], 0);
    setState(() {
      _busy = false;
      _message = tr(
        'Check-in closed. $absent absent, $promoted promoted from the waitlist.',
        'Check-in band ho gaya. $absent absent, $promoted waitlist se promote hue.',
      );
    });
    await _load();
  }

  String _deadlineText() {
    final deadline = _deadline;
    if (deadline == null) return '';
    final remaining = deadline.difference(DateTime.now());
    final time =
        '${deadline.hour.toString().padLeft(2, '0')}:${deadline.minute.toString().padLeft(2, '0')}';
    if (remaining.isNegative) {
      return tr('Deadline was $time (passed).',
          'Deadline $time thi (guzar gayi).');
    }
    final mins = remaining.inMinutes;
    return tr('Deadline $time — $mins min left.',
        'Deadline $time — $mins baqi hain.');
  }

  @override
  Widget build(BuildContext context) {
    final checkedIn = _myStatus == CheckInStatus.checkedIn;
    final late = _myStatus == CheckInStatus.late;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        iconTheme: IconThemeData(color: kGold),
        title: Text(tr('Check-in', 'Check-in'),
            style: TextStyle(color: kText)),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: kGold))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  MockupCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_window.label,
                            style: TextStyle(
                                color: kGold,
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        if (_deadline != null)
                          Text(_deadlineText(),
                              style:
                                  TextStyle(color: kText, fontSize: 14)),
                        const SizedBox(height: 8),
                        Text(
                          checkedIn
                              ? tr('Your team is checked in.',
                                  'Aap ki team ka check-in ho gaya hai.')
                              : late
                                  ? tr('Your team is marked late.',
                                      'Aap ki team late mark hai.')
                                  : tr('Your team has not checked in yet.',
                                      'Aap ki team ne abhi check-in nahi kiya.'),
                          style: TextStyle(color: kMuted, fontSize: 13),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: kGold,
                              foregroundColor: Colors.black,
                            ),
                            onPressed:
                                (_busy || checkedIn) ? null : _checkIn,
                            child: Text(checkedIn
                                ? tr('Checked in', 'Check-in ho gaya')
                                : tr('Check In', 'Check In karen')),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // No-show rule — always visible, stated plainly.
                  MockupCard(
                    child: Text(
                      kNoShowRuleText,
                      style: TextStyle(color: kText, fontSize: 13),
                    ),
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 12),
                    Text(_message!,
                        style: TextStyle(color: kMuted, fontSize: 13)),
                  ],
                  if (_isAdmin) ...[
                    const SizedBox(height: 20),
                    Text(tr('Admin — check-in control',
                            'Admin — check-in control'),
                        style: TextStyle(
                            color: kSectionLabel,
                            fontSize: 14,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    MockupCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: _minutesController,
                            keyboardType: TextInputType.number,
                            style: TextStyle(color: kText),
                            decoration: InputDecoration(
                              labelText: tr('Window length (minutes)',
                                  'Window kitne minute (minutes)'),
                              labelStyle: TextStyle(color: kMuted),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: kGold,
                                    foregroundColor: Colors.black,
                                  ),
                                  onPressed: _busy ? null : _openWindow,
                                  child: Text(tr('Open window',
                                      'Window kholen')),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: kText,
                                    side: BorderSide(color: kBorder),
                                  ),
                                  onPressed: _busy ? null : _closeWindow,
                                  child: Text(tr('Close window',
                                      'Window band karen')),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            tr('Close marks every confirmed team that has not checked in as absent and promotes the waitlist (server-side).',
                                'Close karne par har confirmed team jo check-in nahi kar saki absent mark hogi aur waitlist promote hogi (server-side).'),
                            style:
                                TextStyle(color: kMuted, fontSize: 13),
                          ),
                          const SizedBox(height: 12),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: kGold,
                              foregroundColor: Colors.black,
                              // PHASE E (E20): the old label wrapped
                              // into 2 cramped lines — the short
                              // label + roomy padding fits one line
                              // at 360px (the line above already
                              // explains what Close does).
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 14),
                              textStyle: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700),
                            ),
                            onPressed: _busy ? null : _closeCheckIn,
                            child: Text(tr('Close check-in',
                                'Check-in band karen')),
                          ),
                        ],
                      ),
                    ),
                    if (_absentTeamIds.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      MockupCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(tr('Absent teams', 'Absent teams'),
                                style: TextStyle(
                                    color: kGold,
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            for (final teamId in _absentTeamIds)
                              Padding(
                                padding:
                                    const EdgeInsets.only(bottom: 6),
                                child: Text(teamId,
                                    style: TextStyle(
                                        color: kText, fontSize: 14)),
                              ),
                            const SizedBox(height: 8),
                            Text(
                              tr('No-show teams lose their entry fee — no refund.',
                                  'No-show teams ki entry fee wapas NAHI hogi — koi refund nahi.'),
                              style: TextStyle(
                                  color: kMuted, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
    );
  }
}
