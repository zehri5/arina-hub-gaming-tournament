import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:protournament_user/platform/core/exceptions.dart';
import 'package:protournament_user/platform/core/roles.dart';
import 'package:protournament_user/platform/disputes/dispute_service.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/utils.dart';

/// Admin-side Action Required Center (ChatGPT blueprint §5-7;
/// backend guide §5-7 `disputes` + `exception_reports`).
///
/// Queue of open ActionItems (player disputes + auto-generated
/// exceptions) grouped by type with severity. Tap an item for
/// detail + actions: Mark under review / Resolve with resolution
/// text / Reject with reason.
///
/// ACCESS: admin-only. The role is resolved from the caller's
/// profile via [RoleService.roleOf], with super-admin granted
/// ONLY when the Firebase UID equals the designated admin UID in
/// `admin_config` id=1 (the same check as
/// `fetchDesignatedAdminUid` in services/admin_config.dart —
//  mirrored here to avoid importing that service). Entry requires
/// [RoleService.canModerate] or [RoleService.canVerifyResults];
/// anyone else sees an access-denied state. This gates the UI
/// only — real enforcement is a backend handoff item (anon-key
/// auth model, guide §2).
class ActionRequiredPage extends StatefulWidget {
  const ActionRequiredPage({super.key});

  @override
  State<ActionRequiredPage> createState() => _ActionRequiredPageState();
}

class _ActionRequiredPageState extends State<ActionRequiredPage> {
  final _service = DisputeService();
  bool _loading = true;
  bool _allowed = false;
  bool _showAll = false;
  String _adminUid = '';
  List<DisputeRecord> _items = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _verifyAndLoad();
  }

  Future<void> _verifyAndLoad() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      String adminUid = '';
      try {
        final rows = await SupaDb.getList('admin_config', eqCol: 'id', eqVal: 1);
        if (rows.isNotEmpty) {
          adminUid = SupaDb.strOf(rows.first['admin_firebase_uid']);
        }
      } catch (_) {
        adminUid = '';
      }
      final profile =
          uid.isEmpty ? <String, dynamic>{} : await SupaDb.getProfile(uid);
      final role = RoleService.roleOf(profile,
          isSuperAdmin: uid.isNotEmpty && uid == adminUid);
      final allowed =
          RoleService.canModerate(role) || RoleService.canVerifyResults(role);
      if (!mounted) return;
      if (!allowed) {
        setState(() {
          _allowed = false;
          _loading = false;
        });
        return;
      }
      _adminUid = uid;
      await _loadItems();
      if (!mounted) return;
      setState(() {
        _allowed = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = tr('Could not load the queue: $e',
            'Queue load nahi hui: $e');
        _loading = false;
      });
    }
  }

  Future<void> _loadItems() async {
    final items =
        _showAll ? await _service.listAll() : await _service.listOpenExceptions();
    if (!mounted) return;
    setState(() => _items = items);
  }

  Color _severityColor(ExceptionSeverity s) => switch (s) {
        ExceptionSeverity.high => kRed,
        ExceptionSeverity.medium => Colors.orange,
        ExceptionSeverity.low => kMuted,
      };

  Color _statusColor(DisputeStatus s) => switch (s) {
        DisputeStatus.open => kGold,
        DisputeStatus.underReview => Colors.orange,
        DisputeStatus.resolved => kGreen,
        DisputeStatus.rejected => kRed,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        title: Text(tr('Action Required', 'Action Required'),
            style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
        iconTheme: IconThemeData(color: kGold),
        actions: [
          if (_allowed)
            IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _loading ? null : _loadItems),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: kGold))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: kText)),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _verifyAndLoad,
                          style: ElevatedButton.styleFrom(
                              backgroundColor: kGold,
                              foregroundColor: Colors.black),
                          child: Text(tr('Retry', 'Dobara koshish karen')),
                        ),
                      ],
                    ),
                  ),
                )
              : !_allowed
                  ? _accessDenied()
                  : RefreshIndicator(
                      color: kGold,
                      onRefresh: _loadItems,
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          _filterRow(),
                          const SizedBox(height: 12),
                          if (_items.isEmpty)
                            MockupCard(
                              animate: false,
                              child: Text(
                                _showAll
                                    ? tr('No disputes or exceptions yet.',
                                        'Abhi tak koi dispute ya exception nahi hai.')
                                    : tr('Nothing needs action right now.',
                                        'Abhi kisi action ki zaroorat nahi hai.'),
                                style: TextStyle(color: kMuted),
                              ),
                            )
                          else
                            ..._groupedWidgets(),
                        ],
                      ),
                    ),
    );
  }

  Widget _accessDenied() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, color: kGold, size: 48),
            const SizedBox(height: 16),
            Text(
              tr('Access denied', 'Access denied'),
              style:
                  TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              tr('Only admins and organizers can see the Action Required Center.',
                  'Sirf admin aur organizer hi Action Required Center dekh sakte hain.'),
              textAlign: TextAlign.center,
              style: TextStyle(color: kMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterRow() {
    return Row(
      children: [
        _filterChip(tr('Open', 'Khule hue'), !_showAll, () {
          setState(() => _showAll = false);
          _loadItems();
        }),
        const SizedBox(width: 8),
        _filterChip(tr('All', 'Sab'), _showAll, () {
          setState(() => _showAll = true);
          _loadItems();
        }),
        const Spacer(),
        Text(
          tr('${_items.length} items', '${_items.length} items'),
          style: TextStyle(color: kMuted, fontSize: 13),
        ),
      ],
    );
  }

  Widget _filterChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? kGold : kSurface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? kGold : kBorder),
        ),
        child: Text(
          label,
          style: TextStyle(
              color: selected ? Colors.black : kText,
              fontWeight: FontWeight.bold,
              fontSize: 13),
        ),
      ),
    );
  }

  /// Groups the queue by type, highest severity first.
  List<Widget> _groupedWidgets() {
    final groups = <ExceptionType, List<DisputeRecord>>{};
    for (final r in _items) {
      (groups[r.type] ??= []).add(r);
    }
    final types = groups.keys.toList()
      ..sort((a, b) {
        final sev = b.severity.index.compareTo(a.severity.index);
        if (sev != 0) return sev;
        return a.label.compareTo(b.label);
      });
    final out = <Widget>[];
    for (final type in types) {
      final items = groups[type]!;
      final sevColor = _severityColor(type.severity);
      out.add(
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 8),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration:
                    BoxDecoration(color: sevColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${type.label} (${items.length})',
                  style: TextStyle(
                      color: kText,
                      fontWeight: FontWeight.bold,
                      fontSize: 16),
                ),
              ),
              Text(
                type.severity.label,
                style: TextStyle(color: sevColor, fontSize: 12),
              ),
            ],
          ),
        ),
      );
      for (final r in items) {
        out.add(_itemCard(r));
      }
    }
    return out;
  }

  Widget _itemCard(DisputeRecord r) {
    final color = _statusColor(r.status);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: MockupCard(
        animate: false,
        child: InkWell(
          onTap: () => _openDetail(r),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      r.title.isNotEmpty ? r.title : r.type.label,
                      style: TextStyle(
                          color: kText,
                          fontWeight: FontWeight.bold,
                          fontSize: 15),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: color.withValues(alpha: 0.5)),
                    ),
                    child: Text(r.status.label,
                        style: TextStyle(
                            color: color,
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                r.detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: kMuted, fontSize: 13),
              ),
              if (r.createdAt != null) ...[
                const SizedBox(height: 6),
                Text(
                  fmtDate(r.createdAt!.millisecondsSinceEpoch),
                  style: TextStyle(color: kMuted, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openDetail(DisputeRecord r) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text(r.type.label,
            style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _detailRow(tr('Status', 'Status'), r.status.label),
              _detailRow(tr('Severity', 'Severity'), r.type.severity.label),
              if (r.tournamentId.isNotEmpty)
                _detailRow(tr('Tournament', 'Tournament'), r.tournamentId),
              if (r.matchId.isNotEmpty)
                _detailRow(tr('Match', 'Match'), r.matchId),
              if (r.reportedBy.isNotEmpty)
                _detailRow(tr('Reported by', 'Report karne wala'), r.reportedBy),
              _detailRow(tr('Detail', 'Tafseel'), r.detail),
              if (r.evidenceUrls.isNotEmpty)
                _detailRow(tr('Evidence', 'Saboot'), r.evidenceUrls.join('\n')),
              if (r.resolution.isNotEmpty)
                _detailRow(tr('Resolution', 'Resolution'), r.resolution),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Close', 'Band karen'),
                style: TextStyle(color: kMuted)),
          ),
          if (r.needsAction) ...[
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await _service.markUnderReview(r.id);
                await _loadItems();
                if (mounted) {
                  toast(context, tr('Marked under review.', 'Review mein mark kar diya.'));
                }
              },
              child: Text(tr('Under review', 'Review mein'),
                  style: TextStyle(color: Colors.orange)),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await _askTextAndAct(
                  title: tr('Reject dispute', 'Dispute reject karen'),
                  hint: tr('Reason for rejection', 'Reject karne ki wajah'),
                  onSubmit: (text) =>
                      _service.rejectDispute(r.id, text, _adminUid),
                  doneMsg: tr('Dispute rejected.', 'Dispute reject ho gayi.'),
                );
              },
              child: Text(tr('Reject', 'Reject'), style: TextStyle(color: kRed)),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await _askTextAndAct(
                  title: tr('Resolve dispute', 'Dispute hal karen'),
                  hint: tr('Resolution — what was decided?',
                      'Resolution — kya faisla hua?'),
                  onSubmit: (text) =>
                      _service.resolveDispute(r.id, text, _adminUid),
                  doneMsg: tr('Dispute resolved.', 'Dispute hal ho gayi.'),
                );
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: kGold, foregroundColor: Colors.black),
              child: Text(tr('Resolve', 'Hal karen')),
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  color: kMuted, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(color: kText, fontSize: 14)),
        ],
      ),
    );
  }

  Future<void> _askTextAndAct({
    required String title,
    required String hint,
    required Future<bool> Function(String text) onSubmit,
    required String doneMsg,
  }) async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text(title,
            style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          autofocus: true,
          style: TextStyle(color: kText),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: kMuted),
            filled: true,
            fillColor: kField,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: kBorder)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                Text(tr('Cancel', 'Cancel'), style: TextStyle(color: kMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: ElevatedButton.styleFrom(
                backgroundColor: kGold, foregroundColor: Colors.black),
            child: Text(tr('Confirm', 'Confirm karen')),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (text == null || text.isEmpty || !mounted) return;
    final ok = await onSubmit(text);
    await _loadItems();
    if (mounted) {
      toast(context,
          ok ? doneMsg : tr('Could not save. Try again.', 'Save nahi hua. Dobara koshish karen.'));
    }
  }
}
