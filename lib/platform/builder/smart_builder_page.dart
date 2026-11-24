import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:protournament_user/platform/core/local_store.dart';
import 'package:protournament_user/platform/core/regions.dart';
import 'package:protournament_user/platform/core/scoring.dart';
import 'package:protournament_user/platform/core/tournament_enums.dart';
import 'package:protournament_user/services/admin_db_tournaments.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/utils.dart';

import 'builder_validation.dart';
import 'rules_impact.dart';
import 'schedule_kind.dart';
import 'tournament_draft.dart';

/// SMART TOURNAMENT BUILDER (ChatGPT blueprint §3 — 7 sections).
///
/// A 7-step wizard: (A) Basic info, (B) Competition config,
/// (C) Registration config, (D) Entry model, (E) Schedule,
/// (F) Rules & scoring, (G) Publish & preview.
///
/// WIRING (coordinator): push this page directly —
/// `SmartBuilderPage(existing: draft, organizationId: orgId)`.
/// `existing` edits a draft; omit it for a new tournament.
/// `existingRegistrations` / `existingVerifiedResults` feed the
/// rules-change impact warning on step F (default 0).
/// This page is NOT wired into main.dart navigation — the
/// coordinator owns the entry point.
///
/// DRAFT AUTO-SAVE: the draft is saved to [PlatformLocalStore]
/// (area 'builder', id = draft id or 'new') on every step change,
/// so an interrupted builder session resumes from the local draft.
///
/// PUBLISH — WHAT THE SERVER GETS TODAY: publish writes ONLY the
/// `tournaments` columns verified to exist, via the EXISTING
/// [AdminDbTournaments.createTournament] / `updateTournament` path
/// (the same retry ladder the admin form uses): name, game_name,
/// game_id (looked up from the `games` table by name, best-effort),
/// mode, entry_fee, prize_pool, per_kill_prize, max_players,
/// status ('upcoming' — the app's live status; the guide's
/// 'published' is kept on the LOCAL draft only), start_time (first
/// match schedule item), created_by, tags ([category]), description,
/// rules, map (first map in the pool), registration_deadline
/// (registration end), lobby_opens_at (check-in item start),
/// banner_url, commission_pct (10, the platform default).
///
/// EVERYTHING ELSE stays in the local draft until the backend
/// batch lands the guide's columns — see the report for the full
/// list (organization_id, visibility, game_mode, elimination,
/// registration_type/registrant, entry_model, schedule items,
/// scoring template, policies, ...). The local draft is kept after
/// publish so those fields are not lost.
///
/// APPROVED-PAID GATE (guide §3-D): publish is BLOCKED unless
/// paidApprovedAt / paidApprovedBy are set. The builder has NO
/// approval flow and NO input for those fields — they can only
/// arrive on an existing draft (set by Super Admin tooling). The
/// gate text is: "Paid entry needs Super Admin approval — contact
/// support".
class SmartBuilderPage extends StatefulWidget {
  /// Draft to edit (null = new tournament).
  final TournamentDraft? existing;

  /// Owning organization id. When non-empty it overrides the
  /// draft's organizationId; '' = the user's own org / unknown.
  final String? organizationId;

  /// Registrations already on the tournament (for the step-F
  /// rules-change impact warning). Default 0.
  final int existingRegistrations;

  /// Verified results already on the tournament (same warning).
  final int existingVerifiedResults;

  const SmartBuilderPage({
    super.key,
    this.existing,
    this.organizationId,
    this.existingRegistrations = 0,
    this.existingVerifiedResults = 0,
  });

  @override
  State<SmartBuilderPage> createState() => _SmartBuilderPageState();
}

const List<String> _knownMaps = [
  'Erangel',
  'Miramar',
  'Sanhok',
  'Vikendi',
  'Livik',
  'Karakin',
  'Nusa',
];

class _SmartBuilderPageState extends State<SmartBuilderPage> {
  late TournamentDraft _draft;
  int _step = 0;
  bool _busy = false;
  bool _showIssues = false;
  late final String _initialScoringId;
  late final String _initialScheduleJson;

  late final TextEditingController _title;
  late final TextEditingController _organizerName;
  late final TextEditingController _category;
  late final TextEditingController _description;
  late final TextEditingController _rules;
  late final TextEditingController _contactInfo;
  late final TextEditingController _supportInfo;
  late final TextEditingController _bannerUrl;
  late final TextEditingController _logoUrl;
  late final TextEditingController _prizePool;
  late final TextEditingController _perKillPrize;
  late final TextEditingController _serverRegion;
  late final TextEditingController _maxTeams;
  late final TextEditingController _minTeams;
  late final TextEditingController _matchCount;
  late final TextEditingController _substituteLimit;
  late final TextEditingController _substitutePolicy;
  late final TextEditingController _entryFee;
  late final TextEditingController _refundPolicy;
  late final TextEditingController _cancellationPolicy;
  late final TextEditingController _postponementPolicy;
  late final TextEditingController _customMaps;
  late final TextEditingController _killPoints;
  late final TextEditingController _bonusRules;
  late final TextEditingController _penalties;
  late final TextEditingController _tiebreakers;
  late final TextEditingController _dqRules;
  late final List<TextEditingController> _placementCtrls;
  final Set<String> _selectedMaps = {};

  List<String> get _stepTitles => [
        tr('Basic info', 'Bunyadi info'),
        tr('Competition', 'Competition'),
        tr('Registration', 'Registration'),
        tr('Entry model', 'Entry model'),
        tr('Schedule', 'Schedule'),
        tr('Rules & scoring', 'Rules & scoring'),
        tr('Publish', 'Publish'),
      ];

  @override
  void initState() {
    super.initState();
    _draft = widget.existing?.copy() ?? TournamentDraft();
    final orgId = widget.organizationId;
    if (orgId != null && orgId.isNotEmpty) {
      _draft.organizationId = orgId;
    }
    _initialScoringId = _draft.scoringTemplateId;
    _initialScheduleJson = _draft.scheduleItems
        .map((s) => '${s.kind.wireValue}:${s.startsAt?.toIso8601String()}')
        .join('|');

    final d = _draft;
    _title = TextEditingController(text: d.title);
    _organizerName = TextEditingController(text: d.organizerName);
    _category = TextEditingController(text: d.category);
    _description = TextEditingController(text: d.description);
    _rules = TextEditingController(text: d.rules);
    _contactInfo = TextEditingController(text: d.contactInfo);
    _supportInfo = TextEditingController(text: d.supportInfo);
    _bannerUrl = TextEditingController(text: d.bannerUrl);
    _logoUrl = TextEditingController(text: d.logoUrl);
    _prizePool =
        TextEditingController(text: d.prizePool > 0 ? '${d.prizePool}' : '');
    _perKillPrize = TextEditingController(
        text: d.perKillPrize > 0 ? '${d.perKillPrize}' : '');
    _serverRegion = TextEditingController(text: d.serverRegion);
    _maxTeams =
        TextEditingController(text: d.maxTeams > 0 ? '${d.maxTeams}' : '');
    _minTeams =
        TextEditingController(text: d.minTeams > 0 ? '${d.minTeams}' : '');
    _matchCount = TextEditingController(text: '${d.matchCount}');
    _substituteLimit = TextEditingController(
        text: d.substituteLimit > 0 ? '${d.substituteLimit}' : '');
    _substitutePolicy = TextEditingController(text: d.substitutePolicy);
    _entryFee = TextEditingController(
        text: (d.entryFee ?? 0) > 0 ? '${d.entryFee}' : '');
    _refundPolicy = TextEditingController(text: d.refundPolicy);
    _cancellationPolicy = TextEditingController(text: d.cancellationPolicy);
    _postponementPolicy = TextEditingController(text: d.postponementPolicy);
    _killPoints =
        TextEditingController(text: '${d.scoringTemplate.killPoints}');
    _bonusRules =
        TextEditingController(text: d.scoringTemplate.bonusRules.join('\n'));
    _penalties =
        TextEditingController(text: d.scoringTemplate.penalties.join('\n'));
    _tiebreakers = TextEditingController(
        text: d.scoringTemplate.tieBreakers.join('\n'));
    _dqRules = TextEditingController(
        text: d.scoringTemplate.disqualifyOn.join('\n'));
    _placementCtrls = List.generate(8, (i) {
      final pts = d.scoringTemplate.placementPoints[i + 1];
      return TextEditingController(text: pts == null ? '' : '$pts');
    });
    final customMaps = <String>[];
    for (final m in d.mapPool) {
      if (_knownMaps.contains(m)) {
        _selectedMaps.add(m);
      } else {
        customMaps.add(m);
      }
    }
    _customMaps = TextEditingController(text: customMaps.join(', '));
  }

  @override
  void dispose() {
    // Fire-and-forget final save — the draft must survive an
    // interrupted session even if the user leaves mid-step.
    unawaited(_saveDraft());
    for (final c in [
      _title,
      _organizerName,
      _category,
      _description,
      _rules,
      _contactInfo,
      _supportInfo,
      _bannerUrl,
      _logoUrl,
      _prizePool,
      _perKillPrize,
      _serverRegion,
      _maxTeams,
      _minTeams,
      _matchCount,
      _substituteLimit,
      _substitutePolicy,
      _entryFee,
      _refundPolicy,
      _cancellationPolicy,
      _postponementPolicy,
      _customMaps,
      _killPoints,
      _bonusRules,
      _penalties,
      _tiebreakers,
      _dqRules,
      ..._placementCtrls,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // ---------- draft persistence ----------

  Future<bool> _saveDraft() {
    if (_draft.id.isEmpty) {
      _draft.id =
          'draft-${DateTime.now().millisecondsSinceEpoch}';
    }
    return PlatformLocalStore.saveDraft(
        'builder', _draft.id, _draft.toMap());
  }

  void _goTo(int step) {
    unawaited(_saveDraft());
    setState(() {
      _step = step.clamp(0, 6);
      _showIssues = false;
    });
  }

  // ---------- helpers ----------

  void _syncMapPool() {
    final maps = <String>{..._selectedMaps};
    for (final part in _customMaps.text.split(',')) {
      final m = part.trim();
      if (m.isNotEmpty) maps.add(m);
    }
    _draft.mapPool = maps.toList();
  }

  List<String> _lines(TextEditingController c) => c.text
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  /// Rebuilds the custom scoring template from the placement +
  /// rules editors (step F). Only used when the Custom template is
  /// selected; Default is the fixed core constant. (The Legacy-022
  /// option was removed from the picker: the superseded 15/12/10
  /// table must never be chosen for new tournaments — the constant
  /// survives only for the player-stats server mirror.)
  void _syncCustomTemplate() {
    if (_draft.scoringTemplateId != 'custom') return;
    final placement = <int, int>{};
    for (var i = 0; i < _placementCtrls.length; i++) {
      final v = int.tryParse(_placementCtrls[i].text.trim());
      if (v != null && v > 0) placement[i + 1] = v;
    }
    _draft.scoringTemplate = ScoringTemplate(
      id: 'custom',
      name: 'Custom',
      placementPoints: placement,
      killPoints: int.tryParse(_killPoints.text.trim()) ?? 1,
      bonusRules: _lines(_bonusRules),
      penalties: _lines(_penalties),
      tieBreakers: _lines(_tiebreakers),
      disqualifyOn: _lines(_dqRules),
    );
  }

  void _setTemplate(String id) {
    setState(() {
      _draft.scoringTemplateId = id;
      if (id == 'default') {
        _draft.scoringTemplate = kDefaultScoringTemplate;
      } else if (id == 'legacy-022') {
        _draft.scoringTemplate = kLegacy022ScoringTemplate;
      } else {
        _syncCustomTemplate();
      }
    });
  }

  bool get _scoringChanged =>
      _draft.scoringTemplateId != _initialScoringId;

  bool get _scheduleChanged =>
      _draft.scheduleItems
          .map((s) =>
              '${s.kind.wireValue}:${s.startsAt?.toIso8601String()}')
          .join('|') !=
      _initialScheduleJson;

  String _fmtDateTime(DateTime? dt) {
    if (dt == null) return tr('Not set', 'Set nahi hai');
    final l = dt.toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final hh = l.hour.toString().padLeft(2, '0');
    final mm = l.minute.toString().padLeft(2, '0');
    return '${l.day} ${months[l.month - 1]} ${l.year}, $hh:$mm';
  }

  Future<DateTime?> _pickDateTime(DateTime? initial) async {
    final now = DateTime.now();
    final base = initial?.toLocal() ?? now.add(const Duration(days: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: base.isBefore(now) ? now : base,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute)
        .toUtc();
  }

  void _addScheduleItem() {
    final present = _draft.scheduleItems.map((s) => s.kind).toSet();
    var kind = ScheduleKind.match;
    for (final k in kRequiredScheduleKinds) {
      if (!present.contains(k)) {
        kind = k;
        break;
      }
    }
    final now = DateTime.now();
    final start =
        DateTime(now.year, now.month, now.day + 1, 18, 0).toUtc();
    setState(() {
      _draft.scheduleItems.add(ScheduleItem(
        kind: kind,
        startsAt: start,
        timezone: _draft.timezone,
      ));
    });
  }

  // ---------- publish ----------

  /// The server row: ONLY columns verified to exist in
  /// `tournaments` today (see the class doc). Everything else stays
  /// in the local draft.
  Future<Map<String, dynamic>> _serverRow() async {
    final d = _draft;
    // Best-effort game_id lookup: match the draft's game name
    // against the real `games` rows. No match = omit the column
    // (game_name still lands).
    String gameId = '';
    try {
      final games = await SupaDb.getGamesForPicker();
      final want = d.game.toLowerCase().trim();
      for (final g in games) {
        final name = SupaDb.strOf(g['name']).toLowerCase();
        if (name.isNotEmpty &&
            (name == want ||
                name.contains(want) ||
                want.contains(name))) {
          gameId = SupaDb.strOf(g['id']);
          break;
        }
      }
    } catch (_) {
      // Lookup failed — publish continues without game_id.
    }
    final matchStart = d.scheduleItem(ScheduleKind.match)?.startsAt;
    final checkInStart =
        d.scheduleItem(ScheduleKind.checkIn)?.startsAt;
    final mode = switch (d.teamMode) {
      TeamMode.solo => 'Solo',
      TeamMode.duo => 'Duo',
      TeamMode.squad => 'Squad',
    };
    final row = <String, dynamic>{
      'name': d.title.trim(),
      'game_name': d.game,
      if (gameId.isNotEmpty) 'game_id': gameId,
      'mode': mode,
      'entry_fee': d.entryFee ?? 0,
      'prize_pool': d.prizePool,
      'per_kill_prize': d.perKillPrize,
      'max_players': d.maxPlayers,
      // Status is decided in _publish, not here: a NEW tournament
      // goes to 'pending' (admin approval queue, same as the user
      // Create Tournament form); an EDIT never touches the live
      // status. The old code wrote 'upcoming' unconditionally, so a
      // builder publish skipped approval entirely AND an edit could
      // resurrect a cancelled/completed tournament (audit fix
      // 2026-11-21).
      'status': 'pending',
      'start_time': matchStart?.toUtc().toIso8601String(),
      'created_by': FirebaseAuth.instance.currentUser?.uid ?? '',
      'tags': d.category.trim().isEmpty ? <String>[] : [d.category.trim()],
      'description': d.description.trim(),
      'rules': d.rules.trim(),
      'map': d.mapPool.isEmpty ? '' : d.mapPool.first,
      'registration_deadline':
          d.registrationEnd?.toUtc().toIso8601String(),
      'lobby_opens_at': checkInStart?.toUtc().toIso8601String(),
      'banner_url': d.bannerUrl.trim(),
      // Platform default 10% (same constant the admin form uses).
      'commission_pct': 10,
    };
    return row;
  }

  Future<void> _publish() async {
    final blocking =
        validateForPublish(_draft).where((i) => i.blocking).toList();
    if (blocking.isNotEmpty) {
      setState(() => _showIssues = true);
      if (mounted) {
        toast(
          context,
          tr(
            'Fix the blocking issues before publishing.',
            'Publish se pehle blocking issues theek karein.',
          ),
        );
      }
      return;
    }
    setState(() => _busy = true);
    try {
      final row = await _serverRow();
      final Map<String, dynamic> res;
      final serverId = _draft.serverId;
      final isEdit = serverId != null && serverId.isNotEmpty;
      if (isEdit) {
        // Edit: never touch the live status (or created_by).
        final values = Map<String, dynamic>.from(row)
          ..remove('created_by')
          ..remove('status');
        res = await AdminDbTournaments.updateTournament(
          serverId,
          values,
          oldValues: {'name': _draft.title},
        ).timeout(const Duration(seconds: 30));
      } else {
        // New: 'pending' — the admin approval queue decides when it
        // goes live (same as the user Create Tournament form).
        res = await AdminDbTournaments.createTournament(row)
            .timeout(const Duration(seconds: 30));
      }
      if (!mounted) return;
      if (res['ok'] == true) {
        _draft.status = 'published';
        final inserted = res['row'];
        if (inserted is Map) {
          final id = SupaDb.strOf(inserted['id']);
          if (id.isNotEmpty) _draft.serverId = id;
        }
        await _saveDraft();
        if (!mounted) return;
        var msg = isEdit
            ? tr(
                'Tournament updated.',
                'Tournament update ho gaya.',
              )
            : tr(
                'Tournament sent for review. It will go live once the admin approves it.',
                'Tournament review ke liye bhej diya gaya — admin approve karega to live hoga.',
              );
        if (res['full'] == false) {
          msg = tr(
            'Saved, but some fields could not be saved yet (database update pending).',
            'Save ho gaya, lekin kuch fields abhi save nahi hue (database update baaki hai).',
          );
        }
        toast(context, msg);
        Navigator.pop(context, true);
      } else {
        toast(context, friendlyDbError(res['error']));
      }
    } catch (e) {
      debugPrint('[SmartBuilder] publish failed: $e');
      if (mounted) toast(context, friendlyDbError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- UI helpers ----------

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6, top: 4),
        child: Text(
          text,
          style: TextStyle(
            color: kSectionLabel,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
      );

  InputDecoration _decoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: kMuted),
        filled: true,
        fillColor: kField,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: kBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: kBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: kGold),
        ),
      );

  Widget _textField({
    required TextEditingController controller,
    required String label,
    String? hint,
    int maxLines = 1,
    TextInputType? keyboardType,
    required ValueChanged<String> onChanged,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(label),
          TextField(
            controller: controller,
            maxLines: maxLines,
            keyboardType: keyboardType,
            style: TextStyle(color: kText),
            decoration: _decoration(hint ?? label),
            onChanged: onChanged,
          ),
          const SizedBox(height: 8),
        ],
      );

  Widget _chip<T>({
    required T value,
    required T selected,
    required String label,
    required ValueChanged<T> onSelected,
  }) {
    final active = value == selected;
    return ChoiceChip(
      label: Text(label),
      selected: active,
      onSelected: (_) => onSelected(value),
      selectedColor: kGold,
      backgroundColor: kField,
      labelStyle: TextStyle(
        color: active ? Colors.black : kText,
        fontWeight: active ? FontWeight.bold : FontWeight.normal,
      ),
      side: BorderSide(color: active ? kGold : kBorder),
    );
  }

  Widget _toggleChip({
    required String label,
    required bool selected,
    required ValueChanged<bool> onSelected,
  }) =>
      FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: onSelected,
        selectedColor: kGold,
        backgroundColor: kField,
        labelStyle: TextStyle(
          color: selected ? Colors.black : kText,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        ),
        side: BorderSide(color: selected ? kGold : kBorder),
      );

  Widget _switchRow({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(color: kText)),
          ),
          Switch(
            value: value,
            activeThumbColor: kGold,
            onChanged: onChanged,
          ),
        ],
      );

  Widget _dateRow({
    required String label,
    required DateTime? value,
    required ValueChanged<DateTime?> onPicked,
    bool clearable = false,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(label),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    color: kField,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: kBorder),
                  ),
                  child: Text(
                    _fmtDateTime(value),
                    style: TextStyle(
                        color: value == null ? kMuted : kText),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () async {
                  final picked = await _pickDateTime(value);
                  if (picked != null) onPicked(picked);
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: kGold,
                  side: BorderSide(color: kGold),
                ),
                child: Text(tr('Pick', 'Chunein')),
              ),
              if (clearable && value != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () => onPicked(null),
                  icon: Icon(Icons.clear, color: kMuted),
                  tooltip: tr('Clear', 'Saaf karein'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
        ],
      );

  Widget _card(Widget child) => MockupCard(
        padding: const EdgeInsets.all(16),
        animate: false,
        child: child,
      );

  Widget _warningBox(String text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: kGold.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kGold.withValues(alpha: 0.5)),
        ),
        child: Text(text, style: TextStyle(color: kText, fontSize: 13)),
      );

  // ---------- steps ----------

  Widget _stepHeader() {
    final titles = _stepTitles;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (var i = 0; i < 7; i++) ...[
              InkWell(
                onTap: () => _goTo(i),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == _step
                        ? kGold
                        : (i < _step
                            ? kGold.withValues(alpha: 0.35)
                            : kField),
                    border: Border.all(
                      color: i <= _step ? kGold : kBorder,
                    ),
                  ),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      color: i == _step ? Colors.black : kText,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
              if (i < 6)
                Expanded(
                  child: Container(
                    height: 2,
                    color: i < _step ? kGold : kBorder,
                  ),
                ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '${tr('Step', 'Step')} ${_step + 1} ${tr('of', 'of')} 7 — ${titles[_step]}',
          style: TextStyle(
            color: kText,
            fontSize: 17,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          tr(
            'Draft auto-saves on every step.',
            'Draft har step par khud save hota hai.',
          ),
          style: TextStyle(color: kMuted, fontSize: 12),
        ),
      ],
    );
  }

  Widget _stepA() {
    final d = _draft;
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _textField(
            controller: _title,
            label: tr('Tournament title', 'Tournament title'),
            onChanged: (v) => d.title = v,
          ),
          _textField(
            controller: _description,
            label: tr('Description', 'Description'),
            maxLines: 3,
            onChanged: (v) => d.description = v,
          ),
          _textField(
            controller: _organizerName,
            label: tr('Organizer name', 'Organizer ka naam'),
            onChanged: (v) => d.organizerName = v,
          ),
          _textField(
            controller: _category,
            label: tr('Category', 'Category'),
            hint: 'e.g. Weekly Cup',
            onChanged: (v) => d.category = v,
          ),
          _sectionLabel(tr('Game', 'Game')),
          Text(
            d.game,
            style: TextStyle(color: kText, fontSize: 15),
          ),
          const SizedBox(height: 12),
          _textField(
            controller: _bannerUrl,
            label: tr('Banner image URL', 'Banner image URL'),
            onChanged: (v) => d.bannerUrl = v,
          ),
          _textField(
            controller: _logoUrl,
            label: tr('Logo image URL', 'Logo image URL'),
            onChanged: (v) => d.logoUrl = v,
          ),
          _sectionLabel(tr('Visibility', 'Visibility')),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final v in TournamentVisibility.values)
                _chip<TournamentVisibility>(
                  value: v,
                  selected: d.visibility,
                  label: v.label,
                  onSelected: (nv) =>
                      setState(() => d.visibility = nv),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (d.visibility == TournamentVisibility.selectedCountries) ...[
            _sectionLabel(
                tr('Allowed countries', 'Allowed countries')),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in kSupportedCountries)
                  _toggleChip(
                    label: c.name,
                    selected: d.allowedCountryCodes.contains(c.code),
                    onSelected: (on) => setState(() {
                      if (on) {
                        d.allowedCountryCodes.add(c.code);
                      } else {
                        d.allowedCountryCodes.remove(c.code);
                      }
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          _sectionLabel(tr('Country', 'Mulk')),
          DropdownButtonFormField<String>(
            initialValue: d.countryCode,
            dropdownColor: kCard,
            style: TextStyle(color: kText),
            decoration: _decoration(tr('Country', 'Mulk')),
            items: [
              for (final c in kSupportedCountries)
                DropdownMenuItem(value: c.code, child: Text(c.name)),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() {
                d.countryCode = v;
                d.timezone = RegionService.countryFor(v).timezone;
              });
            },
          ),
          const SizedBox(height: 8),
          _sectionLabel(tr('Timezone', 'Timezone')),
          DropdownButtonFormField<String>(
            initialValue: d.timezone,
            dropdownColor: kCard,
            style: TextStyle(color: kText),
            decoration: _decoration(tr('Timezone', 'Timezone')),
            items: [
              for (final tz in {
                for (final c in kSupportedCountries) c.timezone,
              })
                DropdownMenuItem(value: tz, child: Text(tz)),
            ],
            onChanged: (v) {
              if (v != null) setState(() => d.timezone = v);
            },
          ),
          const SizedBox(height: 8),
          _sectionLabel(tr('Language', 'Language')),
          DropdownButtonFormField<String>(
            initialValue: d.language,
            dropdownColor: kCard,
            style: TextStyle(color: kText),
            decoration: _decoration(tr('Language', 'Language')),
            items: [
              for (final lang in {
                for (final c in kSupportedCountries)
                  ...c.languageCodes,
              })
                DropdownMenuItem(value: lang, child: Text(lang)),
            ],
            onChanged: (v) {
              if (v != null) setState(() => d.language = v);
            },
          ),
          const SizedBox(height: 8),
          _switchRow(
            label: tr('Public tournament', 'Public tournament'),
            value: d.isPublic,
            onChanged: (v) => setState(() => d.isPublic = v),
          ),
          _textField(
            controller: _contactInfo,
            label: tr('Contact info', 'Contact info'),
            onChanged: (v) => d.contactInfo = v,
          ),
          _textField(
            controller: _supportInfo,
            label: tr('Support info', 'Support info'),
            onChanged: (v) => d.supportInfo = v,
          ),
        ],
      ),
    );
  }

  Widget _stepB() {
    final d = _draft;
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(tr('Game mode', 'Game mode')),
          Wrap(
            spacing: 8,
            children: [
              for (final m in GameMode.values)
                _chip<GameMode>(
                  value: m,
                  selected: d.gameMode,
                  label: m.label,
                  onSelected: (nv) => setState(() => d.gameMode = nv),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _sectionLabel(tr('Perspective', 'Perspective')),
          Wrap(
            spacing: 8,
            children: [
              for (final p in Perspective.values)
                _chip<Perspective>(
                  value: p,
                  selected: d.perspective,
                  label: p.label,
                  onSelected: (nv) => setState(() => d.perspective = nv),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _sectionLabel(tr('Team mode', 'Team mode')),
          Wrap(
            spacing: 8,
            children: [
              for (final t in TeamMode.values)
                _chip<TeamMode>(
                  value: t,
                  selected: d.teamMode,
                  label: t.label,
                  onSelected: (nv) => setState(() => d.teamMode = nv),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _sectionLabel(tr('Maps', 'Maps')),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in _knownMaps)
                _toggleChip(
                  label: m,
                  selected: _selectedMaps.contains(m),
                  onSelected: (on) => setState(() {
                    if (on) {
                      _selectedMaps.add(m);
                    } else {
                      _selectedMaps.remove(m);
                    }
                    _syncMapPool();
                  }),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _textField(
            controller: _customMaps,
            label: tr('Other maps (comma separated)',
                'Aur maps (comma se alag)'),
            onChanged: (_) => _syncMapPool(),
          ),
          _textField(
            controller: _serverRegion,
            label: tr('Server region', 'Server region'),
            hint: 'e.g. Asia',
            onChanged: (v) => d.serverRegion = v,
          ),
          Row(
            children: [
              Expanded(
                child: _textField(
                  controller: _maxTeams,
                  label: tr('Max teams', 'Max teams'),
                  keyboardType: TextInputType.number,
                  onChanged: (v) =>
                      d.maxTeams = int.tryParse(v.trim()) ?? 0,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _textField(
                  controller: _matchCount,
                  label: tr('Matches', 'Matches'),
                  keyboardType: TextInputType.number,
                  onChanged: (v) =>
                      d.matchCount = int.tryParse(v.trim()) ?? 1,
                ),
              ),
            ],
          ),
          _textField(
            controller: _substituteLimit,
            label: tr('Substitute limit', 'Substitute limit'),
            keyboardType: TextInputType.number,
            onChanged: (v) =>
                d.substituteLimit = int.tryParse(v.trim()) ?? 0,
          ),
          _sectionLabel(tr('Stages', 'Stages')),
          Wrap(
            spacing: 8,
            children: [
              for (final s in StageType.values)
                _toggleChip(
                  label: s.label,
                  selected: d.stages.contains(s),
                  onSelected: (on) => setState(() {
                    if (on) {
                      d.stages.add(s);
                    } else {
                      d.stages.remove(s);
                    }
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _sectionLabel(tr('Format', 'Format')),
          Wrap(
            spacing: 8,
            children: [
              for (final f in TournamentFormat.values)
                _chip<TournamentFormat>(
                  value: f,
                  selected: d.format,
                  label: f.label,
                  onSelected: (nv) => setState(() => d.format = nv),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // The server has ONE `elimination` column: knockout
          // formats pick the elimination type, everything else
          // picks the match format (see tournament_draft.dart).
          if (d.format == TournamentFormat.knockout) ...[
            _sectionLabel(tr('Elimination', 'Elimination')),
            Wrap(
              spacing: 8,
              children: [
                for (final e in EliminationType.values)
                  _chip<EliminationType>(
                    value: e,
                    selected: d.elimination,
                    label: e.label,
                    onSelected: (nv) =>
                        setState(() => d.elimination = nv),
                  ),
              ],
            ),
          ] else ...[
            _sectionLabel(tr('Match format', 'Match format')),
            Wrap(
              spacing: 8,
              children: [
                for (final m in MatchFormat.values)
                  _chip<MatchFormat>(
                    value: m,
                    selected: d.matchFormat,
                    label: m.label,
                    onSelected: (nv) =>
                        setState(() => d.matchFormat = nv),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Text(
            tr(
              'Max players: ${d.maxPlayers} (${d.maxTeams} teams x ${d.teamSize})',
              'Max players: ${d.maxPlayers} (${d.maxTeams} teams x ${d.teamSize})',
            ),
            style: TextStyle(color: kMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _stepC() {
    final d = _draft;
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(tr('Registration mode', 'Registration mode')),
          Wrap(
            spacing: 8,
            children: [
              for (final m in RegistrationMode.values)
                _chip<RegistrationMode>(
                  value: m,
                  selected: d.registrationMode,
                  label: m.label,
                  onSelected: (nv) =>
                      setState(() => d.registrationMode = nv),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _dateRow(
            label: tr('Registration starts', 'Registration shuru'),
            value: d.registrationStart,
            onPicked: (v) => setState(() => d.registrationStart = v),
          ),
          _dateRow(
            label: tr('Registration ends', 'Registration khatam'),
            value: d.registrationEnd,
            onPicked: (v) => setState(() => d.registrationEnd = v),
          ),
          _dateRow(
            label: tr('Roster lock at (optional)',
                'Roster lock (optional)'),
            value: d.rosterLockAt,
            clearable: true,
            onPicked: (v) => setState(() => d.rosterLockAt = v),
          ),
          _textField(
            controller: _minTeams,
            label: tr('Minimum teams', 'Minimum teams'),
            keyboardType: TextInputType.number,
            onChanged: (v) => d.minTeams = int.tryParse(v.trim()) ?? 0,
          ),
          _switchRow(
            label: tr('Waitlist enabled', 'Waitlist on hai'),
            value: d.waitlistEnabled,
            onChanged: (v) => setState(() => d.waitlistEnabled = v),
          ),
          _switchRow(
            label: tr(
                'Verification required', 'Verification zaroori hai'),
            value: d.verificationRequired,
            onChanged: (v) =>
                setState(() => d.verificationRequired = v),
          ),
          _textField(
            controller: _substitutePolicy,
            label: tr('Substitute policy', 'Substitute policy'),
            maxLines: 3,
            onChanged: (v) => d.substitutePolicy = v,
          ),
        ],
      ),
    );
  }

  Widget _stepD() {
    final d = _draft;
    String description(EntryModel m) => switch (m) {
          EntryModel.free => tr(
              'No entry fee — anyone can join.',
              'Koi entry fee nahi — koi bhi join kar sakta hai.',
            ),
          EntryModel.sponsored => tr(
              'A sponsor covers the prizes — players join free.',
              'Sponsor prizes deta hai — players free join karte hain.',
            ),
          EntryModel.organizerFunded => tr(
              'You fund the prizes yourself — players join free.',
              'Prizes aap khud dete hain — players free join karte hain.',
            ),
          EntryModel.approvedPaid => tr(
              'Players pay an entry fee — needs Super Admin approval first.',
              'Players entry fee dete hain — pehle Super Admin ki approval chahiye.',
            ),
        };
    final gateBlocked = d.entryModel == EntryModel.approvedPaid &&
        (d.paidApprovedAt == null ||
            (d.paidApprovedBy ?? '').trim().isEmpty);
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(tr('Entry model', 'Entry model')),
          for (final m in EntryModel.values) ...[
            InkWell(
              onTap: () => setState(() => d.entryModel = m),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: d.entryModel == m
                      ? kGold.withValues(alpha: 0.12)
                      : kField,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: d.entryModel == m ? kGold : kBorder,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      d.entryModel == m
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      color:
                          d.entryModel == m ? kGold : kMuted,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            m.label,
                            style: TextStyle(
                              color: kText,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            description(m),
                            style: TextStyle(
                                color: kMuted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (gateBlocked) ...[
            const SizedBox(height: 4),
            _warningBox(tr(
              'Paid entry needs Super Admin approval — contact support. Publish stays blocked until approval is set.',
              'Paid entry ke liye Super Admin ki approval chahiye — support se rabta karein. Approval ke baghair publish nahi hoga.',
            )),
            const SizedBox(height: 8),
          ],
          if (d.entryModel == EntryModel.approvedPaid)
            _textField(
              controller: _entryFee,
              label: tr('Entry fee (Rs)', 'Entry fee (Rs)'),
              keyboardType: TextInputType.number,
              onChanged: (v) =>
                  d.entryFee = double.tryParse(v.trim()),
            ),
          _textField(
            controller: _prizePool,
            label: tr('Prize pool (Rs)', 'Prize pool (Rs)'),
            keyboardType: TextInputType.number,
            onChanged: (v) =>
                d.prizePool = double.tryParse(v.trim()) ?? 0,
          ),
          _textField(
            controller: _perKillPrize,
            label: tr('Per-kill prize (Rs)', 'Per-kill prize (Rs)'),
            keyboardType: TextInputType.number,
            onChanged: (v) =>
                d.perKillPrize = double.tryParse(v.trim()) ?? 0,
          ),
          if (d.entryModel == EntryModel.approvedPaid) ...[
            _textField(
              controller: _refundPolicy,
              label: tr('Refund policy', 'Refund policy'),
              maxLines: 3,
              onChanged: (v) => d.refundPolicy = v,
            ),
            _textField(
              controller: _cancellationPolicy,
              label:
                  tr('Cancellation policy', 'Cancellation policy'),
              maxLines: 3,
              onChanged: (v) => d.cancellationPolicy = v,
            ),
            _textField(
              controller: _postponementPolicy,
              label:
                  tr('Postponement policy', 'Postponement policy'),
              maxLines: 3,
              onChanged: (v) => d.postponementPolicy = v,
            ),
          ],
        ],
      ),
    );
  }

  Widget _stepE() {
    final d = _draft;
    return Column(
      children: [
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(
                  'Times are stored in UTC and shown in your local time. The organizer timezone is ${d.timezone}.',
                  'Waqt UTC mein save hota hai aur aap ke local time mein dikhta hai. Organizer timezone ${d.timezone} hai.',
                ),
                style: TextStyle(color: kMuted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < d.scheduleItems.length; i++) ...[
                _scheduleItemRow(d.scheduleItems[i]),
                const SizedBox(height: 12),
              ],
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _addScheduleItem,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(tr('Add schedule item',
                      'Schedule item add karein')),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kGold,
                    side: BorderSide(color: kGold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _scheduleItemRow(ScheduleItem item) {
    final d = _draft;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kField,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButton<ScheduleKind>(
                  value: item.kind,
                  dropdownColor: kCard,
                  style: TextStyle(color: kText),
                  underline: const SizedBox.shrink(),
                  isExpanded: true,
                  items: [
                    for (final k in ScheduleKind.values)
                      DropdownMenuItem(value: k, child: Text(k.label)),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => item.kind = v);
                  },
                ),
              ),
              IconButton(
                onPressed: () =>
                    setState(() => d.scheduleItems.remove(item)),
                icon: Icon(Icons.delete_outline, color: kRed),
                tooltip: tr('Remove', 'Hatayen'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  _fmtDateTime(item.startsAt),
                  style: TextStyle(color: kText),
                ),
              ),
              OutlinedButton(
                onPressed: () async {
                  final picked =
                      await _pickDateTime(item.startsAt);
                  if (picked != null) {
                    setState(() => item.startsAt = picked);
                  }
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: kGold,
                  side: BorderSide(color: kGold),
                ),
                child: Text(tr('Set time', 'Waqt set karein')),
              ),
            ],
          ),
          if (item.startsAt != null) ...[
            const SizedBox(height: 4),
            Text(
              RegionService.formatInTimezone(
                item.startsAt!,
                item.timezone.isEmpty ? d.timezone : item.timezone,
              ),
              style: TextStyle(color: kMuted, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stepF() {
    final d = _draft;
    final template = d.scoringTemplate;
    final preview = calculateMatchPoints(
      placement: 1,
      kills: 12,
      template: template,
    );
    final impact = rulesChangeImpact(
      registrationCount: widget.existingRegistrations,
      verifiedResultsCount: widget.existingVerifiedResults,
      scoringChanged: _scoringChanged,
      scheduleChanged: _scheduleChanged,
    );
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _textField(
            controller: _rules,
            label: tr('Tournament rules', 'Tournament rules'),
            maxLines: 5,
            onChanged: (v) => d.rules = v,
          ),
          _sectionLabel(tr('Scoring template', 'Scoring template')),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _chip<String>(
                value: 'default',
                selected: d.scoringTemplateId,
                label: tr('Default (decided)', 'Default (decided)'),
                onSelected: (_) => _setTemplate('default'),
              ),
              _chip<String>(
                value: 'custom',
                selected: d.scoringTemplateId,
                label: tr('Custom', 'Custom'),
                onSelected: (_) => _setTemplate('custom'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            tr(
              '1st place + 12 kills = $preview points (placement ${template.placementPoints[1] ?? 0} + ${template.killPoints} per kill).',
              '1st place + 12 kills = $preview points (placement ${template.placementPoints[1] ?? 0} + ${template.killPoints} per kill).',
            ),
            style: TextStyle(color: kMuted, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            tr(
              'Note: the template choice is a preview for now — scoring always uses the admin template (1st=10, 2nd=7, 3rd=5, +1/kill) until per-tournament templates are saved on the server (backend).',
              'Note: template ka intikhab filhal sirf preview hai — scoring hamesha admin template (1st=10, 2nd=7, 3rd=5, +1/kill) se hoti hai jab tak per-tournament template server par save na ho (backend).',
            ),
            style: TextStyle(color: kMuted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          if (d.scoringTemplateId == 'custom') ...[
            _sectionLabel(
                tr('Placement points (1st–8th)', 'Placement points (1st–8th)')),
            for (var i = 0; i < 8; i++)
              Row(
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(
                      '${i + 1}${i == 0 ? 'st' : i == 1 ? 'nd' : i == 2 ? 'rd' : 'th'}',
                      style: TextStyle(color: kText),
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _placementCtrls[i],
                      keyboardType: TextInputType.number,
                      style: TextStyle(color: kText),
                      decoration: _decoration('0'),
                      onChanged: (_) => _syncCustomTemplate(),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            _textField(
              controller: _killPoints,
              label: tr('Points per kill', 'Points per kill'),
              keyboardType: TextInputType.number,
              onChanged: (_) => _syncCustomTemplate(),
            ),
          ] else ...[
            _sectionLabel(tr('Placement table', 'Placement table')),
            Text(
              template.placementPoints.entries
                  .map((e) => '#${e.key}: ${e.value}')
                  .join('  •  '),
              style: TextStyle(color: kText, fontSize: 13),
            ),
            const SizedBox(height: 12),
          ],
          _textField(
            controller: _bonusRules,
            label: tr('Bonus rules (one per line)',
                'Bonus rules (har line par ek)'),
            maxLines: 3,
            onChanged: (_) => _syncCustomTemplate(),
          ),
          _textField(
            controller: _penalties,
            label: tr('Penalties (one per line)',
                'Penalties (har line par ek)'),
            maxLines: 3,
            onChanged: (_) => _syncCustomTemplate(),
          ),
          _textField(
            controller: _tiebreakers,
            label: tr('Tiebreakers (one per line)',
                'Tiebreakers (har line par ek)'),
            maxLines: 3,
            onChanged: (_) => _syncCustomTemplate(),
          ),
          _textField(
            controller: _dqRules,
            label: tr('Disqualification rules (one per line)',
                'Disqualification rules (har line par ek)'),
            maxLines: 3,
            onChanged: (_) => _syncCustomTemplate(),
          ),
          if (impact.isNotEmpty) ...[
            const SizedBox(height: 4),
            _warningBox(impact),
          ],
        ],
      ),
    );
  }

  Widget _summaryRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 130,
              child: Text(label, style: TextStyle(color: kMuted)),
            ),
            Expanded(
              child: Text(value, style: TextStyle(color: kText)),
            ),
          ],
        ),
      );

  Widget _stepG() {
    final d = _draft;
    final checklist = publishChecklist(d);
    final issues = validateForPublish(d);
    final blocking = issues.where((i) => i.blocking).toList();
    final warnings = issues.where((i) => !i.blocking).toList();
    return Column(
      children: [
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel(tr('Preview', 'Preview')),
              _summaryRow(tr('Title', 'Title'),
                  d.title.isEmpty ? '—' : d.title),
              _summaryRow(tr('Game', 'Game'), d.game),
              _summaryRow(
                  tr('Mode', 'Mode'),
                  '${d.gameMode.label} • ${d.perspective.label} • ${d.teamMode.label}'),
              _summaryRow(tr('Maps', 'Maps'),
                  d.mapPool.isEmpty ? '—' : d.mapPool.join(', ')),
              _summaryRow(
                  tr('Capacity', 'Capacity'),
                  '${d.maxTeams} teams • ${d.maxPlayers} players'),
              _summaryRow(
                  tr('Registration', 'Registration'),
                  '${_fmtDateTime(d.registrationStart)} → ${_fmtDateTime(d.registrationEnd)}'),
              _summaryRow(tr('Entry', 'Entry'),
                  d.entryModel.label),
              _summaryRow(tr('Prize pool', 'Prize pool'),
                  'Rs ${d.prizePool.toStringAsFixed(0)}'),
              _summaryRow(
                  tr('Scoring', 'Scoring'),
                  d.scoringTemplate.name),
              _summaryRow(
                  tr('Schedule items', 'Schedule items'),
                  '${d.scheduleItems.length}'),
              _summaryRow(tr('Visibility', 'Visibility'),
                  d.visibility.label),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel(
                  tr('Publish checklist', 'Publish checklist')),
              for (final item in checklist)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(
                        item.passed
                            ? Icons.check_circle
                            : Icons.cancel,
                        color: item.passed ? kGreen : kRed,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          item.label,
                          style: TextStyle(color: kText),
                        ),
                      ),
                    ],
                  ),
                ),
              if (warnings.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final w in warnings)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '• ${w.message}',
                      style:
                          TextStyle(color: kMuted, fontSize: 12),
                    ),
                  ),
              ],
              if (_showIssues && blocking.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final b in blocking)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '• ${b.message}',
                      style: TextStyle(color: kRed, fontSize: 13),
                    ),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(
                  'Publish writes the tournament with the fields the database has today. New builder fields (visibility, competition config, registration config, entry model, schedule, scoring template, policies) stay in the local draft until the database update lands — nothing is lost.',
                  'Publish tournament ko un fields ke saath likhta hai jo database mein aaj maujood hain. Naye builder fields (visibility, competition config, registration config, entry model, schedule, scoring template, policies) local draft mein rehte hain jab tak database update nahi aata — kuch zaya nahi hota.',
                ),
                style: TextStyle(color: kMuted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: goldButton(
                  label: tr('Publish tournament',
                      'Tournament publish karein'),
                  onPressed: _busy ? null : _publish,
                  busy: _busy,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final steps = [
      _stepA(),
      _stepB(),
      _stepC(),
      _stepD(),
      _stepE(),
      _stepF(),
      _stepG(),
    ];
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        iconTheme: IconThemeData(color: kGold),
        title: boardAppBarTitle(
            tr('Smart Tournament Builder', 'Smart Tournament Builder')),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _stepHeader(),
            const SizedBox(height: 16),
            steps[_step],
            const SizedBox(height: 16),
            Row(
              children: [
                if (_step > 0)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _goTo(_step - 1),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: kText,
                        side: BorderSide(color: kBorder),
                        padding:
                            const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: Text(tr('Back', 'Peeche')),
                    ),
                  ),
                if (_step > 0) const SizedBox(width: 12),
                if (_step < 6)
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => _goTo(_step + 1),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kGold,
                        foregroundColor: Colors.black,
                        padding:
                            const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: Text(
                        tr('Next', 'Aage'),
                        style: const TextStyle(
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
