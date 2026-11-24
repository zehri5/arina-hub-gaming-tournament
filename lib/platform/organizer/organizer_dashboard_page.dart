import 'package:flutter/material.dart';
import 'package:protournament_user/platform/builder/smart_builder_page.dart';
import 'package:protournament_user/platform/competition/allocation_page.dart';
import 'package:protournament_user/platform/competition/checkin_page.dart';
import 'package:protournament_user/platform/competition/checkin_service.dart';
import 'package:protournament_user/platform/competition/room_release_page.dart';
import 'package:protournament_user/platform/core/lifecycle.dart';
import 'package:protournament_user/platform/core/organization.dart';
import 'package:protournament_user/platform/core/roles.dart';
import 'package:protournament_user/platform/organizer/organizer_public_page.dart';
import 'package:protournament_user/platform/organizer/organizer_service.dart';
import 'package:protournament_user/platform/organizer/staff_management_page.dart';
import 'package:protournament_user/platform/organizer/tiers_page.dart';
import 'package:protournament_user/platform/scoring/leaderboard_page.dart';
import 'package:protournament_user/services/squad.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/utils.dart';

/// Organizer home (ChatGPT blueprint §7 — organizer dashboard).
///
/// Shows the organization's tier card, my-tournaments summary,
/// participants count, results-to-verify count and staff count, plus
/// quick links (tournament builder, staff, branding, public page).
///
/// DATA SOURCES (honest): the organization + staff come from
/// [OrganizerService] (local store until `organizations` /
/// `organization_members` land). Tournaments come from the EXISTING
/// [SupaDb.getTournaments] read, filtered to `created_by == ownerUid`
/// — tournaments carry NO `organization_id` yet (guide §4 adds it),
/// so the owner-UID match is the interim filter. Participants come
/// from the existing [SupaDb.getRegistrations] per tournament.
/// Results-to-verify come from the existing `tournament_results`
/// table via [SupaDb.getList] (statuses `pending` / `submitted` /
/// `re-submitted`, same set the admin Results page treats as
/// "awaiting review"). Every count is best-effort: a failed read
/// shows "—", never a guessed number.
///
/// NOT wired into main.dart navigation — the coordinator wires the
/// entry point.
class OrganizerDashboardPage extends StatefulWidget {
  const OrganizerDashboardPage({super.key, required this.organizationId});
  final String organizationId;

  @override
  State<OrganizerDashboardPage> createState() => _OrganizerDashboardPageState();
}

class _OrganizerDashboardPageState extends State<OrganizerDashboardPage> {
  final _service = const OrganizerService();

  bool _loading = true;
  Organization? _org;
  List<Map<String, dynamic>> _myTournaments = [];
  int? _participants;
  int? _resultsToVerify;
  int _staffCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final org = await _service.getOrganization(widget.organizationId);
    if (org == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    var tournaments = <Map<String, dynamic>>[];
    try {
      final all = await SupaDb.getTournaments();
      tournaments = all
          .where((t) =>
              SupaDb.strOf(t['created_by']) == org.ownerUid)
          .toList();
    } catch (_) {
      tournaments = [];
    }
    int? participants;
    int? toVerify;
    try {
      var p = 0;
      var v = 0;
      for (final t in tournaments) {
        final tid = SupaDb.strOf(t['id']);
        if (tid.isEmpty) continue;
        final regs = await SupaDb.getRegistrations(tid);
        p += regs.length;
        final results = await SupaDb.getList(
          'tournament_results',
          eqCol: 'tournament_id',
          eqVal: tid,
        );
        v += results.where((r) {
          final s = SupaDb.strOf(r['status']).toLowerCase();
          return s == 'pending' || s == 'submitted' || s == 're-submitted';
        }).length;
      }
      participants = p;
      toVerify = v;
    } catch (_) {
      participants = null;
      toVerify = null;
    }
    final staff = await _service.listStaff(org.id);
    if (!mounted) return;
    setState(() {
      _org = org;
      _myTournaments = tournaments;
      _participants = participants;
      _resultsToVerify = toVerify;
      _staffCount = staff.length;
      _loading = false;
    });
  }

  Future<void> _editBranding() async {
    final org = _org;
    if (org == null) return;
    final logoCtrl = TextEditingController(text: org.logoUrl);
    final descCtrl = TextEditingController(text: org.description);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text(tr('Edit branding', 'Branding badlein'),
            style: TextStyle(color: kText)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: logoCtrl,
              style: TextStyle(color: kText),
              decoration: InputDecoration(
                labelText: tr('Logo image link', 'Logo tasveer ka link'),
                labelStyle: TextStyle(color: kMuted),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descCtrl,
              maxLines: 3,
              style: TextStyle(color: kText),
              decoration: InputDecoration(
                labelText: tr('Description', 'Tafseel'),
                labelStyle: TextStyle(color: kMuted),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Cancel', 'Cancel'), style: TextStyle(color: kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Save', 'Save'),
                style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    logoCtrl.dispose();
    descCtrl.dispose();
    if (saved != true || !mounted) return;
    final ok = await _service.updateBranding(
        org.id, logoCtrl.text, descCtrl.text);
    if (!mounted) return;
    toast(context,
        ok
            ? tr('Branding updated.', 'Branding update ho gayi.')
            : tr('Could not save branding.', 'Branding save nahi ho saki.'));
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    final org = _org;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        iconTheme: IconThemeData(color: kGold),
        title: Text(tr('Organizer Dashboard', 'Organizer Dashboard'),
            style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: kGold))
          : org == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      tr('Organization not found on this device.',
                          'Organization is device par nahi mili.'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: kMuted),
                    ),
                  ),
                )
              : RefreshIndicator(
                  color: kGold,
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // Tier card.
                      MockupCard(
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 26,
                              backgroundColor:
                                  kGold.withValues(alpha: 0.15),
                              backgroundImage: org.logoUrl.isNotEmpty
                                  ? NetworkImage(org.logoUrl)
                                  : null,
                              child: org.logoUrl.isEmpty
                                  ? Icon(Icons.business,
                                      color: kGold, size: 28)
                                  : null,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(org.name,
                                      style: TextStyle(
                                          color: kText,
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${org.tier.label} · ${org.status.label}',
                                    style: TextStyle(
                                        color: kGold, fontSize: 13),
                                  ),
                                  if (org.description.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(org.description,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            color: kMuted, fontSize: 12)),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Stat cards.
                      GridView.count(
                        crossAxisCount: 2,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        childAspectRatio: 1.6,
                        children: [
                          _statCard(
                              Icons.emoji_events,
                              tr('My tournaments', 'Mere tournaments'),
                              '${_myTournaments.length}'),
                          _statCard(
                              Icons.people,
                              tr('Participants', 'Participants'),
                              _participants == null
                                  ? '—'
                                  : '$_participants'),
                          _statCard(
                              Icons.fact_check,
                              tr('Results to verify', 'Verify karne wale results'),
                              _resultsToVerify == null
                                  ? '—'
                                  : '$_resultsToVerify'),
                          _statCard(Icons.group, tr('Staff', 'Staff'),
                              '$_staffCount'),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(tr('Quick links', 'Quick links'),
                          style: TextStyle(
                              color: kText,
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      _linkTile(
                        Icons.add_circle,
                        tr('Create tournament', 'Tournament banayen'),
                        tr('Open the tournament builder', 'Tournament builder kholen'),
                        () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => SmartBuilderPage(
                                  organizationId: org.id)),
                        ),
                      ),
                      _linkTile(
                        Icons.group,
                        tr('Staff & referees', 'Staff aur referees'),
                        tr('Invite and manage your team', 'Apni team ko invite aur manage karen'),
                        () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => StaffManagementPage(
                                    organizationId: org.id)),
                          );
                          _load();
                        },
                      ),
                      _linkTile(
                        Icons.brush,
                        tr('Branding', 'Branding'),
                        tr('Logo and description', 'Logo aur tafseel'),
                        _editBranding,
                      ),
                      _linkTile(
                        Icons.public,
                        tr('Public page', 'Public page'),
                        tr('How players see your organization', 'Players ko aap ki organization kaisi dikhti hai'),
                        () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  OrganizerPublicPage(organization: org)),
                        ),
                      ),
                      _linkTile(
                        Icons.layers,
                        tr('Tiers', 'Tiers'),
                        tr('Starter / Professional / Enterprise', 'Starter / Professional / Enterprise'),
                        () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const OrganizerTiersPage()),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // My tournaments list.
                      Text(tr('My tournaments', 'Mere tournaments'),
                          style: TextStyle(
                              color: kText,
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      if (_myTournaments.isEmpty)
                        MockupCard(
                          animate: false,
                          child: Text(
                            tr('No tournaments yet. Create your first one from the builder above.',
                                'Abhi koi tournament nahi. Upar wale builder se pehla banayen.'),
                            style: TextStyle(color: kMuted, fontSize: 13),
                          ),
                        )
                      else
                        for (final t in _myTournaments)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: MockupCard(
                              animate: false,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(SupaDb.strOf(t['name'], 'Tournament'),
                                                style: TextStyle(
                                                    color: kText,
                                                    fontWeight: FontWeight.w600)),
                                            const SizedBox(height: 2),
                                            Text(
                                              '${SupaDb.strOf(t['mode'])} · ${SupaDb.strOf(t['status'])}',
                                              style: TextStyle(
                                                  color: kMuted, fontSize: 12),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Text(
                                        '${SupaDb.intOf(t['maxPlayers'])} ${tr('slots', 'slots')}',
                                        style: TextStyle(
                                            color: kMuted, fontSize: 12),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  // Tournament ops (integration
                                  // 2026-11-21): check-in, room
                                  // release, team allocation, results.
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      _opButton(
                                          tr('Check-in', 'Check-in'),
                                          () => Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (_) => CheckInPage(
                                                    tournamentId:
                                                        SupaDb.strOf(t['id']),
                                                    teamId: '',
                                                    captainUid: '',
                                                    viewerRole:
                                                        AppRole.organizer,
                                                  ),
                                                ),
                                              )),
                                      _opButton(tr('Room', 'Room'),
                                          () => _openRoomRelease(SupaDb.strOf(t['id']))),
                                      _opButton(tr('Teams', 'Teams'),
                                          () => _openAllocation(SupaDb.strOf(t['id']))),
                                      _opButton(
                                          tr('Results', 'Results'),
                                          () => Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (_) =>
                                                      ScopedLeaderboardPage(
                                                    tournamentId:
                                                        SupaDb.strOf(t['id']),
                                                  ),
                                                ),
                                              )),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                    ],
                  ),
                ),
    );
  }

  /// Small gold-outline action pill for the per-tournament ops row.
  Widget _opButton(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: kGold),
          borderRadius: BorderRadius.circular(20),
          color: kGold.withValues(alpha: 0.08),
        ),
        child: Text(label,
            style: TextStyle(
                color: kGold, fontSize: 12, fontWeight: FontWeight.bold)),
      ),
    );
  }

  /// Room release (integration 2026-11-21): checked-in teams come
  /// from the check-in service; only they ever receive the room.
  Future<void> _openRoomRelease(String tournamentId) async {
    final entries = await CheckInService().getEntries(tournamentId);
    final checkedIn = entries
        .where((e) =>
            e.status == CheckInStatus.checkedIn ||
            e.status == CheckInStatus.late)
        .map((e) => e.teamId)
        .toList();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RoomReleasePage(
          matchId: tournamentId,
          checkedInTeamIds: checkedIn,
          viewerRole: AppRole.organizer,
        ),
      ),
    );
  }

  /// Team allocation (integration 2026-11-21): team ids are the
  /// registration squad ids for this tournament.
  Future<void> _openAllocation(String tournamentId) async {
    final regs = await SupaDb.getRegistrations(tournamentId);
    final teamIds = regs
        .map((r) => squadIdFor(tournamentId, SupaDb.strOf(r['team_name'])))
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AllocationPage(
          matchId: tournamentId,
          teamIds: teamIds,
          viewerRole: AppRole.organizer,
        ),
      ),
    );
  }

  Widget _statCard(IconData icon, String label, String value) {
    return MockupCard(
      animate: false,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: kGold, size: 22),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  color: kText, fontSize: 22, fontWeight: FontWeight.bold)),
          Text(label, style: TextStyle(color: kMuted, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _linkTile(
      IconData icon, String title, String subtitle, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MockupCard(
        animate: false,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon, color: kGold),
          title: Text(title, style: TextStyle(color: kText, fontSize: 15)),
          subtitle:
              Text(subtitle, style: TextStyle(color: kMuted, fontSize: 12)),
          trailing: Icon(Icons.chevron_right, color: kMuted),
          onTap: onTap,
        ),
      ),
    );
  }
}
