import 'package:protournament_user/utils.dart';

/// Pure payment rules + copy (ChatGPT blueprint §4; backend guide
/// §4 + §1.6). No UI, no I/O — safe to unit-test.

/// IRON RULE (guide §4): a screenshot is never payment
/// confirmation. Canonical English text; the UI copy is
/// [screenshotNotProofText] (tr()'d). Kept as a `const` so the exact
/// wording is pinned and testable.
const String kScreenshotNotProof =
    'A screenshot is never payment confirmation — confirmation comes only from the authorized payment provider.';

/// User-facing copy of the iron rule, via tr().
String get screenshotNotProofText => tr(
      kScreenshotNotProof,
      'Screenshot kabhi payment ki confirmation nahi hota — confirmation sirf authorized payment provider se aati hai.');

/// The iron rule as code: a payment may be marked `confirmed` ONLY
/// when the authorized provider confirmed it. A user screenshot,
/// a manual claim, or an admin's say-so is never enough.
bool canMarkConfirmed({required bool providerConfirmed}) =>
    providerConfirmed;

/// Commercial finance (paid entry for organizers, subscriptions
/// billing, ads payouts) stays OFF until legal approval (guide
/// §1.6). This is a CONSTANT false — deliberately NOT a toggle:
/// no screen, setting, or flag may switch it on from the app.
/// It changes only when Sameer gets legal approval and a workstream
/// edits this line with the approval recorded.
const bool commercialFinanceEnabled = false;
