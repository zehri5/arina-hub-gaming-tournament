import 'package:flutter/material.dart';
import 'package:protournament_user/platform/core/lifecycle.dart';
import 'package:protournament_user/theme.dart';

/// Notification-list additions for the 10 lifecycle events
/// (blueprint §5-6; backend guide §5-6). Material icons only —
/// no emoji as UI icons.

/// Icon per lifecycle event kind.
IconData iconForEvent(NotificationEvent event) => switch (event) {
      NotificationEvent.registrationConfirmed => Icons.check_circle,
      NotificationEvent.registrationClosing => Icons.timer,
      NotificationEvent.checkInOpened => Icons.how_to_reg,
      NotificationEvent.checkInMissed => Icons.event_busy,
      NotificationEvent.matchReminder => Icons.sports_esports,
      NotificationEvent.roomPublished => Icons.meeting_room,
      NotificationEvent.resultSubmitted => Icons.assignment_turned_in,
      NotificationEvent.disputeResolved => Icons.gavel,
      NotificationEvent.leaderboardPublished => Icons.leaderboard,
      NotificationEvent.tournamentCompleted => Icons.emoji_events,
    };

/// Small labeled chip for one lifecycle event kind, for use in
/// notification lists. The label is the event's notification title
/// (via [notificationContent]), so chip and notification copy can
/// never drift apart.
class LifecycleEventChip extends StatelessWidget {
  final NotificationEvent event;

  const LifecycleEventChip({super.key, required this.event});

  @override
  Widget build(BuildContext context) {
    final label = notificationContent(event, const {}).title;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: kGold.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kGold.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(iconForEvent(event), size: 14, color: kGold),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                color: kGold,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
