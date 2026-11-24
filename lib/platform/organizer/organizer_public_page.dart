import 'package:flutter/material.dart';
import 'package:protournament_user/platform/core/organization.dart';
import 'package:protournament_user/platform/core/regions.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/utils.dart';

/// Public organizer page (ChatGPT blueprint §7 — organizer
/// marketplace; backend guide §7: served from `organizations` —
/// name / logo / description / public stats, no extra table).
///
/// Shows logo, name, description, country, tier badge and public
/// stats. Stats come from the EXISTING [SupaDb.getTournaments] read
/// filtered to `created_by == ownerUid` (tournaments carry NO
/// `organization_id` yet — guide §4 adds it) and
/// [SupaDb.getRegistrations] per tournament for the player count.
/// Both are best-effort: a failed read shows "—", never a guess.
/// The guide's `organizations.public_stats` jsonb (refreshed by
/// `rebuild_leaderboard`) replaces this client-side counting once
/// the backend lands.
class OrganizerPublicPage extends StatefulWidget {
  const OrganizerPublicPage({super.key, required this.organization});
  final Organization organization;

  @override
  State<OrganizerPublicPage> createState() => _OrganizerPublicPageState();
}

class _OrganizerPublicPageState extends State<OrganizerPublicPage> {
  int? _tournamentsRun;
  int? _players;
  bool _loadingStats = true;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    try {
      final all = await SupaDb.getTournaments();
      final mine = all
          .where((t) =>
              SupaDb.strOf(t['created_by']) ==
              widget.organization.ownerUid)
          .toList();
      var players = 0;
      for (final t in mine) {
        final tid = SupaDb.strOf(t['id']);
        if (tid.isEmpty) continue;
        players += (await SupaDb.getRegistrations(tid)).length;
      }
      if (!mounted) return;
      setState(() {
        _tournamentsRun = mine.length;
        _players = players;
        _loadingStats = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingStats = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final org = widget.organization;
    final country = RegionService.countryFor(org.countryCode);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        iconTheme: IconThemeData(color: kGold),
        title: Text(tr('Organizer', 'Organizer'),
            style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          MockupCard(
            child: Column(
              children: [
                CircleAvatar(
                  radius: 44,
                  backgroundColor: kGold.withValues(alpha: 0.15),
                  backgroundImage: org.logoUrl.isNotEmpty
                      ? NetworkImage(org.logoUrl)
                      : null,
                  child: org.logoUrl.isEmpty
                      ? Icon(Icons.business, color: kGold, size: 44)
                      : null,
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(org.name,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: kText,
                              fontSize: 22,
                              fontWeight: FontWeight.bold)),
                    ),
                    if (org.verified) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.verified, color: kGold, size: 22),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    _badge(org.tier.label, kGold),
                    _badge(org.status.label,
                        org.status == OrganizationStatus.active
                            ? const Color(0xFF00F5A0)
                            : org.status == OrganizationStatus.suspended
                                ? const Color(0xFFFF3B30)
                                : kMuted),
                    _badge(country.name, kMuted),
                  ],
                ),
                if (org.description.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(org.description,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: kMuted, fontSize: 14)),
                ],
                if (org.createdAt != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${tr('Organizing since', 'Kab se organize kar rahe hain')}: '
                    '${org.createdAt!.toLocal().day}/${org.createdAt!.toLocal().month}/${org.createdAt!.toLocal().year}',
                    style: TextStyle(color: kMuted, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: MockupCard(
                  animate: false,
                  child: Column(
                    children: [
                      if (_loadingStats)
                        SizedBox(
                            height: 24,
                            width: 24,
                            child: CircularProgressIndicator(
                                color: kGold, strokeWidth: 2))
                      else
                        Text(
                            _tournamentsRun == null
                                ? '—'
                                : '$_tournamentsRun',
                            style: TextStyle(
                                color: kText,
                                fontSize: 24,
                                fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(tr('Tournaments run', 'Tournaments karwaye'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: kMuted, fontSize: 12)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: MockupCard(
                  animate: false,
                  child: Column(
                    children: [
                      if (_loadingStats)
                        SizedBox(
                            height: 24,
                            width: 24,
                            child: CircularProgressIndicator(
                                color: kGold, strokeWidth: 2))
                      else
                        Text(_players == null ? '—' : '$_players',
                            style: TextStyle(
                                color: kText,
                                fontSize: 24,
                                fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(tr('Players hosted', 'Players'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: kMuted, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(label,
          style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold)),
    );
  }
}
