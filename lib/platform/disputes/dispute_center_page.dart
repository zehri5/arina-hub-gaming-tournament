import 'package:flutter/material.dart';
import 'package:protournament_user/platform/core/exceptions.dart';
import 'package:protournament_user/platform/disputes/dispute_service.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/utils.dart';

/// Player-side Dispute Center (ChatGPT blueprint §5-7; backend
/// guide §5-7 `disputes` table).
///
/// A player files a dispute (kind picker incl. `other`, detail,
/// evidence screenshot URL) and sees their own disputes with
/// status badges + the admin's resolution text once resolved.
///
/// Storage is local ([DisputeService]) until the backend `disputes`
/// table lands. Evidence URLs are screenshot URLs stored as given
/// — a screenshot is dispute evidence, never payment proof.
class DisputeCenterPage extends StatefulWidget {
  final String uid;
  final String? tournamentId;

  const DisputeCenterPage({super.key, required this.uid, this.tournamentId});

  @override
  State<DisputeCenterPage> createState() => _DisputeCenterPageState();
}

class _DisputeCenterPageState extends State<DisputeCenterPage> {
  final _service = DisputeService();
  final _detailCtrl = TextEditingController();
  final _evidenceCtrl = TextEditingController();

  ExceptionType _kind = ExceptionType.wrongScore;
  String? _selectedTournamentId;
  List<Map<String, dynamic>> _tournaments = [];
  List<DisputeRecord> _mine = [];
  bool _loading = true;
  bool _filing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectedTournamentId = widget.tournamentId;
    _load();
  }

  @override
  void dispose() {
    _detailCtrl.dispose();
    _evidenceCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final mine = await _service.listMyDisputes(widget.uid);
      List<Map<String, dynamic>> tournaments = [];
      if (widget.tournamentId == null) {
        tournaments = await SupaDb.getTournaments();
      }
      if (!mounted) return;
      setState(() {
        _mine = mine;
        _tournaments = tournaments;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = tr('Could not load disputes: $e',
            'Disputes load nahi hue: $e');
        _loading = false;
      });
    }
  }

  List<String> _parseEvidenceUrls(String raw) => raw
      .split(RegExp(r'[\s,]+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  Future<void> _file() async {
    final detail = _detailCtrl.text.trim();
    if (detail.isEmpty) {
      toast(context, tr('Please describe the problem first.',
          'Pehle masla likhen.'));
      return;
    }
    setState(() => _filing = true);
    await _service.fileDispute(
      tournamentId: _selectedTournamentId ?? '',
      kind: _kind,
      detail: detail,
      evidenceUrls: _parseEvidenceUrls(_evidenceCtrl.text),
      reportedBy: widget.uid,
    );
    if (!mounted) return;
    _detailCtrl.clear();
    _evidenceCtrl.clear();
    setState(() => _filing = false);
    toast(context,
        tr('Dispute filed. The admin will review it.', 'Dispute bhej di gayi. Admin review karega.'));
    await _load();
  }

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
        title: Text(tr('Dispute Center', 'Dispute Center'),
            style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
        iconTheme: IconThemeData(color: kGold),
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
                          onPressed: _load,
                          style: ElevatedButton.styleFrom(
                              backgroundColor: kGold,
                              foregroundColor: Colors.black),
                          child: Text(tr('Retry', 'Dobara koshish karen')),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  color: kGold,
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _fileForm(),
                      const SizedBox(height: 20),
                      Text(
                        tr('My disputes', 'Meri disputes'),
                        style: TextStyle(
                            color: kText,
                            fontWeight: FontWeight.bold,
                            fontSize: 17),
                      ),
                      const SizedBox(height: 12),
                      if (_mine.isEmpty)
                        MockupCard(
                          animate: false,
                          child: Text(
                            tr('No disputes filed yet.',
                                'Abhi tak koi dispute nahi bheji.'),
                            style: TextStyle(color: kMuted),
                          ),
                        )
                      else
                        ..._mine.map(_disputeCard),
                    ],
                  ),
                ),
    );
  }

  Widget _fileForm() {
    return MockupCard(
      animate: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('File a dispute', 'Dispute file karen'),
            style:
                TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 12),
          if (widget.tournamentId == null) ...[
            DropdownButtonFormField<String>(
              value: _tournaments.any(
                      (t) => SupaDb.strOf(t['id']) == _selectedTournamentId)
                  ? _selectedTournamentId
                  : null,
              decoration: InputDecoration(
                labelText: tr('Tournament (optional)', 'Tournament (optional)'),
                labelStyle: TextStyle(color: kMuted),
                filled: true,
                fillColor: kField,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: kBorder)),
              ),
              dropdownColor: kSurface,
              style: TextStyle(color: kText),
              items: _tournaments
                  .map((t) => DropdownMenuItem<String>(
                        value: SupaDb.strOf(t['id']),
                        child: Text(SupaDb.strOf(t['name'], 'Tournament')),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _selectedTournamentId = v),
            ),
            const SizedBox(height: 12),
          ],
          DropdownButtonFormField<ExceptionType>(
            value: _kind,
            decoration: InputDecoration(
              labelText: tr('What happened?', 'Kya hua?'),
              labelStyle: TextStyle(color: kMuted),
              filled: true,
              fillColor: kField,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: kBorder)),
            ),
            dropdownColor: kSurface,
            style: TextStyle(color: kText),
            items: ExceptionType.values
                .map((k) =>
                    DropdownMenuItem<ExceptionType>(value: k, child: Text(k.label)))
                .toList(),
            onChanged: (v) {
              if (v != null) setState(() => _kind = v);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _detailCtrl,
            maxLines: 4,
            style: TextStyle(color: kText),
            decoration: InputDecoration(
              labelText: tr('Describe the problem', 'Masla tafseel se likhen'),
              labelStyle: TextStyle(color: kMuted),
              filled: true,
              fillColor: kField,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: kBorder)),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _evidenceCtrl,
            style: TextStyle(color: kText),
            decoration: InputDecoration(
              labelText: tr('Evidence screenshot link (optional)',
                  'Saboot screenshot ka link (optional)'),
              labelStyle: TextStyle(color: kMuted),
              filled: true,
              fillColor: kField,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: kBorder)),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _filing ? null : _file,
              style: ElevatedButton.styleFrom(
                  backgroundColor: kGold, foregroundColor: Colors.black),
              child: _filing
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.black))
                  : Text(tr('Submit dispute', 'Dispute bhejen')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _disputeCard(DisputeRecord r) {
    final color = _statusColor(r.status);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: MockupCard(
        animate: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    r.type.label,
                    style: TextStyle(
                        color: kText, fontWeight: FontWeight.bold, fontSize: 15),
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
            const SizedBox(height: 8),
            Text(r.detail, style: TextStyle(color: kText, fontSize: 14)),
            if (r.evidenceUrls.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                tr('Evidence: ${r.evidenceUrls.join(', ')}',
                    'Saboot: ${r.evidenceUrls.join(', ')}'),
                style: TextStyle(color: kMuted, fontSize: 12),
              ),
            ],
            if ((r.status == DisputeStatus.resolved ||
                    r.status == DisputeStatus.rejected) &&
                r.resolution.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: kField,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  tr('Admin reply: ${r.resolution}',
                      'Admin ka jawab: ${r.resolution}'),
                  style: TextStyle(color: kText, fontSize: 13),
                ),
              ),
            ],
            if (r.createdAt != null) ...[
              const SizedBox(height: 8),
              Text(
                fmtDate(r.createdAt!.millisecondsSinceEpoch),
                style: TextStyle(color: kMuted, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
