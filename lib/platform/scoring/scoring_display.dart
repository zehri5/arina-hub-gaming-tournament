import 'package:flutter/material.dart';
import 'package:protournament_user/platform/core/scoring.dart';
import 'package:protournament_user/utils.dart';

/// Scoring display widgets (ChatGPT blueprint §5-5 / §6; backend
/// guide §6 transparency rules).
///
/// Pure display only — the points math lives in the platform
/// contract ([calculateMatchPoints], platform/core/scoring.dart)
/// and the server RPC `calculate_match_score` is the authority.
/// These widgets never invent points; they render the breakdown of
/// a placement + kills pair under a given [ScoringTemplate].

/// Placement + kill breakdown for one match result, with the
/// template name that produced it.
///
/// Shows three rows (placement points, kill points, total) so a
/// player can see exactly how their points were calculated —
/// blueprint §6 transparency. Placement <= 0 renders as "no
/// result" (0 points); placements outside the template table
/// (9th+) earn 0 placement points but still earn kill points.
class PointsBreakdown extends StatelessWidget {
  final int placement;
  final int kills;
  final ScoringTemplate? template;

  const PointsBreakdown({
    super.key,
    required this.placement,
    required this.kills,
    this.template,
  });

  @override
  Widget build(BuildContext context) {
    final t = template ?? kDefaultScoringTemplate;
    final safeKills = kills < 0 ? 0 : kills;
    final placementPoints =
        placement > 0 ? (t.placementPoints[placement] ?? 0) : 0;
    final killPoints = placement > 0 ? safeKills * t.killPoints : 0;
    final total = calculateMatchPoints(
        placement: placement, kills: kills, template: t);
    return MockupCard(
      animate: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tr('Points breakdown', 'Points ki tafseel'),
                  style: TextStyle(
                      color: kText,
                      fontWeight: FontWeight.bold,
                      fontSize: 15),
                ),
              ),
              TemplateBadge(template: t),
            ],
          ),
          const SizedBox(height: 12),
          _row(
            tr('Placement', 'Placement'),
            placement > 0 ? '#$placement' : '—',
            tr('$placementPoints pts', '$placementPoints points'),
          ),
          const SizedBox(height: 8),
          _row(
            tr('Kills', 'Kills'),
            '$safeKills × ${t.killPoints}',
            tr('$killPoints pts', '$killPoints points'),
          ),
          const Divider(height: 20),
          _row(
            tr('Total', 'Total'),
            '',
            tr('$total pts', '$total points'),
            bold: true,
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String detail, String points,
      {bool bold = false}) {
    final style = TextStyle(
      color: bold ? kGold : kText,
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      fontSize: 14,
    );
    return Row(
      children: [
        Expanded(
          child: Text(label, style: style),
        ),
        if (detail.isNotEmpty)
          Text(detail, style: TextStyle(color: kMuted, fontSize: 13)),
        const SizedBox(width: 12),
        Text(points, style: style),
      ],
    );
  }
}

/// Small pill naming the scoring template a ranking or breakdown
/// was calculated with (blueprint §6: the calculation method must
/// always be visible).
class TemplateBadge extends StatelessWidget {
  final ScoringTemplate template;

  const TemplateBadge({super.key, required this.template});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: kGold.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: kGold.withValues(alpha: 0.5)),
      ),
      child: Text(
        template.name,
        style: TextStyle(
            color: kGold, fontSize: 12, fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// Verified (green) / Provisional (gold) status pill.
///
/// A ranking is Verified only when it comes from a published
/// server snapshot (`leaderboard_snapshots`, guide §6); anything
/// computed locally from approved results is Provisional until
/// the backend publishes snapshots.
class ProvisionalBadge extends StatelessWidget {
  final bool verified;

  const ProvisionalBadge({super.key, required this.verified});

  @override
  Widget build(BuildContext context) {
    final color = verified ? kGreen : kGold;
    final label =
        verified ? tr('Verified', 'Verified') : tr('Provisional', 'Aarzi');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style:
            TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
      ),
    );
  }
}
