import 'package:flutter/material.dart';
import 'package:protournament_user/platform/core/tournament_enums.dart';
import 'package:protournament_user/utils.dart';

/// Entry-model picker + payment-status badge (ChatGPT blueprint §3-D
/// / §4; backend guide §3-D `entry_model`, §4 `payment_events.status`).
///
/// The picker NEVER blocks a selection — selecting Approved Paid
/// without approval only shows the gate note; the BUILDER enforces
/// the publish block (guide §3-D: `approved_paid` only with a
/// legal/payment approval flag on).
class EntryModelPicker extends StatelessWidget {
  final EntryModel value;
  final ValueChanged<EntryModel> onChanged;

  /// True when Super Admin + legal/payment approval for paid entry
  /// is on record (`tournaments.paid_approved_at` set). When false
  /// and Approved Paid is selected, the gate note shows.
  final bool paidApprovalSet;

  const EntryModelPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.paidApprovalSet = false,
  });

  String _description(EntryModel model) => switch (model) {
        EntryModel.free => tr(
            'Recommended launch model — no entry fee, prizes from the organizer.',
            'Recommended launch model — koi entry fee nahi, inaam organizer se.'),
        EntryModel.sponsored => tr(
            'A sponsor funds the prizes — players enter free.',
            'Sponsor inaam deta hai — players free mein enter hote hain.'),
        EntryModel.organizerFunded => tr(
            'The organizer covers the prizes from their own budget.',
            'Organizer apne budget se inaam deta hai.'),
        EntryModel.approvedPaid => tr(
            'Players pay an entry fee. Only with Super Admin + legal/payment approval.',
            'Players entry fee dete hain. Sirf Super Admin + legal/payment approval ke saath.'),
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final model in EntryModel.values) ...[
          MockupCard(
            animate: false,
            sparks: false,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: InkWell(
              onTap: () => onChanged(model),
              borderRadius: BorderRadius.circular(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Custom radio dot (the Radio widget's groupValue /
                  // onChanged are deprecated in this SDK) — the whole
                  // row is tappable via the InkWell above.
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 4),
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: model == value ? kGold : kMuted,
                          width: 2,
                        ),
                      ),
                      child: model == value
                          ? Center(
                              child: Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: kGold,
                                ),
                              ),
                            )
                          : null,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                model.label,
                                style: TextStyle(
                                  color: kText,
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            if (model == EntryModel.free) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: kGold,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  tr('Recommended', 'Recommended'),
                                  style: const TextStyle(
                                    color: Colors.black,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _description(model),
                          style: TextStyle(color: kMuted, fontSize: 13),
                        ),
                        if (model == EntryModel.approvedPaid &&
                            value == EntryModel.approvedPaid &&
                            !paidApprovalSet) ...[
                          const SizedBox(height: 8),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.warning_amber_rounded,
                                  color: kGold, size: 16),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  tr(
                                    'Paid entry needs Super Admin approval — the tournament cannot publish until approval is on record.',
                                    'Paid entry ke liye Super Admin ki approval chahiye — approval ke baghair tournament publish nahi ho sakta.',
                                  ),
                                  style: TextStyle(
                                      color: kGold,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

/// Colored status badge for a payment (guide §4
/// `payment_events.status`).
class PaymentStatusBadge extends StatelessWidget {
  final PaymentStatus status;

  const PaymentStatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final Color? border;
    switch (status) {
      case PaymentStatus.confirmed:
        bg = kGreen;
        fg = Colors.black;
        border = null;
      case PaymentStatus.pending:
        bg = kGold;
        fg = Colors.black;
        border = null;
      case PaymentStatus.failed:
        bg = kRed;
        fg = Colors.white;
        border = null;
      case PaymentStatus.refunded:
        bg = Colors.transparent;
        fg = kMuted;
        border = kMuted;
      case PaymentStatus.underReview:
        bg = Colors.transparent;
        fg = kGold;
        border = kGold;
      case PaymentStatus.notRequired:
        bg = kMuted.withValues(alpha: 0.25);
        fg = kMuted;
        border = null;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: border == null ? null : Border.all(color: border),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          color: fg,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
