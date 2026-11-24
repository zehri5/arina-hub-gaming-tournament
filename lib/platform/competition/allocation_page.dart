import 'package:flutter/material.dart';
import 'package:protournament_user/platform/competition/team_allocation.dart';
import 'package:protournament_user/platform/core/local_store.dart';
import 'package:protournament_user/platform/core/roles.dart';
import 'package:protournament_user/platform/core/tournament_enums.dart';
import 'package:protournament_user/utils.dart';

/// Team allocation page (blueprint §5-3; backend guide §5-3
/// `match_teams` + `allocate_teams` RPC).
///
/// ADMIN ONLY: viewers whose role cannot verify results see an
/// access message instead of the tool. Method picker (random /
/// seeded / country / performance / manual), slots list, manual
/// override (tap a team → pick a new slot — swap-based, slots stay
/// unique), and simple text-field inputs for seeds, country codes
/// and ratings where the chosen method needs them.
///
/// NOT wired into main.dart navigation — the coordinator wires it.
/// Push it with:
/// `Navigator.push(context, MaterialPageRoute(builder: (_) =>
/// AllocationPage(matchId: ..., teamIds: ..., viewerRole: ...)))`.
///
/// INTERIM — LOCAL STORE ONLY: the computed allocation is saved to
/// the local store (area `allocation`) until the backend
/// `match_teams` table + `allocate_teams` RPC land.
class AllocationPage extends StatefulWidget {
  final String matchId;
  final List<String> teamIds;

  /// Role of the viewer; only organizers / regional / super admins
  /// may allocate. Defaults to player (access message shown).
  final AppRole viewerRole;

  const AllocationPage({
    super.key,
    required this.matchId,
    required this.teamIds,
    this.viewerRole = AppRole.player,
  });

  @override
  State<AllocationPage> createState() => _AllocationPageState();
}

class _AllocationPageState extends State<AllocationPage> {
  static const String _area = 'allocation';

  TeamAllocationMode _method = TeamAllocationMode.random;
  List<AllocatedSlot> _slots = [];
  bool _loading = true;

  /// Per-team inputs, keyed by team ID. Seeds/ratings are raw
  /// strings from the text fields, parsed on Generate.
  final Map<String, String> _seedInputs = {};
  final Map<String, String> _countryInputs = {};
  final Map<String, String> _ratingInputs = {};
  String _randomSeedInput = '';

  bool get _isAdmin => RoleService.canVerifyResults(widget.viewerRole);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await PlatformLocalStore.loadList(_area, widget.matchId);
    if (!mounted) return;
    setState(() {
      _slots = rows.map(AllocatedSlot.fromMap).toList()
        ..sort((a, b) => a.slot.compareTo(b.slot));
      _loading = false;
    });
  }

  Future<void> _saveSlots() async {
    await PlatformLocalStore.saveList(
        _area, widget.matchId, _slots.map((s) => s.toMap()).toList());
  }

  void _generate() {
    final seeds = <String, int>{};
    for (final e in _seedInputs.entries) {
      final v = int.tryParse(e.value.trim());
      if (v != null) seeds[e.key] = v;
    }
    final countries = <String, String>{};
    for (final e in _countryInputs.entries) {
      if (e.value.trim().isNotEmpty) countries[e.key] = e.value.trim();
    }
    final ratings = <String, int>{};
    for (final e in _ratingInputs.entries) {
      final v = int.tryParse(e.value.trim());
      if (v != null) ratings[e.key] = v;
    }
    final randomSeed = int.tryParse(_randomSeedInput.trim());
    final slots = allocateTeams(
      teamIds: widget.teamIds,
      method: _method,
      seeds: seeds,
      teamCountries: countries,
      teamRatings: ratings,
      randomSeed: randomSeed,
    );
    setState(() => _slots = slots);
    _saveSlots();
  }

  Future<void> _overrideSlot(AllocatedSlot slot) async {
    var picked = slot.slot;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: kCardPurpleMid,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
          title: Text(
            tr('Move ${slot.teamId} to slot', '${slot.teamId} ko slot mein bhejen'),
            style: TextStyle(color: kText, fontSize: 16),
          ),
          content: DropdownButton<int>(
            value: picked,
            dropdownColor: kCard,
            style: TextStyle(color: kText),
            isExpanded: true,
            items: [
              for (var i = 1; i <= _slots.length; i++)
                DropdownMenuItem(value: i, child: Text('Slot $i')),
            ],
            onChanged: (v) {
              if (v != null) setDialogState(() => picked = v);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(tr('Cancel', 'Cancel'),
                  style: TextStyle(color: kMuted)),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(tr('Move', 'Move karein'),
                  style: TextStyle(color: kGold)),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _slots = applyManualOverride(_slots, slot.teamId, picked);
    });
    await _saveSlots();
  }

  Widget _inputRow(String teamId) {
    final label = switch (_method) {
      TeamAllocationMode.seeded => tr('Seed', 'Seed'),
      TeamAllocationMode.countryBased => tr('Country code', 'Mulk code'),
      TeamAllocationMode.performanceBased => tr('Rating', 'Rating'),
      _ => '',
    };
    if (label.isEmpty) return const SizedBox.shrink();
    final map = switch (_method) {
      TeamAllocationMode.seeded => _seedInputs,
      TeamAllocationMode.countryBased => _countryInputs,
      TeamAllocationMode.performanceBased => _ratingInputs,
      _ => <String, String>{},
    };
    return TextField(
      key: ValueKey('${_method.name}:$teamId'),
      onChanged: (v) => map[teamId] = v,
      keyboardType: _method == TeamAllocationMode.countryBased
          ? TextInputType.text
          : TextInputType.number,
      style: TextStyle(color: kText, fontSize: 13),
      decoration: InputDecoration(
        labelText: '$teamId — $label',
        labelStyle: TextStyle(color: kMuted, fontSize: 13),
        isDense: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isAdmin) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
          iconTheme: IconThemeData(color: kGold),
          title: Text(tr('Team allocation', 'Team allocation'),
              style: TextStyle(color: kText)),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: MockupCard(
            child: Text(
              tr('Only organizers can allocate teams to matches.',
                  'Sirf organizer teams ko matches mein allocate kar sakta hai.'),
              style: TextStyle(color: kText, fontSize: 14),
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        iconTheme: IconThemeData(color: kGold),
        title: Text(tr('Team allocation', 'Team allocation'),
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
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        DropdownButton<TeamAllocationMode>(
                          value: _method,
                          dropdownColor: kCard,
                          style: TextStyle(color: kText),
                          isExpanded: true,
                          items: [
                            for (final m in TeamAllocationMode.values)
                              DropdownMenuItem(value: m, child: Text(m.label)),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => _method = v);
                          },
                        ),
                        const SizedBox(height: 12),
                        if (_method == TeamAllocationMode.random)
                          TextField(
                            onChanged: (v) => _randomSeedInput = v,
                            keyboardType: TextInputType.number,
                            style: TextStyle(color: kText, fontSize: 13),
                            decoration: InputDecoration(
                              labelText: tr(
                                  'Random seed (optional — same seed = same result)',
                                  'Random seed (optional — ek seed = ek hi result)'),
                              labelStyle:
                                  TextStyle(color: kMuted, fontSize: 13),
                              isDense: true,
                            ),
                          ),
                        if (_method == TeamAllocationMode.seeded ||
                            _method == TeamAllocationMode.countryBased ||
                            _method == TeamAllocationMode.performanceBased)
                          for (final teamId in widget.teamIds)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: _inputRow(teamId),
                            ),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: kGold,
                            foregroundColor: Colors.black,
                          ),
                          onPressed:
                              widget.teamIds.isEmpty ? null : _generate,
                          child: Text(tr('Generate allocation',
                              'Allocation banayen')),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_slots.isEmpty)
                    Text(
                      tr('No allocation yet. Pick a method and generate.',
                          'Abhi koi allocation nahi hai. Method chunen aur generate karen.'),
                      style: TextStyle(color: kMuted, fontSize: 13),
                    )
                  else
                    MockupCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr('Tap a team to move it to another slot.',
                                'Team ko doosre slot mein bhejne ke liye us par tap karen.'),
                            style: TextStyle(color: kMuted, fontSize: 13),
                          ),
                          const SizedBox(height: 12),
                          for (final slot in _slots)
                            InkWell(
                              onTap: () => _overrideSlot(slot),
                              child: Padding(
                                padding:
                                    const EdgeInsets.only(bottom: 10),
                                child: Row(
                                  children: [
                                    Text('Slot ${slot.slot}',
                                        style: TextStyle(
                                            color: kGold,
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold)),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(slot.teamId,
                                          style: TextStyle(
                                              color: kText,
                                              fontSize: 14)),
                                    ),
                                    if (slot.seed != null)
                                      Text('Seed ${slot.seed}',
                                          style: TextStyle(
                                              color: kMuted,
                                              fontSize: 12)),
                                  ],
                                ),
                              ),
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
