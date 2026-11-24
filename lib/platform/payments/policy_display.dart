import 'package:flutter/material.dart';
import 'package:protournament_user/utils.dart';

/// Refund / cancellation / postponement policy display (ChatGPT
/// blueprint §4; backend guide §4: `tournaments.refund_policy`,
/// `cancellation_policy`, `postponement_policy` — all three must be
/// non-empty before a paid tournament can publish).
///
/// Placed on the tournament detail / join flow by the coordinator so
/// players see the policies BEFORE registering.

/// The no-show rule (DECISIONS-2026-11-20.md §2): shown in the
/// cancellation policy display when the tournament has an entry fee.
String get kNoShowRule => tr(
      'No-show: 10-minute grace, then entry fee is forfeited — no refund.',
      'No-show: 10 minute ki mohlat, phir entry fee wapas nahi milegi — koi refund nahi.');

/// True only when all three policies are non-empty (after trimming).
/// Used by the publish validation for paid tournaments.
bool policiesComplete({
  required String refund,
  required String cancellation,
  required String postponement,
}) =>
    refund.trim().isNotEmpty &&
    cancellation.trim().isNotEmpty &&
    postponement.trim().isNotEmpty;

/// Labels of the policies that are empty (after trimming). Empty list
/// means all three are present.
List<String> missingPolicies({
  required String refund,
  required String cancellation,
  required String postponement,
}) {
  final missing = <String>[];
  if (refund.trim().isEmpty) {
    missing.add(tr('Refund policy', 'Refund policy'));
  }
  if (cancellation.trim().isEmpty) {
    missing.add(tr('Cancellation policy', 'Cancellation policy'));
  }
  if (postponement.trim().isEmpty) {
    missing.add(tr('Postponement policy', 'Postponement policy'));
  }
  return missing;
}

class RefundPolicyDisplay extends StatelessWidget {
  final String refundPolicy;
  final String cancellationPolicy;
  final String postponementPolicy;

  /// When true, the no-show rule line is shown under the
  /// cancellation policy (it only applies to paid entry).
  final bool hasEntryFee;

  const RefundPolicyDisplay({
    super.key,
    required this.refundPolicy,
    required this.cancellationPolicy,
    required this.postponementPolicy,
    this.hasEntryFee = false,
  });

  Widget _policyCard(String heading, String body, {String? extraLine}) {
    return MockupCard(
      animate: false,
      sparks: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            heading,
            style: TextStyle(
              color: kGold,
              fontSize: 13,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body.isEmpty
                ? tr('Not set yet.', 'Abhi set nahi hui.')
                : body,
            style: TextStyle(
              color: body.isEmpty ? kMuted : kText,
              fontSize: 14,
            ),
          ),
          if (extraLine != null) ...[
            const SizedBox(height: 8),
            Text(
              extraLine,
              style: TextStyle(
                color: kGold,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _policyCard(
          tr('Refund policy', 'Refund policy'),
          refundPolicy,
        ),
        const SizedBox(height: 10),
        _policyCard(
          tr('Cancellation policy', 'Cancellation policy'),
          cancellationPolicy,
          extraLine: hasEntryFee ? kNoShowRule : null,
        ),
        const SizedBox(height: 10),
        _policyCard(
          tr('Postponement policy', 'Postponement policy'),
          postponementPolicy,
        ),
      ],
    );
  }
}
