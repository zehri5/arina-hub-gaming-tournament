import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../components/arena_components.dart';
import '../components/cached_image.dart';
import '../widgets/arena_ui.dart'; // Phase 2 redesign shared components (S12 Edit Profile)
import '../components/arena_chat.dart';
import '../components/chat_bubble.dart'; // showChatImageDialog (chat photo tap-to-view)
import '../services/squad.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../services/sound_service.dart';
import '../services/message_sounds.dart';
import '../services/imgbb_service.dart';
import '../services/supabase_db.dart';
import '../community_service.dart';
import '../utils.dart';
import 'frames_widgets.dart';
import 'communities_screens.dart'; // FIX 11: the Community tab embeds the public-communities list (CreateCommunityPage / CommunityDetailPage) on TeamsPage (Dart allows this import cycle with communities_screens.dart via community_screens.dart; all three files only define classes — same precedent as more_screens.dart below).
import 'more_screens.dart'; // #16 dedup: MatchSummaryPage redirects to MatchResultDetailsPage (Dart allows this import cycle with more_screens.dart; both files only define classes).
import 'room_screen.dart';
import '../widgets/voice_settings_sheet.dart'; // FIX 16: header Settings sheet + its panel bridge

/// PRO FEATURES — FULL COMPLETION round, expansions 1 + 2 + 3 (2026-10-27).
///
/// Everything here is FREE-only (Supabase free + Firebase Auth free +
/// OneSignal free + share/WhatsApp intents). No paid service, no paid
/// SMS, no paid streaming, no paid anti-cheat, no hardcoded keys.
///
/// HONESTY CONTRACT for the new tables (migration 008_pro_features.sql):
/// every screen that reads a new table catches a missing-table error
/// and shows a clear "backend pending — run migration 008" state
/// instead of crashing or faking data. Features computed from EXISTING
/// tables (match_history, profiles, transactions, registrations,
/// tournaments) work immediately, with or without migration 008.
/// Nothing here invents a result, a winner, a payment or a delivery.

bool proTableMissing(Object e) {
  final s = e.toString();
  return s.contains('PGRST205') || s.contains('42P01') || s.contains('does not exist') || s.contains('Could not find the table');
}

/// Phase 2 (Teams): network-failure detector for the error paths that
/// can actually throw (direct client writes — create/join/edit/lock).
/// NOTE: SupaDb.getList/getRow swallow read errors and return []/{},
/// so a *read* failure can never be distinguished from "empty" here —
/// the ErrorState/OfflineState below are driven by the reachable
/// write paths, and the _load catch is defensive only. Surfacing read
/// errors needs a data-layer change (out of Phase 2 scope).
bool _isOfflineError(Object e) {
  final s = e.toString().toLowerCase();
  return s.contains('socketexception') ||
      s.contains('failed host lookup') ||
      s.contains('network is unreachable') ||
      s.contains('connection refused') ||
      s.contains('connection timed out') ||
      s.contains('no internet') ||
      s.contains('network error');
}

String _uid() => FirebaseAuth.instance.currentUser?.uid ?? '';

/// Phase 3 (support #2/#4): shared evidence-image picker (OD-15).
/// JPG/PNG only, ≤5MB, checked client-side before any upload.
/// Pass [imageQuality]/[maxWidth] to compress at pick time —
/// profile photos MUST pass them (a full-res phone photo can never
/// finish uploading on a slow connection before the timeout).
/// Returns (file, error): file is null when the user cancels;
/// error carries the rejection reason for the caller to toast —
/// the helper itself never touches a BuildContext across an await.
/// CHANGE-PHOTO FIX (2026-11-20, Round 3 item 10): pickImage can
/// throw MissingPluginException (Dart-registrant disease) — an
/// uncaught throw here meant tap-animates-but-nothing-opens with NO
/// toast at all (the exact reported symptom). It now falls back to
/// file_picker (same pattern as the admin uploaders), and any other
/// failure returns a plain error string instead of throwing — this
/// helper NEVER throws, so no caller can silently die.
Future<({File? file, String? error})> _pickEvidenceImage({int? imageQuality, double? maxWidth}) async {
  try {
    String? path;
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: imageQuality, maxWidth: maxWidth);
      if (picked == null) return (file: null, error: null);
      path = picked.path;
    } on MissingPluginException {
      final res = await FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: false);
      if (res == null || res.files.isEmpty || res.files.single.path == null) {
        return (file: null, error: null);
      }
      path = res.files.single.path!;
    }
    final lower = path.toLowerCase();
    if (!lower.endsWith('.jpg') && !lower.endsWith('.jpeg') && !lower.endsWith('.png')) {
      return (file: null, error: 'Sirf JPG ya PNG photo allowed hai.');
    }
    final file = File(path);
    final size = await file.length();
    if (size > 5 * 1024 * 1024) {
      return (file: null, error: 'Photo 5MB se bari hai — chhoti photo chunen.');
    }
    return (file: file, error: null);
  } catch (_) {
    return (file: null, error: 'Photo nahi khul saki — dobara koshish karein.');
  }
}

/// Shared step tracker (Phase 3 #2 disputes, #20 tickets): [current]
/// is the 0-based index of the in-progress step; earlier steps are done
/// (gold fill + black check), the current step is a gold ring with a
/// gold dot, later steps are SOLID GREY DOTS (mockups #2 / #20 both
/// show solid grey pending circles, not hollow rings — the grey is
/// kMuted, the same token as the connector line). The connector line
/// spans the full gap between circles and stays grey — mockups #2 /
/// #20 both show a grey line between the circles, even after a gold
/// done-step.
/// [highlightCurrent] false renders the current step as a plain solid
/// grey dot (mockup #2: "Submitted" done, "Under Review" / "Resolved"
/// plain grey — nothing in progress is ringed).
/// J-detail-fix1: [doneLabelsGold] — mockup #2 labels the done step
/// gold bold ("Submitted"), mockup #20 labels done steps grey and
/// only the current step gold bold ("Responded"). [glowCurrent] —
/// mockup #20's current circle is larger (~36px incl. halo) with a
/// soft gold halo; #2's tracker has no glow.
class _StepTracker extends StatelessWidget {
  const _StepTracker({required this.steps, required this.current, this.highlightCurrent = true, this.doneLabelsGold = true, this.glowCurrent = false});
  final List<String> steps;
  final int current;
  final bool highlightCurrent;
  final bool doneLabelsGold;
  final bool glowCurrent;
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            for (var i = 0; i < steps.length; i++) ...[
              _stepCircle(i),
              if (i < steps.length - 1)
                // Mockups #2 / #20: the connector line is grey, even
                // after a gold done-step — never gold.
                Expanded(child: Container(height: 2, color: kMuted)),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (var i = 0; i < steps.length; i++)
              Expanded(
                child: Text(
                  steps[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: i < current
                        ? (doneLabelsGold ? kGold : kMuted)
                        : (i == current && highlightCurrent)
                            ? kGold
                            : kMuted,
                    fontSize: 11,
                    fontWeight: i == current || (i < current && doneLabelsGold) ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _stepCircle(int i) {
    final isCurrent = i == current && highlightCurrent;
    final isDone = i < current;
    // Mockups #2 / #20: pending steps are SOLID grey dots (kMuted
    // fill, same token as the connector line) — never hollow rings.
    final circle = Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: isDone ? kGold : isCurrent ? kCard : kMuted,
        shape: BoxShape.circle,
        border: Border.all(color: isDone ? kGold : isCurrent ? kGold : kMuted, width: 2),
      ),
      child: Center(
        child: isDone
            ? const Icon(Icons.check, size: 16, color: Colors.black)
            : isCurrent
                ? Container(width: 10, height: 10, decoration: const BoxDecoration(color: Color(0xFFFDC903), shape: BoxShape.circle))
                : const SizedBox(),
      ),
    );
    // Mockup #20: the current circle reads ~36px incl. a soft gold
    // halo around it.
    if (!glowCurrent || !isCurrent) return circle;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: kGold.withValues(alpha: 0.35), width: 1.5),
        boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.35), blurRadius: 12, spreadRadius: 1)],
      ),
      child: Center(child: circle),
    );
  }
}

/// ------- Wave B design-match helpers (2026-11-19) -------
///
/// Mockup-faithful chrome shared by the pro-feature screens below.
/// Colours come from the gold tokens (theme.dart); nothing here
/// invents data — every slot shows real data or an honest empty state.

/// Centered heavy title. Most mockups are upright bold (#2/#3/#4);
/// mockups #13 (HELP & SUPPORT) and #20 (TICKET DETAILS) show the
/// title ITALIC — pass [italic: true] only for those two. The
/// default (upright) is unchanged for every other caller.
Widget _mockAppBarTitle(String title, {bool italic = false}) => Text(
      title,
      style: TextStyle(color: Colors.white, fontStyle: italic ? FontStyle.italic : FontStyle.normal, fontWeight: FontWeight.w900, fontSize: 20, letterSpacing: 0.5),
    );

/// Uppercase bold section label, as on mockups #2/#4 (#2
/// "SELECT ISSUE TYPE", #4 "ISSUE CATEGORY", ...). Colour is the
/// muted olive-gold [kSectionLabel] (user correction 2026-11-20:
/// headings light golden, not pure white — same token + size as the
/// Account Security section labels in more_screens.dart).
Widget _mockSectionLabel(String label) => Text(
      label,
      style: const TextStyle(color: kSectionLabel, fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1),
    );

/// Section header with a gold left bar, as on mockups #3 ("INVITE
/// PLAYERS", "ROSTER"), #13 ("POPULAR FAQs"), #16 ("PERFORMANCE
/// SUMMARY", "MATCH TIMELINE"). [goldFirstWord] renders the first
/// word gold and the rest white (mockup #13 "POPULAR FAQs").
Widget _goldBarHeader(String label, {Widget? trailing, bool goldFirstWord = false}) => Row(
      children: [
        Container(width: 4, height: 22, decoration: BoxDecoration(color: kGold, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 8),
        Expanded(
          child: goldFirstWord && label.contains(' ')
              ? RichText(
                  text: TextSpan(
                    style: const TextStyle(color: Colors.white, fontStyle: FontStyle.italic, fontWeight: FontWeight.w900, fontSize: 18, letterSpacing: 0.5),
                    children: [
                      TextSpan(text: '${label.split(' ').first} ', style: TextStyle(color: kGold)),
                      TextSpan(text: label.split(' ').skip(1).join(' ')),
                    ],
                  ),
                )
              : Text(label, style: const TextStyle(color: Colors.white, fontStyle: FontStyle.italic, fontWeight: FontWeight.w900, fontSize: 18, letterSpacing: 0.5)),
        ),
        if (trailing != null) trailing,
      ],
    );

/// Small bold white field label above an input (mockups #4/#15).
Widget _mockLabel(String label) => Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13));

/// Mockup-styled text field: visible grey border, gold focus ring.
/// [suffix] renders inside the field's right edge (e.g. the
/// username-availability check on #15).
Widget _mockField({
  required TextEditingController controller,
  required String label,
  String? hint,
  int maxLines = 1,
  TextInputType? keyboardType,
  Widget? suffix,
  ValueChanged<String>? onChanged,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _mockLabel(label),
      const SizedBox(height: 6),
      // FIX 23 item 29: card look via CardFieldShell.
      CardFieldShell(
        child: TextField(
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboardType,
        onChanged: onChanged,
        style: TextStyle(color: kText),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: kMuted),
          suffixIcon: suffix,
          contentPadding: const EdgeInsets.symmetric(vertical: 13, horizontal: 14),
          border: const OutlineInputBorder(borderSide: BorderSide.none),
          enabledBorder: const OutlineInputBorder(borderSide: BorderSide.none),
          focusedBorder: const OutlineInputBorder(borderSide: BorderSide.none),
        ),
      ),
      ),
      const SizedBox(height: 12),
    ],
  );
}

/// Mockup-styled dropdown: gold border, gold chevron (mockup #4
/// category, #15 country / favourite game).
Widget _mockDropdown({
  required String label,
  required String? value,
  required List<String> options,
  required ValueChanged<String?> onChanged,
  String? hint,
}) {
  final safeValue = value != null && options.contains(value) ? value : null;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _mockLabel(label),
      const SizedBox(height: 6),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(12), border: Border.all(color: kGold, width: 1.5)),
        child: DropdownButton<String>(
          value: safeValue,
          isExpanded: true,
          hint: Text(hint ?? 'Select', style: TextStyle(color: kMuted)),
          dropdownColor: kCard,
          underline: const SizedBox(),
          icon: Icon(Icons.keyboard_arrow_down, color: kGold),
          style: TextStyle(color: kText),
          items: options.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
          onChanged: onChanged,
        ),
      ),
      const SizedBox(height: 12),
    ],
  );
}

/// Dashed gold border painter for the upload boxes (mockups #2/#4).
class _DashedBorderPainter extends CustomPainter {
  final Color color;
  const _DashedBorderPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      // Round caps (Fix 2 HD sweep, 2026-11-21): square-cut dash
      // ends looked jagged at small sizes. Dashes are intentional
      // here (mockup upload boxes) — only the ends are softened.
      ..strokeCap = StrokeCap.round;
    const dash = 8.0;
    const gap = 6.0;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)));
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        canvas.drawPath(metric.extractPath(dist, min(dist + dash, metric.length)), paint);
        dist += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Dashed upload box (mockups #2 "UPLOAD EVIDENCE", #4 "UPLOAD
/// SCREENSHOT OR ATTACHMENT").
Widget _dashedUploadBox({required VoidCallback onTap, required Widget child}) {
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: CustomPaint(
      painter: _DashedBorderPainter(kGold),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
        child: child,
      ),
    ),
  );
}

/// Full-width gold-outline button (mockups #2 "SUBMIT REPORT" style
/// secondary actions, #3 EDIT TEAM / TEAM HISTORY, #16 REPORT RESULT
/// ISSUE, #20 MARK AS RESOLVED). [goldText] makes the label gold
/// (mockup #20); default is white text (mockups #3/#16). [goldIcon]
/// makes only the icon gold while the label stays white (mockup #3:
/// gold pencil / clock icons, white labels).
/// FIX 5b (2026-11-21, My Team): the label is wrapped in
/// Flexible + FittedBox (scaleDown), so a long label in a narrow
/// half-width button shrinks instead of overflowing its border —
/// "TEAM HISTORY" used to run outside the button on the right.
/// [fontSize] / [horizontalPadding] let the cramped callers (the
/// My Team pair) go a little smaller; the defaults keep every other
/// caller pixel-identical, and FittedBox is a no-op when the label
/// already fits. [verticalPadding] (mockup #3, 2026-11-21): the
/// My Team pair is measured ~26dp tall on the mockup, so it passes
/// 5 — the default 14 keeps every other caller pixel-identical.
Widget _goldOutlineBtn({required String label, required VoidCallback? onPressed, IconData? icon, bool goldText = false, bool goldIcon = false, double fontSize = 15, double horizontalPadding = 20, double verticalPadding = 14}) {
  return SizedBox(
    width: double.infinity,
    child: OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: kGold, width: 1.5),
        backgroundColor: kCard,
        padding: EdgeInsets.symmetric(vertical: verticalPadding, horizontal: horizontalPadding),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[Icon(icon, color: goldText || goldIcon ? kGold : kText, size: 18), const SizedBox(width: 6)],
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label, style: TextStyle(color: goldText ? kGold : kText, fontWeight: FontWeight.bold, fontSize: fontSize)),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Local gold PILL button (J-detail-fix1). The shared GoldButton is
/// radius 12 by design and must not change — but mockups #2 (SUBMIT
/// REPORT), #4 (SUBMIT TICKET), #13 (CREATE SUPPORT TICKET) and #20
/// (SEND) all show a fully-rounded pill CTA. [iconBefore] puts the
/// icon to the LEFT of the label (mockup #13's ticket icon).
Widget _goldPillBtn({required String label, required VoidCallback? onPressed, IconData? icon, bool iconBefore = false, bool busy = false, bool fullWidth = true}) {
  final child = busy
      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0A0A0F)))
      : Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null && iconBefore) ...[Icon(icon, size: 18, color: const Color(0xFF0A0A0F)), const SizedBox(width: 8)],
            Text(label, style: const TextStyle(color: Color(0xFF0A0A0F), fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: 0.5)),
            if (icon != null && !iconBefore) ...[const SizedBox(width: 6), Icon(icon, size: 18, color: const Color(0xFF0A0A0F))],
          ],
        );
  final btn = ElevatedButton(
    onPressed: busy ? null : onPressed,
    style: ElevatedButton.styleFrom(
      backgroundColor: kGold,
      foregroundColor: const Color(0xFF0A0A0F),
      disabledBackgroundColor: kGold.withValues(alpha: 0.45),
      disabledForegroundColor: const Color(0xFF0A0A0F),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      elevation: 0,
    ),
    child: child,
  );
  if (!fullWidth) return btn;
  return SizedBox(width: double.infinity, child: btn);
}

/// Faint diagonal shard motif (J-detail-fix1): the dark silver-grey
/// speed-line slashes in the top-right corner of mockups #4 / #13
/// (and Home #37). Static, subtle, behind content — draw once, no
/// animation, no per-frame allocation.
class _TopRightShards extends StatelessWidget {
  const _TopRightShards();
  @override
  Widget build(BuildContext context) => const CustomPaint(painter: _TopRightShardsPainter(), size: Size.infinite);
}

class _TopRightShardsPainter extends CustomPainter {
  const _TopRightShardsPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // Main shard: a wide blade cutting in from the top edge.
    final main = Path()
      ..moveTo(w * 0.58, 0)
      ..lineTo(w, 0)
      ..lineTo(w, h * 0.13)
      ..lineTo(w * 0.86, h * 0.04)
      ..close();
    canvas.drawPath(main, Paint()..color = Colors.white.withValues(alpha: 0.045));
    // Thin shard just below it.
    final thin = Path()
      ..moveTo(w * 0.74, h * 0.05)
      ..lineTo(w, h * 0.015)
      ..lineTo(w, h * 0.055)
      ..lineTo(w * 0.82, h * 0.095)
      ..close();
    canvas.drawPath(thin, Paint()..color = Colors.white.withValues(alpha: 0.03));
    // Faint bright edge along the main shard's long diagonal.
    canvas.drawLine(
      Offset(w * 0.86, h * 0.04),
      Offset(w, h * 0.13),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.10)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Clock time only ("7:12 PM") for thread timestamps (mockup #20).
String _fmtClock(dynamic ts) {
  final ms = SupaDb.parseTs(ts);
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour >= 12 ? 'PM' : 'AM'}';
}

/// "Sat, Nov 22 • 8:00 PM" — the mockup #2 tournament-card date
/// line, from a real start-time ms value.
String _fmtShortWhen(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '${wd[d.weekday - 1]}, ${mo[d.month - 1]} ${d.day} • $h:${d.minute.toString().padLeft(2, '0')} ${d.hour >= 12 ? 'PM' : 'AM'}';
}

/// NOTE (2026-11-21, #16 dedup): the old MatchSummaryPage build used a
/// local `_ordinal` helper; it was deleted with that duplicate screen.
/// MatchResultDetailsPage (more_screens.dart) owns its own `_ordinal`.

/// XP / level / MMR — computed live from existing records, never stored
/// as a claim. Formula (documented in-app): XP = matches×10 + wins×50 +
/// kills×2. Level = XP~/200 + 1. MMR = 1000 + wins×25 + kills×2 −
/// losses×10 (floor 0).
Future<Map<String, int>> playerProgress(String uid) async {
  final profile = await SupaDb.getProfile(uid);
  final history = await SupaDb.getMatchHistory(uid);
  final matches = SupaDb.intOf(profile['totalMatches'], history.length);
  final wins = SupaDb.intOf(profile['wonMatches'], history.where((h) => SupaDb.intOf(h['rank']) == 1).length);
  final kills = history.fold<int>(0, (s, h) => s + SupaDb.intOf(h['kills']));
  final xp = matches * 10 + wins * 50 + kills * 2;
  final mmr = max(0, 1000 + wins * 25 + kills * 2 - max(0, matches - wins) * 10);
  return {'xp': xp, 'level': xp ~/ 200 + 1, 'mmr': mmr, 'matches': matches, 'wins': wins, 'kills': kills};
}

/// In-app points (NOT real money, NOT betting): earned only from Daily
/// Spin, Quiz, Daily Reward and Season free-track claims; spent only on
/// free-coin Cheers. Computed from transactions, so no new table needed.
Future<double> pointsBalance(String uid) async {
  try {
    final rows = await SupaDb.getList('transactions', eqCol: 'firebase_uid', eqVal: uid);
    const pointTypes = {'spin_points', 'quiz_points', 'daily_reward', 'season_reward', 'cheer_points'};
    var sum = 0.0;
    for (final r in rows) {
      if (pointTypes.contains(SupaDb.strOf(r['type']))) sum += SupaDb.numOf(r['amount']);
    }
    return sum;
  } catch (_) {
    return 0;
  }
}

Widget proPendingCard(String feature) => MockupCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Backend pending', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text('$feature ke liye naya database table abhi nahi bana hai. Admin ko migration 008_pro_features.sql chalani hogi (Supabase Dashboard → SQL Editor). Tab tak yeh feature dikhaya ja raha hai, fake data nahi.', style: TextStyle(color: kMuted, fontSize: 13)),
        ],
      ),
    );

Widget proEmpty(String text) => Padding(
      padding: const EdgeInsets.all(24),
      child: Center(child: Text(text, style: TextStyle(color: kMuted), textAlign: TextAlign.center)),
    );

/// ---------------- PRO HUB ----------------


// REMAINING-ITEMS item 9: Pro Hub tile labels in Roman Urdu when the
// language toggle is ON (tr() reads langUrduNotifier). Labels not in
// this map keep their English text — the toggle scope is documented
// in SettingsExtrasPage, not claimed as full-app translation.
String _hubUrdu(String en) {
  const m = {
    'Teams': 'Teams',
    'Match Check-in': 'Match Check-in',
    'Create Tournament': 'Tournament Banayen',
    'Disputes & Reports': 'Shikayat aur Report',
    'Friends & Follow': 'Dost aur Follow',
    'Prize Escrow & Proof': 'Prize Escrow aur Proof',
    'Season, XP & MMR': 'Season, XP aur MMR',
    'Hall of Fame': 'Hall of Fame',
    'Seasonal Leaderboards': 'Seasonal Leaderboards',
    'Stats Card & Poster': 'Stats Card aur Poster',
    'Highlight Clips': 'Highlight Clips',
    'Spectate a Room': 'Room Dekhen',
    'Host Tools': 'Host Tools',
    'Rate Tournaments': 'Tournaments Rate Karen',
    'Winner Celebration': 'Winner Celebration',
    'Create Profile': 'Profile Banayen',
    'My Fans (Followers)': 'Mere Fans (Followers)',
    'Match Summary': 'Match Summary',
    'Live Support Chat': 'Live Support Chat',
    'Win Certificate (PDF)': 'Jeet Certificate (PDF)',
    'FAQ': 'FAQ',
    'Help & Support': 'Madad aur Support',
    'New Support Ticket': 'Naya Support Ticket',
    'App Settings (Data/Text)': 'App Settings (Data/Text)',
  };
  return tr(en, m[en] ?? en);
}

class ProHubPage extends StatelessWidget {
  const ProHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = _uid();
    final tiles = <Map<String, dynamic>>[
      {'icon': Icons.group, 'label': 'Teams', 'page': TeamsPage(uid: uid)},
      {'icon': Icons.how_to_reg, 'label': 'Match Check-in', 'page': CheckInPage(uid: uid)},
      {'icon': Icons.add_circle, 'label': 'Create Tournament', 'page': CreateTournamentPage(uid: uid)},
      {'icon': Icons.report, 'label': 'Disputes & Reports', 'page': DisputeReportHubPage(uid: uid)},
      {'icon': Icons.people, 'label': 'Friends & Follow', 'page': PlayerLookupPage(uid: uid)},
      {'icon': Icons.shield, 'label': 'Prize Escrow & Proof', 'page': EscrowHubPage(uid: uid)},
      {'icon': Icons.star, 'label': 'Season, XP & MMR', 'page': ProgressPage(uid: uid)},
      {'icon': Icons.emoji_events, 'label': 'Hall of Fame', 'page': HallOfFamePage()},
      {'icon': Icons.leaderboard, 'label': 'Seasonal Leaderboards', 'page': SeasonalLeaderboardPage()},
      {'icon': Icons.image, 'label': 'Stats Card & Poster', 'page': ShareHubPage(uid: uid)},
      {'icon': Icons.video_library, 'label': 'Highlight Clips', 'page': ClipsPage(uid: uid)},
      {'icon': Icons.visibility, 'label': 'Spectate a Room', 'page': SpectatePage(uid: uid)},
      {'icon': Icons.security, 'label': 'Host Tools', 'page': HostToolsHubPage(uid: uid)},
      {'icon': Icons.star_rate, 'label': 'Rate Tournaments', 'page': RatingPage(uid: uid)},
      {'icon': Icons.celebration, 'label': 'Winner Celebration', 'page': WinnerCelebrationPage(uid: uid)},
      {'icon': Icons.person_add, 'label': 'Create Profile', 'page': CreateProfilePage(uid: uid)},
      {'icon': Icons.favorite, 'label': 'My Fans (Followers)', 'page': FanListPage(uid: uid)},
      {'icon': Icons.summarize, 'label': 'Match Summary', 'page': MatchSummaryHubPage(uid: uid)},
      {'icon': Icons.support_agent, 'label': 'Live Support Chat', 'page': LiveSupportPage(uid: uid)},
      {'icon': Icons.workspace_premium, 'label': 'Win Certificate (PDF)', 'page': CertificatePage(uid: uid)},
      {'icon': Icons.help, 'label': 'FAQ', 'page': const FaqPage()},
      {'icon': Icons.help_center, 'label': 'Help & Support', 'page': HelpSupportPage(uid: uid)},
      {'icon': Icons.confirmation_number, 'label': 'New Support Ticket', 'page': NewSupportTicketPage(uid: uid)},
      {'icon': Icons.tune, 'label': 'App Settings (Data/Text)', 'page': const SettingsExtrasPage()},
    ];
    return Scaffold(
      appBar: AppBar(title: Text('Pro Features', style: TextStyle(color: kGold))),
      body: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 1.25),
        itemCount: tiles.length,
        itemBuilder: (context, i) {
          final t = tiles[i];
          return InkWell(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => t['page'] as Widget)),
            borderRadius: BorderRadius.circular(14),
            child: MockupCard(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(t['icon'] as IconData, color: kGold, size: 30),
                  const SizedBox(height: 8),
                  Text(_hubUrdu(t['label'] as String), style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 13), textAlign: TextAlign.center),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// ---------------- TEAMS ----------------

/// FIX 7 (2026-11-21, team photo): the `teams` table has NO photo
/// column in the code's reads/writes (name / tag / game / is_clan /
/// captain_uid / captain_name / invite_code / roster_locked only),
/// and no migration adds one — so until the backend adds
/// `teams.photo_url` (see BACKEND ADDENDUM in the fix report), the
/// photo URL is persisted device-locally in SharedPreferences keyed
/// by team id. The resolver below prefers the SERVER value whenever
/// the row carries one, so the same code lights up server-wide the
/// moment the column exists — no app change needed then.
/// `getRow`/`getList` use select(), so a future `photo_url` column
/// flows into the team maps automatically.
String resolveTeamPhotoUrl({String? serverUrl, String? localUrl}) {
  if (serverUrl != null && serverUrl.isNotEmpty) return serverUrl;
  if (localUrl != null && localUrl.isNotEmpty) return localUrl;
  return '';
}

String teamPhotoPrefsKey(String teamId) => 'team_photo_$teamId';

/// Device-local team photo URL (FIX 7 fallback). Never throws — a
/// prefs failure reads as "no local photo", never as a page error.
Future<String> loadTeamPhotoLocal(String teamId) async {
  if (teamId.isEmpty) return '';
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(teamPhotoPrefsKey(teamId)) ?? '';
  } catch (_) {
    return '';
  }
}

Future<void> saveTeamPhotoLocal(String teamId, String url) async {
  if (teamId.isEmpty) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    if (url.isEmpty) {
      await prefs.remove(teamPhotoPrefsKey(teamId));
    } else {
      await prefs.setString(teamPhotoPrefsKey(teamId), url);
    }
  } catch (_) {}
}

/// FIX 5b (2026-11-21): the My Team EDIT TEAM / TEAM HISTORY pair,
/// extracted so the 360dp no-overflow behaviour is widget-testable.
/// Labels stay EXACTLY "EDIT TEAM" / "TEAM HISTORY" (user order) —
/// the fit comes from the smaller font (13) + tighter padding (12)
/// + the FittedBox inside [_goldOutlineBtn], never from shortening
/// the text. EDIT is captain-only (null when not captain, same as
/// before); HISTORY is open to every member.
/// MOCKUP #3 PRINTER-COPY (2026-11-21, measured): the pair is
/// ~26dp tall on the mockup, so verticalPadding 5 (~28dp) — the
/// shared default 14 would make the pair ~46dp, nearly twice the
/// mockup height. Font stays 13 (measured + pinned by test).
class TeamActionButtons extends StatelessWidget {
  final bool isCaptain;
  final VoidCallback? onEdit;
  final VoidCallback onHistory;
  const TeamActionButtons({super.key, required this.isCaptain, required this.onEdit, required this.onHistory});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      // Mockup #3: gold pencil / clock icons with white labels.
      Expanded(child: _goldOutlineBtn(label: 'EDIT TEAM', icon: Icons.edit, goldIcon: true, fontSize: 13, horizontalPadding: 12, verticalPadding: 5, onPressed: isCaptain ? onEdit : null)),
      const SizedBox(width: 10),
      Expanded(child: _goldOutlineBtn(label: 'TEAM HISTORY', icon: Icons.history, goldIcon: true, fontSize: 13, horizontalPadding: 12, verticalPadding: 5, onPressed: onHistory)),
    ]);
  }
}

/// MY TEAM mockup #3 — PRINTER-COPY (2026-11-21, user voice call:
/// "jaise printer se hazaar copies ek jaisi nikalti hain"). Every
/// size below was MEASURED off the mockup
/// (109096427_1795037743902443.jpg, 768x1376 = a 360dp-wide phone,
/// 2.133 px/dp) with visual grounding — no eyeballed sizes:
/// team card ~113dp tall, shield box ~34dp, stats bar ~30dp,
/// action buttons ~26dp tall, invite card ~62dp, roster card
/// ~64-70dp on a ~76dp pitch, avatar circle ~55dp, bottom nav
/// ~53dp. Font sizes are the WIDTH-measured values (team name 24,
/// invite code 18, INVITE PLAYER + 12) — the height bboxes were
/// loose, the widths tight. Data stays REAL everywhere: the
/// mockup's Team Alpha / ALPHA709X / ViperX / 12 matches / Rank #8
/// are layout samples only, never copied as data.

/// Roster capacity of one team row (mockup #3 "4/4"): an explicit
/// size column wins; else a stored mode maps Solo 1 / Duo 2 /
/// Squad 4 (same formula as the registration unify rule — the
/// mode column describes the TOURNAMENT format the team was made
/// for, not a team type). Otherwise null: FIX 11 (2026-11-23)
/// removed the Squad team type and FIX 12 G5 removed the Clan
/// type too, so every team is just a team and a team has no fixed
/// cap — the header shows the bare count and
/// no empty slots are invented.
int? teamRosterSize(Map<String, dynamic> team) {
  final explicit = SupaDb.intOf(team['team_size'], SupaDb.intOf(team['max_members'], SupaDb.intOf(team['size'])));
  if (explicit > 0) return explicit;
  if (SupaDb.strOf(team['mode']).isNotEmpty) return SupaDb.teamSizeOf(team);
  return null;
}

/// "ROSTER (4/4)" when the cap is known, "ROSTER (4)" for a team.
String rosterHeaderLabel(int count, int? size) => size == null ? 'ROSTER ($count)' : 'ROSTER ($count/$size)';

/// "4/4 Members" when the cap is known, "4 Members" for a team.
String membersStatLabel(int count, int? size) => size == null ? '$count Members' : '$count/$size Members';

/// P2 RANKS / POSITIONS / CAP (2026-11-22, migration 081):
/// valid squad positions (mockup #3 roster roles; the captain's
/// row always shows 'IGL / Leader' instead — see _memberCard).
/// Stored in team_members.position (CHECK-enforced server-side).
/// Pure — unit-tested in test/my_team_ranks_test.dart.
const List<String> teamPositions = ['IGL', 'Assaulter', 'Support', 'Entry Fragger'];

bool isValidTeamPosition(String? position) => position != null && teamPositions.contains(position);

/// Display label for a stored position: the position itself when
/// valid, '' when unset/invalid (the caller falls back to 'Member').
String teamPositionLabel(String? position) => isValidTeamPosition(position) ? position! : '';

/// "Rank #8" for a real rank, "Rank —" when unranked (NULL) —
/// never a fake rank. [rank] is the raw teams.team_rank value
/// (migration 081, written only by recompute_team_ranks).
String teamRankLabel(dynamic rank) {
  final r = SupaDb.intOf(rank, 0);
  return r > 0 ? 'Rank #$r' : 'Rank —';
}

/// True when the roster cap is known and reached (or over — a
/// stale/over-full roster is still full). A null cap (team) is
/// never full.
bool teamIsFull(int count, int? size) => size != null && count >= size;

/// Honest empty slots: how many roster places are still open.
/// 0 when the cap is unknown (team) or the roster is full/over.
int emptySlotCount(int count, int? size) {
  if (size == null) return 0;
  final open = size - count;
  return open > 0 ? open : 0;
}

/// GLOBAL CARD RULE (2026-11-22, user order — SUPERSEDES the
/// 2026-11-21 mockup #3 "PRINTER-COPY" full gold border + glow):
/// team cards follow the same rule as every other card in the
/// app — the standard kCard gradient fill, NO full border, just the
/// two short yellow shines (top-right + bottom-left) with fade
/// in/out + clock-hands rotation. Implemented by delegating to
/// [MockupCard] (the global card component): [gold] true =
/// animated shines (team list cards, captain roster card);
/// false = parked shines, no ticker (member roster rows — a team
/// roster can be long, so one controller per row would be
/// wasteful). The old FULL 1.5dp gold border + gold glow are gone,
/// in dark and light mode alike (MockupCard owns the light-mode
/// fallback too).
class MyTeamCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool gold;
  final double radius;
  const MyTeamCard({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.gold = true, this.radius = 16});

  @override
  Widget build(BuildContext context) {
    return MockupCard(
      padding: padding,
      radius: radius,
      animate: gold,
      child: child,
    );
  }
}

/// Mockup #3 roster row (PRINTER-COPY 2026-11-21, measured):
/// ~55dp avatar circle (gold ring for the captain, muted ring
/// otherwise), name 18 bold white, "UID: …" 12 grey, role 14
/// (captain gold bold "IGL / Leader", members grey), ONLINE green
/// dot + text / OFFLINE grey at the bottom-right. The captain's
/// card has the FULL gold border + the gold CAPTAIN tab (drawn crown
/// via the shared ArenaRolePill — the same gold pill + flat black
/// crown as the mockup #27 ORGANIZER pill; the old ♛ text glyph is
/// unverified on the TECNO, so it is not used)
/// overlapping its top-right corner (top: -6, into the row gap);
/// members get the muted border and no tab. [uidLine] is the
/// in-game UID line (rosterUidLine) — never a Firebase UID.
/// Pure layout — the caller ([_TeamDetailPageState._memberCard])
/// still owns the role/presence/profile lookups, so this stays
/// widget-testable.
class TeamMemberCard extends StatelessWidget {
  final String name;
  final String uidLine;
  final String roleText;
  final String photoUrl;
  final bool isCaptain;
  final bool online;
  // LAST SEEN (2026-11-22): the member's presence last_seen (epoch
  // ms, 0 = never seen). Offline members show "Last seen X" under
  // OFFLINE (same rule as the Status sheet); online members show
  // just ONLINE.
  final int lastSeenMs;
  const TeamMemberCard({super.key, required this.name, required this.uidLine, required this.roleText, this.photoUrl = '', required this.isCaptain, required this.online, this.lastSeenMs = 0});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          MyTeamCard(
            gold: isCaptain,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: isCaptain ? kGold : kBorder, width: 2)),
                  // WAVE 4 FIX 5 (B): disk-cached avatar (was bare
                  // NetworkImage). Empty URL -> person icon, dead URL
                  // -> person icon, same as before.
                  child: ArenaCachedAvatar(
                    photoUrl: photoUrl,
                    radius: 24,
                    backgroundColor: kField,
                    fallback: photoUrl.isEmpty ? Icon(Icons.person, color: kGold, size: 26) : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(name, style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 18)),
                      ),
                      Text(uidLine, style: TextStyle(color: kMuted, fontSize: 12), overflow: TextOverflow.ellipsis),
                      Text(roleText, style: TextStyle(color: isCaptain ? kGold : kMuted, fontSize: 14, fontWeight: isCaptain ? FontWeight.bold : FontWeight.normal)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(children: [
                      Container(width: 8, height: 8, decoration: BoxDecoration(color: online ? Colors.green : kMuted, shape: BoxShape.circle)),
                      const SizedBox(width: 5),
                      Text(online ? 'ONLINE' : 'OFFLINE', style: TextStyle(color: online ? Colors.green : kMuted, fontSize: 12, fontWeight: FontWeight.bold)),
                    ]),
                    // LAST SEEN (2026-11-22): offline members show
                    // when they were last online (real last_seen, or
                    // "Last seen —" when never seen — never a fake
                    // date: timeAgo(0) would render 1970).
                    if (!online) ...[
                      const SizedBox(height: 2),
                      Text(lastSeenMs > 0 ? 'Last seen ${timeAgo(lastSeenMs)}' : 'Last seen —', style: TextStyle(color: kMuted, fontSize: 11)),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (isCaptain)
            // Mockup #3 CAPTAIN tab: the shared ArenaRolePill
            // (gold pill + drawn flat black crown, same as the
            // mockup #27 ORGANIZER pill) — a proper crown, not the
            // ♛ text glyph (unverified on the TECNO).
            const Positioned(
              top: -6,
              right: 10,
              child: ArenaRolePill('CAPTAIN'),
            ),
        ],
      ),
    );
  }
}

/// Honest empty roster slot (mockup #3 "player-section count"):
/// shown once per open place when the roster is partial (e.g. 2/4
/// shows 2 of these). NEVER a fake player — no name, no UID, no
/// avatar photo, just the open place. Same height as a roster row.
class EmptyRosterSlot extends StatelessWidget {
  const EmptyRosterSlot({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: kField,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kGold.withValues(alpha: 0.45), width: 1),
        ),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kGold.withValues(alpha: 0.45), width: 2)),
              child: Icon(Icons.person_add_alt_1, color: kGold.withValues(alpha: 0.7), size: 26),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('Empty Slot', 'Khali slot'), style: TextStyle(color: kMuted, fontWeight: FontWeight.bold, fontSize: 16)),
                  Text(tr('Invite a player to fill this spot', 'Is slot ke liye player invite karen'), style: TextStyle(color: kMuted, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Mockup #3 bottom nav (PRINTER-COPY 2026-11-21): the shell's
/// 6-tab nav (Home, Events, My Matches, Rankings, Community,
/// Profile — Community is an ordered feature, kept even though
/// the mockup predates it) with the active tab in gold — gold icon
/// + label, gold segment at the TOP edge above the active tab and
/// the gold underline bar below it, same as the shell in main.dart.
/// CONTEXT-AWARE (2026-11-22, nav-highlight bug): the active tab
/// used to be HARDCODED to My Matches (2), so the teams list
/// opened from the Community tab wrongly highlighted My Matches.
/// [activeIndex] is now passed in — 2 for My Matches context, 4
/// for Community context (TeamsPage embedded on the nav Community
/// tab passes 4 down to TeamDetailPage). Default stays 2 (mockup).
/// WIRING GAP (needs main.dart, another lane): tab taps can only
/// pop back to the shell root from this pushed page — the shell's
/// tab index is not switchable from here, so every tap returns to
/// the shell's current tab. The visual is exact; the tab switch is
/// NOT wired. See the My Team report.
class MyTeamBottomNav extends StatelessWidget {
  final int activeIndex;
  const MyTeamBottomNav({super.key, this.activeIndex = 2});

  @override
  Widget build(BuildContext context) {
    final center = navBarTabCenter(context, activeIndex);
    // REDESIGN §5 (F2): SafeArea so the nav never sits under the
    // system gesture bar / covers content at the bottom edge.
    // FIX 23 item 23: floating purple bar (ChatGPT reference) —
    // same shell as ArenaBottomNav.
    return SafeArea(
      top: false,
      child: navBarShell(
        child: Stack(
          children: [
            MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.0)),
              child: BottomNavigationBar(
                currentIndex: activeIndex,
                onTap: (_) => Navigator.of(context).popUntil((route) => route.isFirst),
                type: BottomNavigationBarType.fixed,
                backgroundColor: Colors.transparent,
                selectedFontSize: 10,
                unselectedFontSize: 9,
                selectedItemColor: kGold,
                // FIX 23 item 23: unselected = lavender.
                unselectedItemColor: kNavUnselected,
              items: [
                BottomNavigationBarItem(icon: const Icon(Icons.home), label: tr('Home', 'Home')),
                BottomNavigationBarItem(icon: const Icon(Icons.calendar_month), label: tr('Events', 'Events')),
                BottomNavigationBarItem(icon: const CrossedSwordsIcon(), label: tr('My Matches', 'My Matches')),
                BottomNavigationBarItem(icon: const Icon(Icons.leaderboard), label: tr('Rankings', 'Rankings')),
                BottomNavigationBarItem(icon: const Icon(Icons.people), label: tr('Community', 'Community')),
                BottomNavigationBarItem(icon: const Icon(Icons.person), label: tr('Profile', 'Profile')),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: center - 22,
            child: Container(width: 44, height: 4, decoration: BoxDecoration(color: kGold, borderRadius: BorderRadius.circular(2))),
          ),
          Positioned(
            bottom: 0,
            left: center - 26,
            child: Container(width: 52, height: 4, decoration: BoxDecoration(color: kGold, borderRadius: BorderRadius.circular(2))),
          ),
        ],
        ),
      ),
    );
  }
}

/// FIX 7 (2026-11-21): the team photo / logo box — the shield icon
/// box on the team card and the detail header, now showing the
/// uploaded team photo when one exists (disk-cached, same
/// ArenaCachedImage pattern as the tournament banner). Empty or
/// failed URL falls back to the gold shield, exactly as before.
/// Only the captain gets the camera affordance (gold circle at the
/// bottom-right corner); members see the photo/shield with no
/// affordance at all. [busy] swaps the camera icon for a spinner
/// while an upload is in flight.
class TeamPhotoBadge extends StatelessWidget {
  final String? photoUrl;
  final bool isCaptain;
  final VoidCallback? onChangePhoto;
  final double size;
  final bool busy;
  const TeamPhotoBadge({super.key, this.photoUrl, required this.isCaptain, this.onChangePhoto, this.size = 52, this.busy = false});

  @override
  Widget build(BuildContext context) {
    final url = photoUrl ?? '';
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: kGold.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12), border: Border.all(color: kGold)),
          child: url.isEmpty
              ? Icon(Icons.shield, color: kGold, size: size * 0.6)
              : ArenaCachedImage(imageUrl: url, width: size, height: size, fit: BoxFit.cover, borderRadius: BorderRadius.circular(11), placeholderIcon: Icons.shield),
        ),
        if (isCaptain)
          Positioned(
            right: -4,
            bottom: -4,
            child: Tooltip(
              message: tr('Change team photo', 'Team photo badlein'),
              child: Material(
                color: kGold,
                shape: const CircleBorder(),
                child: InkWell(
                  onTap: busy ? null : onChangePhoto,
                  customBorder: const CircleBorder(),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: busy
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0A0A0F)))
                        : const Icon(Icons.camera_alt, size: 14, color: Color(0xFF0A0A0F)),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// ANIMATED CTA (2026-11-22, Create/Join buttons): the teams-list
/// CTAs had no visible animation — Material's splash alone reads as
/// "not animating". This wrapper adds (1) a press-scale (0.96 while
/// pressed, springs back in 120ms) and (2) a slow breathing gold
/// halo behind the button (2s, subtle alpha 0.20 → 0.35) — the
/// theme-matched attention animation. Both CTAs use it so they
/// animate as a pair. Listener (not GestureDetector) so the
/// button's own tap is never disturbed.
class _AnimatedCta extends StatefulWidget {
  final Widget child;
  const _AnimatedCta({required this.child});
  @override
  State<_AnimatedCta> createState() => _AnimatedCtaState();
}

class _AnimatedCtaState extends State<_AnimatedCta> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) => setState(() => _pressed = false),
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          final t = Curves.easeInOut.transform(_pulse.value);
          return Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              boxShadow: [
                BoxShadow(
                  color: kGold.withValues(alpha: 0.20 + 0.15 * t),
                  blurRadius: 12 + 10 * t,
                  spreadRadius: 1 + 2 * t,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: AnimatedScale(
              scale: _pressed ? 0.96 : 1.0,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: child,
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// v2016 FIX 12: compact outlined action button for team cards —
/// 34dp tall (vs the old full-size TextButton), gold outline +
/// gold icon/label, fills its Expanded slot.
/// PHASE E (E24, CORRECTED 2026-11-24): the faint gold tint is
/// back (this button's gold-accent identity — gold outline +
/// gold icon/label); it has no selected state, so the card-fill
/// rule does not apply to it.
/// REDESIGN S6 (2026-11-23): F1 tokens for the radius, padding and
/// label style — same size, same gold treatment, same tap target.
class _TeamCardActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  const _TeamCardActionButton({required this.icon, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: kGold.withValues(alpha: 0.6)),
          backgroundColor: kGold.withValues(alpha: 0.06),
          padding: const EdgeInsets.symmetric(horizontal: kSpace8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadiusChip)),
        ),
        icon: Icon(icon, color: kGold, size: 16),
        label: Text(label, style: kStyleLabel.copyWith(color: kGold, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

/// Teams list (mockup #3). RESTRUCTURE (2026-11-22, user
/// order): this page IS the nav Community tab now — [embedded]
/// hides its own bottom nav ([MyTeamBottomNav]) so it never
/// doubles up with the shell's nav. Pushed routes (Pro Hub →
/// Teams) keep `embedded: false` and their own nav.
///
/// FIX 12 G11 (2026-11-23) — the three-button top row's labels.
/// Button 2 reads "Squad" (user order: "Squad ya Team" — Squad
/// won); the label lives in ONE named constant so it flips to
/// "Team" in a single line if the user changes his mind. The
/// other two labels are constants too, so the whole row reads
/// from one place.
const String kCommunityTabLabel = 'Community';
const String kSquadTabLabel = 'Squad';
const String kCreateTabLabel = 'Create';

class TeamsPage extends StatefulWidget {
  final String uid;
  final bool embedded;
  const TeamsPage({super.key, required this.uid, this.embedded = false});
  @override
  State<TeamsPage> createState() => _TeamsPageState();
}

class _TeamsPageState extends State<TeamsPage> {
  bool _pending = false;
  List<Map<String, dynamic>> _mine = [];
  // Real member count per team id (mockup #3 stats row "4/4 Members"
  // shows the live count; there is no stored size cap, so only the
  // real count is shown — never a fake "/4").
  Map<String, int> _memberCounts = {};
  // FIX 7: device-local team photo URLs (SharedPreferences fallback
  // until the backend adds `teams.photo_url`) — one per team id.
  Map<String, String> _localPhotos = {};
  bool _busy = true;
  bool _refreshing = false;
  // Set only by the reachable failure paths (create/join direct
  // client calls — see _isOfflineError note above). 'offline' shows
  // OfflineState, anything else shows ErrorState with the message.
  String? _error;
  // TEAM-INVITE FIX (2026-11-21): pending invites for this user,
  // read directly from team_invitations (SupaDb
  // .getPendingTeamInvites + enrichTeamInvites) — the invitee's
  // SECOND discovery place besides Notifications. A user with no
  // team yet sees their invites here with Accept/Decline.
  List<Map<String, dynamic>> _invites = [];
  // Invite ids with a respond call in flight (buttons disabled
  // until it lands — no double-tap double-respond).
  final Set<String> _respondingInvites = {};

  // FIX 11 (2026-11-23): list side. false = my squads/teams
  // (default — the list this page showed before), true = public
  // communities (embedded list, same data + paging as
  // CommunitiesListPage). FIX 12 G11 replaced Fix 11's two-pill
  // Clan/Community toggle with the three-button top row
  // (Community / Squad / Create) — this flag is now driven by
  // the row's Community and Squad buttons, via _selectTab.
  bool _showCommunities = false;
  // FIX 11: public-communities tab state — paged 50, server-side
  // search, pull-to-refresh (mirrors CommunitiesListPage §4.1,
  // minus the cached-first layer: the tab loads fresh on first
  // open, and refreshes on pull + after a create returns).
  List<Map<String, dynamic>> _communities = [];
  bool _commLoading = false;
  bool _commLoadingMore = false;
  bool _commHasMore = true;
  bool _commReady = true;
  bool _commLoadedOnce = false;
  // FIX 23 item 19 — ids followed from a card this session (the
  // Follow button stays hidden for them) + ids with a follow
  // request in flight (double-tap guard).
  final Set<String> _commFollowedIds = {};
  final Set<String> _commFollowBusyIds = {};
  String _commQuery = '';
  final _commSearchCtrl = TextEditingController();
  final _commScroll = ScrollController();
  Timer? _commSearchTimer;

  @override
  void initState() {
    super.initState();
    _commScroll.addListener(_onCommScroll);
    _load();
  }

  @override
  void dispose() {
    _commSearchTimer?.cancel();
    _commSearchCtrl.dispose();
    _commScroll.dispose();
    super.dispose();
  }

  void _onCommScroll() {
    if (!_commScroll.hasClients || _commLoadingMore || !_commHasMore || _commLoading) return;
    if (_commScroll.position.pixels >= _commScroll.position.maxScrollExtent - 200) {
      _loadMoreCommunities();
    }
  }

  /// FIX 11: load one page of public communities (50/page,
  /// server-side name search). Never throws — a failed load reads
  /// as an empty list, never a crash.
  Future<void> _loadCommunities({int offset = 0}) async {
    final firstPage = offset == 0;
    if (firstPage) {
      setState(() {
        _commLoading = _communities.isEmpty;
        _commHasMore = true;
      });
    }
    final ready = await CommunityGroups.communitiesBackendReady();
    // FIX 12 G15: the server returns newest-first; the list shows
    // member-count DESCENDING (COUNT-based memberCount). Sort the
    // page AND the merged list, so paging never breaks the order.
    final list = sortCommunitiesByMembers(await CommunityGroups.listCommunities(myUid: widget.uid, search: _commQuery, offset: offset));
    if (!mounted) return;
    setState(() {
      _commReady = ready;
      _commLoading = false;
      _commLoadingMore = false;
      _commLoadedOnce = true;
      _commHasMore = list.length >= CommunityGroups.pageSize;
      _communities = firstPage ? list : sortCommunitiesByMembers([..._communities, ...list]);
    });
  }

  Future<void> _loadMoreCommunities() async {
    if (_commLoadingMore || !_commHasMore) return;
    setState(() => _commLoadingMore = true);
    await _loadCommunities(offset: _communities.length);
  }

  void _onCommSearchChanged(String v) {
    _commSearchTimer?.cancel();
    _commSearchTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _commQuery = v.trim());
      _loadCommunities();
    });
  }

  /// FIX 11 (three-button row since FIX 12 G11): switch between
  /// the Squad list and the Community list. The communities
  /// list loads lazily on first open (no wasted fetch when the
  /// user only ever looks at their squads).
  void _selectTab(bool communities) {
    if (_showCommunities == communities) return;
    setState(() => _showCommunities = communities);
    if (communities && !_commLoadedOnce) _loadCommunities();
  }

  /// FIX 12 G13: open the ONE unified create form (name,
  /// description, photo + [Community] [Squad] submit boxes — the
  /// form itself decides the type). A successful create refreshes
  /// BOTH lists, because either a community or a squad may have
  /// been created. Entry-point name/signature unchanged from Fix 11
  /// (still pushes `CreateCommunityPage(uid: ...)`).
  Future<void> _openCreateCommunity() async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => CreateCommunityPage(uid: widget.uid)),
    );
    if (created == true && mounted) {
      _loadCommunities();
      _load(refresh: true);
    }
  }

  /// FIX 12 G11 + G13: the top row's Create button opens the ONE
  /// unified create form (name, description, photo + the
  /// [Community]/[Squad] option boxes) on either side — the old
  /// squad create dialog is DELETED, both sides use the same
  /// form. No form is built here.
  void _openCreate() {
    _openCreateCommunity();
  }

  /// FIX 11: open a public community's detail page (chat +
  /// members). Refresh on return so a follow/unfollow inside the
  /// detail page shows in the list.
  /// FIX 22 (2026-11-23): the detail page IS the chat now
  /// (tabs removed) — tap opens it directly.
  Future<void> _openCommunity(Map<String, dynamic> c) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => CommunityDetailPage(
              uid: widget.uid,
              communityId: SupaDb.strOf(c['id']),
              community: c)),
    );
    if (mounted) _loadCommunities();
  }

  /// FIX 23 item 19 — Follow from a card = a REAL JOIN:
  /// [CommunityGroups.followCommunity] inserts the
  /// community_members row, so the tap joins directly from
  /// outside. Success -> the button DISAPPEARS (no "Following"
  /// state on the card; unfollow lives inside the room).
  /// Failure -> the button stays + an honest toast.
  Future<void> _followFromCard(Map<String, dynamic> c) async {
    final id = SupaDb.strOf(c['id']);
    if (id.isEmpty || _commFollowBusyIds.contains(id)) return;
    setState(() => _commFollowBusyIds.add(id));
    final res = await CommunityGroups.followCommunity(widget.uid, id);
    if (!mounted) return;
    setState(() => _commFollowBusyIds.remove(id));
    if (res['ok'] == true) {
      setState(() {
        _commFollowedIds.add(id);
        for (final item in _communities) {
          if (SupaDb.strOf(item['id']) == id) {
            item['isMember'] = true;
          }
        }
      });
      toast(context, 'Follow ho gaya — community join ho gayi!');
    } else {
      toast(
          context,
          res['offline'] == true
              ? 'Communities backend abhi online nahi hua (migration 073 pending).'
              : 'Failed: ${res['error']}');
    }
  }

  /// FIX ROUND 2026-10-28 (Teams stuck on spinner): the old code set
  /// _busy = true on EVERY reload, so after "Team ban gayi!" the page
  /// went back to a full-screen spinner — on a slow connection, with
  /// the N+1 per-team fetches below, that looked stuck forever.
  /// Refreshes now keep the existing list visible (only a thin
  /// indicator at the top) and the initial load is the only
  /// full-screen spinner. _busy is always cleared in `finally`, so a
  /// failed fetch can never leave the spinner up.
  Future<void> _load({bool refresh = false}) async {
    if (refresh && _mine.isNotEmpty) {
      setState(() {
        _refreshing = true;
        _error = null;
      });
    } else {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      final memberships = await SupaDb.getList('team_members', eqCol: 'firebase_uid', eqVal: widget.uid);
      final ids = memberships.map((m) => SupaDb.strOf(m['team_id'])).where((s) => s.isNotEmpty).toList();
      final teams = <Map<String, dynamic>>[];
      final counts = <String, int>{};
      final localPhotos = <String, String>{};
      for (final id in ids) {
        final row = await SupaDb.getRow('teams', 'id', id);
        if (row.isNotEmpty) {
          teams.add(row);
          counts[id] = (await SupaDb.getList('team_members', eqCol: 'team_id', eqVal: id)).length;
          // FIX 7: device-local photo for this team (never throws —
          // loadTeamPhotoLocal swallows prefs failures).
          final local = await loadTeamPhotoLocal(id);
          if (local.isNotEmpty) localPhotos[id] = local;
        }
      }
      if (mounted) {
        setState(() {
          _mine = teams;
          _memberCounts = counts;
          _localPhotos = localPhotos;
        });
      }
      // TEAM-INVITE FIX: pending invites, best-effort — a failed
      // read hides the section (empty list), never the team list.
      try {
        final pending = await SupaDb.getPendingTeamInvites(widget.uid);
        final enriched = await SupaDb.enrichTeamInvites(pending);
        if (mounted) setState(() => _invites = enriched);
      } catch (_) {
        if (mounted) setState(() => _invites = []);
      }
    } catch (e) {
      // Defensive only: getList/getRow swallow read errors (return
      // []/{}), so this fires only for an unexpected throw.
      if (mounted) {
        if (proTableMissing(e)) {
          setState(() => _pending = true);
        } else if (_isOfflineError(e)) {
          setState(() => _error = 'offline');
        } else {
          setState(() => _error = 'Teams load nahi ho sake: $e');
        }
      }
    } finally {
      if (mounted) setState(() {
        _busy = false;
        _refreshing = false;
      });
    }
  }

  /// Accept/Decline a pending team invitation from the My Team
  /// section (same direct-write path as the Notifications page —
  /// SupaDb.respondTeamInvite; the 027 RPC cannot run from this
  /// app). On success the list refreshes, so the invite leaves the
  /// section and the joined team appears below.
  Future<void> _respondToInvite(Map<String, dynamic> inv, String response) async {
    final inviteId = SupaDb.strOf(inv['invite_id']);
    if (inviteId.isEmpty || _respondingInvites.contains(inviteId)) return;
    if (response == 'accepted') {
      // 081 CAP: do not accept into a full roster — the invite is
      // left pending (still Accept/Decline-able later) instead of
      // joining over the cap. Reads fail open (getRow/getList
      // return empty on error, same as the rest of this page);
      // the server-side cap guard is open item O3 in 081.
      final teamId = SupaDb.strOf(inv['team_id']);
      if (teamId.isNotEmpty) {
        final team = await SupaDb.getRow('teams', 'id', teamId);
        final cap = teamRosterSize(team);
        final memberCount = (await SupaDb.getList('team_members', eqCol: 'team_id', eqVal: teamId)).length;
        if (teamIsFull(memberCount, cap)) {
          toast(context, 'Team full hai ($memberCount/$cap) — join nahi ho sakti.');
          return;
        }
      }
    }
    setState(() => _respondingInvites.add(inviteId));
    final profile = await SupaDb.getProfile(widget.uid);
    final res = await SupaDb.respondTeamInvite(
      inviteId,
      response,
      uid: widget.uid,
      userName: SupaDb.strOf(profile['displayName'], 'User'),
    );
    if (!mounted) return;
    setState(() => _respondingInvites.remove(inviteId));
    if (res['ok'] == true) {
      toast(context, response == 'accepted' ? 'Team join ho gayi!' : 'Invitation decline kar di.');
      await _load(refresh: true);
    } else {
      final err = SupaDb.strOf(res['error']);
      if (err.contains('pehle hi respond')) {
        toast(context, 'Ye invitation pehle hi respond ho chuki hai.');
        await _load(refresh: true);
      } else {
        toast(context, 'Failed: $err');
      }
    }
  }

  /// One pending-invite card (MockupCard, gold #FDC903 Accept pill +
  /// outlined Decline pill — same action language as the
  /// Notifications invite card, mockup #22).
  /// REDESIGN S6 (2026-11-23): F1 tokens for padding, gaps, radii
  /// and text styles; the gold literal is the kGold token now.
  Widget _inviteCard(Map<String, dynamic> inv) {
    final inviteId = SupaDb.strOf(inv['invite_id']);
    final teamName = SupaDb.strOf(inv['team_name']);
    final inviterName = SupaDb.strOf(inv['inviter_name']);
    final busy = _respondingInvites.contains(inviteId);
    return Padding(
      padding: const EdgeInsets.only(bottom: kSpace12),
      child: MockupCard(
        padding: const EdgeInsets.all(kSpace16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(kRadiusChip), border: Border.all(color: kGold)),
                child: Icon(Icons.group_add, color: kGold, size: 24),
              ),
              const SizedBox(width: kSpace8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      teamName.isEmpty ? 'Team Invitation' : teamName,
                      style: TextStyle(color: kGold, fontStyle: FontStyle.italic, fontWeight: FontWeight.w900, fontSize: 20),
                    ),
                    Text(
                      inviterName.isEmpty ? 'Aap ko team mein invite kiya gaya hai.' : '$inviterName ne aap ko invite kiya hai.',
                      style: kStyleLabel.copyWith(color: kMuted),
                    ),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: kSpace12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _inviteActionBtn(label: 'Accept', gold: true, busy: busy, onTap: () => _respondToInvite(inv, 'accepted')),
                const SizedBox(width: kSpace8),
                _inviteActionBtn(label: 'Decline', gold: false, busy: busy, onTap: () => _respondToInvite(inv, 'declined')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Invite action pill: Accept = solid gold, Decline = dark with a
  /// muted border. Flat — no glow, no shadow.
  /// REDESIGN S6 (2026-11-23): F1 tokens for padding and label.
  Widget _inviteActionBtn({required String label, required bool gold, required bool busy, required VoidCallback onTap}) {
    return Opacity(
      opacity: busy ? 0.5 : 1,
      child: AbsorbPointer(
        absorbing: busy,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: kSpace16, vertical: kSpace8),
            decoration: BoxDecoration(
              color: gold ? kGold : kField,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: gold ? kGold : kBorder),
            ),
            child: Text(label, style: kStyleMeta.copyWith(color: gold ? const Color(0xFF0A0A0F) : kText, fontWeight: FontWeight.bold)),
          ),
        ),
      ),
    );
  }


  Future<void> _joinByCode() async {
    final codeCtrl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      // REDESIGN S6 (2026-11-23): elevated dialog surface, F1 card
      // radius, F2 input (gold focus border, dark fill) and token
      // text styles. Same flow, same labels, same compact size.
      builder: (context) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text('Join by invite code', style: kStyleSection.copyWith(color: kGold)),
        content: ArenaTextField(controller: codeCtrl, labelText: 'Invite code'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel', style: kStyleBody.copyWith(color: kMuted))),
          TextButton(onPressed: () => Navigator.pop(context, codeCtrl.text.trim()), child: Text('Join', style: kStyleBody.copyWith(color: kGold, fontWeight: FontWeight.bold))),
        ],
      ),
    );
    if (code == null || code.isEmpty) return;
    try {
      final rows = await SupaDb.getList('teams', eqCol: 'invite_code', eqVal: code);
      if (rows.isEmpty) {
        if (mounted) toast(context, 'Is code ki koi team nahi mili.');
        return;
      }
      final team = rows.first;
      if (SupaDb.asMap(team)['roster_locked'] == true) {
        if (mounted) toast(context, 'Is team ka roster lock hai — captain se rabta karen.');
        return;
      }
      // 081 CAP: refuse to join a full roster — the invite code
      // stays valid, but a full team takes no more members.
      final cap = teamRosterSize(team);
      final memberCount = (await SupaDb.getList('team_members', eqCol: 'team_id', eqVal: SupaDb.strOf(team['id']))).length;
      if (teamIsFull(memberCount, cap)) {
        if (mounted) toast(context, 'Team full hai ($memberCount/$cap) — koi khali jagah nahi.');
        return;
      }
      final profile = await SupaDb.getProfile(widget.uid);
      await SupaDb.client.from('team_members').insert({
        'team_id': team['id'],
        'firebase_uid': widget.uid,
        'user_name': SupaDb.strOf(profile['displayName'], 'User'),
        'role': 'member',
      });
      if (mounted) toast(context, 'Team join ho gayi!');
      await _load(refresh: true);
    } catch (e) {
      // Reachable failure path (direct client insert throws): drive
      // the shared ErrorState/OfflineState, not just a toast.
      if (!mounted) return;
      if (proTableMissing(e)) {
        setState(() => _pending = true);
        toast(context, 'Backend pending — migration 008 chalani hogi.');
      } else if (_isOfflineError(e)) {
        setState(() => _error = 'offline');
      } else {
        setState(() => _error = 'Join failed: $e');
      }
    }
  }

  /// PHASE E (E7) — the Community tab's ONE STRIP (replaces the
  /// FIX 12 G11 three-pill row + _toggleBtn, deleted): one rounded
  /// translucent container holding all three segments, modelled on
  /// the My Matches _tabsBar (one rounded container, three tabs,
  /// selected = gold pill). The strip fill is the shared card
  /// decoration (translucent purple, same token as every card),
  /// so the poster shows through it like any other card.
  ///
  /// Community and Squad are the two list tabs (selected = gold
  /// pill, dark text; unselected = muted text). Create is an
  /// ACTION, not a tab (gold text, no pill) — it opens the create
  /// form via _openCreate. All three labels render FULL at 14px,
  /// text-only, no ellipsis: at 360px each segment gets ~106px
  /// and the longest label ("Community", ~70px at 14px w900)
  /// fits with room to spare.
  Widget _communityTabStrip() {
    return Container(
      key: const ValueKey('communityTabStrip'),
      padding: const EdgeInsets.all(kSpace4),
      decoration: cardDecoration(radius: 28),
      child: Row(
        children: [
          _stripSegment(
            label: kCommunityTabLabel,
            selected: _showCommunities,
            onTap: () => _selectTab(true),
          ),
          _stripSegment(
            label: kSquadTabLabel,
            selected: !_showCommunities,
            onTap: () => _selectTab(false),
          ),
          _stripSegment(
            label: kCreateTabLabel,
            selected: false,
            isAction: true,
            onTap: _openCreate,
          ),
        ],
      ),
    );
  }

  /// One segment of [_communityTabStrip]: an equal third of the
  /// strip. PHASE E (E24, CORRECTED 2026-11-24): the selected
  /// tab is the gold-gradient pill again (Sameer: "click pe
  /// yellow hona chahiye"); the REST segments stay transparent
  /// (the strip's own card fill shows through) — never black.
  /// The Create action gets gold text and never a border. Text-
  /// only, single line, no ellipsis — the label must always
  /// fit whole.
  Widget _stripSegment(
      {required String label,
      required bool selected,
      bool isAction = false,
      required VoidCallback onTap}) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: selected ? kGoldGradient : null),
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            style: TextStyle(
                color: selected
                    ? const Color(0xFF0A0A0F)
                    : isAction
                        ? kGold
                        : kTextMuted,
                fontWeight: FontWeight.w900,
                fontSize: 14),
          ),
        ),
      ),
    );
  }

  /// FIX 12 G15 (STAN-style list, 2026-11-23 user order): the
  /// Community tab's list — ALL communities as STAN rows (round
  /// photo, name, member count, gold arrow), ordered by member
  /// count DESCENDING, the top 5 in a "Top Communities" section
  /// (plain rows while searching). NO banner grid — the user
  /// cancelled it. Paged 50 with infinite scroll +
  /// pull-to-refresh + the header search field. Tapping a row
  /// opens its detail page. Same data path as the old
  /// CommunitiesListPage (listCommunities +
  /// communitiesBackendReady) — the tab replaces that page as
  /// the entry point, the page itself stays for deep links.
  /// REDESIGN S6 (2026-11-23): F1 tokens for padding, gaps and
  /// radii; the load-more spinner is the F2 gold loading
  /// indicator. The STAN rows themselves are group S8's — this
  /// page only lays them out, it does not restyle them.
  Widget _buildCommunityList() {
    if (_commLoading && _communities.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(kSpace16),
        children: const [
          LoadingSkeleton(height: 118),
          SizedBox(height: kSpace8),
          LoadingSkeleton(height: 118),
        ],
      );
    }
    // FIX 12 G15: section slots — "Top Communities" (top 5 by
    // member count) + "All Communities" when browsing; plain rows
    // when searching.
    final slots = communityListSlots(_communities, searching: _commQuery.isNotEmpty);
    return RefreshIndicator(
      onRefresh: () => _loadCommunities(),
      color: kGold,
      child: ListView.builder(
        controller: _commScroll,
        padding: const EdgeInsets.fromLTRB(kSpace16, 0, kSpace16, kSpace16),
        // 1 header slot (spacing + the not-ready banner, when shown)
        // + list slots (or the empty state) + 1 load-more spinner.
        itemCount: 1 + (_communities.isEmpty ? 1 : slots.length) + (_commLoadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == 0) {
            // Top spacing + the backend-not-ready banner (same text
            // as the old list page — the 073 migration is the
            // backend lane's job, this page never invents data).
            return Column(
              children: [
                const SizedBox(height: kSpace4),
                if (!_commReady)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(kSpace12),
                    margin: const EdgeInsets.only(bottom: kSpace12),
                    decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(kRadiusChip), border: Border.all(color: kGold)),
                    child: Text('Communities backend abhi online nahi hua (migration 073 pending) — list jald aa jayegi.', style: kStyleMeta),
                  ),
              ],
            );
          }
          final slotIndex = index - 1;
          if (_communities.isEmpty) {
            return EmptyState(
              icon: Icons.groups,
              title: _commQuery.isEmpty ? 'Abhi koi community nahi' : 'Koi community nahi mili',
              body: _commQuery.isEmpty ? 'Pehla group aap banayen — naam, photo aur description dein, phir Community ya Squad chunen.' : 'Is naam ki koi community nahi hai.',
              actionLabel: _commQuery.isEmpty ? 'CREATE' : null,
              onAction: _commQuery.isEmpty ? _openCreateCommunity : null,
            );
          }
          if (slotIndex >= slots.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: kSpace16),
              child: Center(child: ArenaLoadingIndicator()),
            );
          }
          final slot = slots[slotIndex];
          if (slot.isHeader) {
            return CommunitySectionHeader(title: slot.header, star: slot.header == 'Top Communities');
          }
          final c = slot.community!;
          return Padding(
            padding: const EdgeInsets.only(bottom: kSpace12),
            child: StanCommunityRow(
              community: c,
              // FIX 23 item 19 — Follow (direct join); hidden
              // after a successful follow.
              showFollow:
                  !_commFollowedIds.contains(SupaDb.strOf(c['id'])),
              onFollow: () => unawaited(_followFromCard(c)),
              onOpen: () => _openCommunity(c),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Mockup #3: ARENA HUB lockup top-right.
      appBar: AppBar(
        title: _mockAppBarTitle('MY TEAM'),
        centerTitle: true,
        actions: const [Padding(padding: EdgeInsets.only(right: 12), child: Center(child: ArenaLogo(crownSize: 28, fontSize: 13)))],
      ),
      // Mockup #3: bottom nav with My Matches active — only when
      // pushed as a route. Embedded as the nav Community tab the
      // shell already draws the bottom nav; a second one here would
      // stack underneath it.
      bottomNavigationBar: widget.embedded ? null : const MyTeamBottomNav(),
      // REDESIGN S6 (2026-11-23): the F2 screen background (deep
      // black gradient + the subtle radial golden light, guide §3)
      // wraps every body state — loading, pending, offline, error
      // and the lists alike.
      body: ArenaBackground(
        showGoldenGlow: true,
        child: _busy
          ? ListView(
              padding: const EdgeInsets.all(kSpace16),
              children: const [
                LoadingSkeleton(height: 48),
                SizedBox(height: kSpace12),
                LoadingSkeleton(height: 118),
                SizedBox(height: kSpace8),
                LoadingSkeleton(height: 118),
              ],
            )
          : _pending
              ? ListView(padding: const EdgeInsets.all(16), children: [proPendingCard('Teams')])
              : _error == 'offline'
                  ? Center(child: OfflineState(message: 'Check your internet connection and try again.', onRetry: () => _load()))
                  : _error != null
                      ? Center(child: ErrorState(message: _error!, onRetry: () => _load()))
                      : Column(
                          children: [
                            // STICKY HEADER (2026-11-22, redesigned FIX 11
                            // 2026-11-23, three-button row FIX 12 G11):
                            // the top row + the tab's controls stay
                            // pinned at the top — only the lists scroll
                            // (user order: the controls scrolled away
                            // with the list before).
                            Padding(
                              padding: const EdgeInsets.fromLTRB(kSpace16, kSpace16, kSpace16, 0),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (_refreshing) ...[LinearProgressIndicator(color: kGold, backgroundColor: kField), const SizedBox(height: kSpace12)],
                                  // PHASE E (E7) — ONE STRIP (Sameer
                                  // 2026-11-24, v2023 phone feedback:
                                  // the three separate pills truncated
                                  // "Community"/"Create" to
                                  // "Communi..."/"Crea..." on a 360px
                                  // phone). ONE rounded translucent
                                  // strip, modelled on the My Matches
                                  // _tabsBar (one rounded container,
                                  // three segments, selected = gold
                                  // pill). Community and Squad are the
                                  // two list tabs; Create STAYS an
                                  // action (opens the create form via
                                  // _openCreate — it is not a tab).
                                  // All three labels render FULL at
                                  // 14px, text-only (no icons — the
                                  // full names come first), no
                                  // ellipsis anywhere. Replaces the
                                  // FIX 12 G11 three-pill row + the
                                  // FIX 23 item 18 flex 4/3/3 split.
                                  _AnimatedCta(child: _communityTabStrip()),
                                  const SizedBox(height: kSpace12),
                                  if (!_showCommunities)
                                    // SQUAD SIDE: Join by Code stays
                                    // here (full width now that Create
                                    // lives in the top row).
                                    // REDESIGN S6 (2026-11-23): the F2
                                    // outlined button (gold border +
                                    // gold text), full width, same
                                    // w900 16px label as the top row.
                                    _AnimatedCta(
                                      child: SizedBox(
                                        width: double.infinity,
                                        child: ArenaOutlinedButton(
                                          onPressed: _joinByCode,
                                          child: Text('Join by Code', style: TextStyle(color: kGold, fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: 0.5)),
                                        ),
                                      ),
                                    ),
                                  if (_showCommunities) ...[
                                    // COMMUNITY SIDE: the name search
                                    // field only — Create lives in the
                                    // top row now (same look as the old
                                    // list page).
                                    // REDESIGN S6 (2026-11-23): F1
                                    // tokens for the text, hint and
                                    // radii. It stays a plain TextField
                                    // (not the F2 ArenaTextField) —
                                    // the Fix 12 G11/G15 neighbour
                                    // tests pin find.byType(TextField)
                                    // on this side.
                                    // FIX 23 item 29: card look via
                                    // CardFieldShell. Still a plain
                                    // TextField (G11/G15 pin it).
                                    CardFieldShell(
                                      child: TextField(
                                      controller: _commSearchCtrl,
                                      onChanged: _onCommSearchChanged,
                                      style: kStyleBody,
                                      decoration: InputDecoration(
                                        hintText: 'Community dhoonden...',
                                        hintStyle: kStyleMeta,
                                        prefixIcon: Icon(Icons.search, color: kGold),
                                        contentPadding: const EdgeInsets.symmetric(horizontal: kSpace16, vertical: kSpace12),
                                        border: const OutlineInputBorder(borderSide: BorderSide.none),
                                        enabledBorder: const OutlineInputBorder(borderSide: BorderSide.none),
                                        focusedBorder: const OutlineInputBorder(borderSide: BorderSide.none),
                                      ),
                                    ),
                                    ),
                                  ],
                                  const SizedBox(height: kSpace16),
                                ],
                              ),
                            ),
                            Expanded(
                              child: _showCommunities
                                  ? _buildCommunityList()
                                  : ListView(
                                padding: const EdgeInsets.fromLTRB(kSpace16, 0, kSpace16, kSpace16),
                                children: [
                            // TEAM-INVITE FIX (2026-11-21): pending
                            // invitations, above the team list — the
                            // invitee's second discovery place. A
                            // user with no team yet still sees their
                            // invites here (the old page only ever
                            // listed teams they had already joined).
                            if (_invites.isNotEmpty) ...[
                              Row(children: [
                                Icon(Icons.mail_outline, color: kGold, size: 18),
                                const SizedBox(width: kSpace8),
                                Text('TEAM INVITATIONS', style: kStyleBody.copyWith(color: kGold, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                              ]),
                              const SizedBox(height: kSpace8),
                              for (final inv in _invites) _inviteCard(inv),
                              const SizedBox(height: kSpace4),
                            ],
                            if (_mine.isEmpty)
                              const EmptyState(
                                icon: Icons.group_outlined,
                                title: 'No team yet',
                                body: 'Aap kisi team me nahi hain. Team banayen ya invite code se join karen.',
                              ),
                            for (final t in _mine)
                              Padding(
                                padding: const EdgeInsets.only(bottom: kSpace12),
                                // v2016 FIX 12 (user order 2026-11-22):
                                // COMPACT + MODERN redesign — the old
                                // card was ~200dp tall with loose
                                // padding and full-size TextButtons, so
                                // barely 1.5 cards fit per screen. Now:
                                // tighter padding (12/10), smaller logo
                                // (40) + name (19), members as a gold
                                // chip, invite code as a tap-to-copy
                                // dark chip, and two compact outlined
                                // action buttons. Same info, same
                                // gold/black theme, ~35dp shorter.
                                // FIX 11 (2026-11-23): the WHOLE card is
                                // tappable — it opens the team chat
                                // (same as 'Members & Chat'); the
                                // buttons below stay for discoverability.
                                // FIX 12 G5: no type pill — every team
                                // is just a team (CLAN pill removed).
                                // REDESIGN S6 (2026-11-23): the card is
                                // already a MockupCard (global card
                                // rule — gradient fill + two short gold
                                // shines, no full border); the insides
                                // read F1 tokens now (card radius,
                                // spacing, label/meta styles) and the
                                // gold literal is the kGold token.
                                child: InkWell(
                                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TeamChatPage(team: t, uid: widget.uid, navIndex: widget.embedded ? 4 : 2))),
                                  borderRadius: BorderRadius.circular(kRadiusCard),
                                  child: MyTeamCard(
                                  padding: const EdgeInsets.all(kSpace12),
                                  radius: kRadiusCard,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(children: [
                                        // FIX 7: the uploaded team
                                        // photo shows here (server
                                        // value first, device-local
                                        // fallback); no photo yet =
                                        // the gold shield, as before.
                                        // No upload affordance on the
                                        // list row — the captain
                                        // changes the photo on the
                                        // detail page.
                                        TeamPhotoBadge(
                                          photoUrl: resolveTeamPhotoUrl(serverUrl: SupaDb.strOf(t['photo_url']), localUrl: _localPhotos[SupaDb.strOf(t['id'])]),
                                          isCaptain: false,
                                          size: 40,
                                        ),
                                        const SizedBox(width: kSpace8),
                                        Expanded(
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              SupaDb.strOf(t['name']),
                                              style: TextStyle(color: kGold, fontStyle: FontStyle.italic, fontWeight: FontWeight.w900, fontSize: 19),
                                            ),
                                          ),
                                        ),
                                      ]),
                                      const SizedBox(height: kSpace8),
                                      Row(children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: kSpace8, vertical: kSpace4),
                                          decoration: BoxDecoration(color: kGold.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(kRadiusChip)),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.group, color: kGold, size: 13),
                                              const SizedBox(width: kSpace4),
                                              Text(membersStatLabel(_memberCounts[SupaDb.strOf(t['id'])] ?? 0, teamRosterSize(t)), style: kStyleLabel.copyWith(color: kGold, fontWeight: FontWeight.bold)),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: kSpace8),
                                        Expanded(child: Text('Tag: ${SupaDb.strOf(t['tag'], '—')}  •  Captain: ${SupaDb.strOf(t['captain_name'])}', style: kStyleLabel.copyWith(color: kMuted), overflow: TextOverflow.ellipsis)),
                                      ]),
                                      const SizedBox(height: kSpace8),
                                      InkWell(
                                        onTap: () {
                                          Clipboard.setData(ClipboardData(text: SupaDb.strOf(t['invite_code'])));
                                          toast(context, 'Invite code copy ho gaya!');
                                        },
                                        borderRadius: BorderRadius.circular(kSpace8),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: kSpace8, vertical: kSpace4),
                                          decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(kSpace8)),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text('Invite code: ', style: kStyleLabel.copyWith(color: kMuted)),
                                              Text(SupaDb.strOf(t['invite_code'], '—'), style: kStyleMeta.copyWith(color: kText, fontWeight: FontWeight.bold)),
                                              const SizedBox(width: kSpace4),
                                              Icon(Icons.copy, color: kGold, size: 14),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: kSpace8),
                                      Row(children: [
                                        // v2016 FIX 13: 'Members & Chat'
                                        // opens the CHAT directly now —
                                        // the detail page moved into the
                                        // chat's Team settings menu.
                                        Expanded(child: _TeamCardActionButton(icon: Icons.chat_bubble, label: 'Members & Chat', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TeamChatPage(team: t, uid: widget.uid, navIndex: widget.embedded ? 4 : 2))))),
                                        const SizedBox(width: kSpace8),
                                        Expanded(child: _TeamCardActionButton(icon: Icons.sports_esports, label: 'Clan War', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CreateTournamentPage(uid: widget.uid, clanWarTeam: t))))),
                                      ]),
                                    ],
                                  ),
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

/// FIX 10 (2026-11-21, user order from the My Team screenshot
/// 1000049118_47_39rz.jpg): the roster's "UID:" line is the IN-GAME
/// player ID (profiles.game_uid) — NEVER the Firebase UID. The old
/// _memberCard fell back to the Firebase UID when a member had no
/// game_uid saved, so both roster rows showed Firebase UIDs.
/// Pure — unit-tested in test/roster_game_uid_test.dart.
String rosterGameUid(Map<String, dynamic> profile) {
  return SupaDb.strOf(profile['game_uid'], SupaDb.strOf(profile['gameUid'])).trim();
}

/// FIX 10: the full roster UID line for one member profile.
/// `UID: ` plus the saved game UID when one is saved, otherwise
/// the [emptyLabel] placeholder — the Firebase UID is never shown,
/// so there is deliberately NO uid parameter here.
String rosterUidLine(Map<String, dynamic> profile, {String emptyLabel = 'Game UID not set'}) {
  final g = rosterGameUid(profile);
  if (g.isEmpty) return emptyLabel;
  // Privacy (Account Security toggle "Show Game ID"): when the member
  // turned it OFF, the roster hides the game UID instead of showing
  // it (audit fix 2026-11-21 — the toggle was stored but never read).
  // Absent privacy data means visible (the toggle defaults to on).
  final privacy = SupaDb.asMap(profile['privacy']);
  if (privacy['show_game_id'] == false) return 'Game UID hidden';
  return 'UID: $g';
}

/// FIX 10: Edit Profile (CreateProfilePage) save patch, extracted
/// pure so the save path is unit-testable. game_uid rides in BOTH
/// the full patch and the minimal retry patch — a failed full
/// update must never silently drop the game UID. [minimal] omits
/// only country / favourite game / bio (the old draft-017 columns;
/// REST probe 2026-11-21 confirmed all of them live, so the
/// minimal retry is now just a safety net, not the expected path).
/// Empty values are omitted, never written as empty strings.
Map<String, dynamic> editProfilePatch({
  required String displayName,
  String username = '',
  String playerId = '',
  String? photoUrl,
  String? country,
  String? game,
  String bio = '',
  String ign = '',
  bool hasIgnColumn = false,
  bool minimal = false,
}) {
  return <String, dynamic>{
    'display_name': displayName.trim(),
    if (username.trim().isNotEmpty) 'username': username.trim(),
    if (playerId.trim().isNotEmpty) 'game_uid': playerId.trim(),
    if (photoUrl != null && photoUrl.isNotEmpty) 'photo_url': photoUrl,
    if (!minimal && country != null) 'country': country,
    if (!minimal && game != null) 'favorite_game': game,
    if (!minimal && bio.trim().isNotEmpty) 'bio': bio.trim(),
    if (hasIgnColumn && ign.trim().isNotEmpty) 'in_game_name': ign.trim(),
  };
}

class TeamDetailPage extends StatefulWidget {
  final Map<String, dynamic> team;
  final String uid;
  // NAV HIGHLIGHT (2026-11-22): which shell tab this page belongs
  // to — 2 = My Matches (default, mockup #3), 4 = Community (when
  // opened from the nav Community tab's embedded teams list).
  // Passed to MyTeamBottomNav + through to TeamChatPage so the
  // highlight stays correct down the whole chain.
  final int navIndex;
  const TeamDetailPage({super.key, required this.team, required this.uid, this.navIndex = 2});
  @override
  State<TeamDetailPage> createState() => _TeamDetailPageState();
}

class _TeamDetailPageState extends State<TeamDetailPage> {
  // Mutable copy of the passed team row: Edit Team updates this so
  // the header refreshes without a round-trip.
  late Map<String, dynamic> _team;
  List<Map<String, dynamic>> _members = [];
  Map<String, Map<String, dynamic>> _presence = {};
  // Member profiles for avatars + in-game IDs (mockup #3 roster shows
  // each member's photo and UID).
  Map<String, Map<String, dynamic>> _profiles = {};
  // Real matches played by the current roster (sum of each member's
  // match_history rows). Null while loading / on failure.
  int? _teamMatches;
  bool _locked = false;
  bool _busy = true;
  String? _error;
  // FIX 7: device-local team photo URL (SharedPreferences fallback
  // until the backend adds `teams.photo_url`) + upload busy flag.
  String _localPhotoUrl = '';
  bool _photoBusy = false;
  // 081: member ids with a position save in flight (picker
  // disabled until it lands — no double-tap double-write).
  final Set<String> _savingPositions = {};
  // PRESENCE REFRESH (2026-11-22): the roster's ONLINE/OFFLINE +
  // last-seen used to freeze at page-load time (one-shot
  // getPresenceMap in _load) — a member going offline while this
  // page was open stayed "ONLINE" until re-entry. A 30s timer
  // re-reads presence for the current roster (same rhythm as the
  // heartbeat) so the dots + last-seen stay live.
  Timer? _presenceTimer;
  bool get _isCaptain => SupaDb.strOf(_team['captain_uid']) == widget.uid;
  // CAPTAIN GATE (2026-11-22, Edit Team / photo bugs): a member
  // sees a dead EDIT TEAM button and no camera icon with no
  // explanation — it looks broken. The note/toast name the captain
  // so the member can see WHO can edit (Sameer's team is captained
  // by his other account — that, not any type code, is why
  // the team showed no photo option: the gate is captain-only,
  // and no code anywhere treats teams differently).
  String get _captainSuffix {
    final name = SupaDb.strOf(_team['captain_name']);
    return name.isEmpty ? '' : ' — captain: $name';
  }
  // FIX 7: photo to display — server `photo_url` first (once the
  // backend column exists), device-local fallback second, shield
  // when neither exists.
  String get _teamPhotoUrl => resolveTeamPhotoUrl(serverUrl: SupaDb.strOf(_team['photo_url']), localUrl: _localPhotoUrl);

  @override
  void initState() {
    super.initState();
    _team = Map<String, dynamic>.from(widget.team);
    _locked = _team['roster_locked'] == true;
    _load();
    // PRESENCE REFRESH (2026-11-22): 30s re-read (see _presenceTimer).
    _presenceTimer = Timer.periodic(const Duration(seconds: 30), (_) => _refreshPresence());
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();
    super.dispose();
  }

  /// Re-reads presence for the current roster only (never a global
  /// online list) and rebuilds so ONLINE/OFFLINE + last-seen text
  /// stay live while the page is open. Best-effort: a failed read
  /// keeps the last good map, never blanks the roster.
  Future<void> _refreshPresence() async {
    if (!mounted || _members.isEmpty) return;
    final uids = _members.map((m) => SupaDb.strOf(m['firebase_uid'])).where((s) => s.isNotEmpty).toList();
    if (uids.isEmpty) return;
    final presence = await SupaDb.getPresenceMap(uids);
    if (!mounted) return;
    setState(() => _presence = presence);
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final rows = await SupaDb.getList('team_members', eqCol: 'team_id', eqVal: SupaDb.strOf(_team['id']));
      final uids = rows.map((m) => SupaDb.strOf(m['firebase_uid'])).where((s) => s.isNotEmpty).toList();
      // 081: refetch the team row so team_rank / max_members
      // (written server-side by recompute_team_ranks / the admin)
      // are fresh, not the stale copy passed in from the list page.
      final teamRow = await SupaDb.getRow('teams', 'id', SupaDb.strOf(_team['id']));
      // FIX 7: device-local photo for this team (never throws).
      final localPhoto = await loadTeamPhotoLocal(SupaDb.strOf(_team['id']));
      // Presence rows only for this team's own member UIDs (same
      // pattern as the Status sheet — never a global online list).
      final presence = await SupaDb.getPresenceMap(uids);
      final profiles = await SupaDb.getProfilesMap(uids);
      // Team matches = real match_history rows of the current roster.
      // A team has no match table of its own (same honesty rule as
      // TeamHistoryPage); a failure here leaves the count unknown
      // ("—") instead of a fake 0.
      int? matches;
      try {
        var total = 0;
        for (final uid in uids) {
          total += (await SupaDb.getMatchHistory(uid)).length;
        }
        matches = total;
      } catch (_) {
        matches = null;
      }
      if (mounted) {
        setState(() {
          _members = rows;
          _presence = presence;
          _profiles = profiles;
          _teamMatches = matches;
          _localPhotoUrl = localPhoto;
          if (teamRow.isNotEmpty) _team = {..._team, ...teamRow};
        });
      }
      // TOURNAMENT CHAT REMOVED (2026-11-22 user order): the
      // tournaments fetch for the My Team "TOURNAMENT CHAT" section
      // went with the section itself — no dead fetch is kept.
    } catch (e) {
      // Defensive only: getList/getPresenceMap swallow read errors.
      if (mounted) setState(() => _error = 'Members load nahi ho sake: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleLock() async {
    try {
      await SupaDb.client.from('teams').update({'roster_locked': !_locked}).eq('id', SupaDb.strOf(_team['id']));
      if (mounted) setState(() => _locked = !_locked);
      if (mounted) toast(context, _locked ? 'Roster lock ON — naye members join nahi kar sakenge.' : 'Roster lock OFF.');
    } catch (e) {
      if (!mounted) return;
      if (_isOfflineError(e)) {
        setState(() => _error = 'offline');
      } else {
        setState(() => _error = 'Roster lock failed: $e');
      }
    }
  }

  /// Edit Team (captain only): name / tag / game update the real
  /// `teams` row. Invite code and captain are NOT editable here —
  /// the code is the team's join key, the captain changes only via
  /// admin.
  Future<void> _editTeam() async {
    final nameCtrl = TextEditingController(text: SupaDb.strOf(_team['name']));
    final tagCtrl = TextEditingController(text: SupaDb.strOf(_team['tag']));
    final gameCtrl = TextEditingController(text: SupaDb.strOf(_team['game']));
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text('Edit Team', style: TextStyle(color: kGold)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              field(controller: nameCtrl, label: 'Team name'),
              field(controller: tagCtrl, label: 'Tag (e.g. PRO)'),
              field(controller: gameCtrl, label: 'Game'),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel', style: TextStyle(color: kMuted))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text('Save', style: TextStyle(color: kGold))),
        ],
      ),
    );
    if (ok != true || nameCtrl.text.trim().isEmpty) return;
    try {
      // SAVE VERIFICATION (2026-11-22, Edit Team bug): a bare
      // .update() returns success even when the row is NOT written
      // (RLS deny / no match = 0 rows, no error) — the old code
      // then showed a false "Team update ho gayi!" and a local-only
      // name that reverted on the next load. .select('id') returns
      // the written rows: empty means the save did NOT land, so the
      // local state is left untouched and the user gets an honest
      // failure instead of a fake success. (Same pattern as the
      // tournament_results dispute update.)
      final updated = await SupaDb.client.from('teams').update({
        'name': nameCtrl.text.trim(),
        'tag': tagCtrl.text.trim(),
        'game': gameCtrl.text.trim(),
      }).eq('id', SupaDb.strOf(_team['id'])).select('id');
      if (updated.isEmpty) {
        if (mounted) toast(context, 'Team update nahi ho saki — dobara koshish karein.');
        return;
      }
      if (mounted) {
        setState(() {
          _team['name'] = nameCtrl.text.trim();
          _team['tag'] = tagCtrl.text.trim();
          _team['game'] = gameCtrl.text.trim();
        });
        toast(context, 'Team update ho gayi!');
      }
    } catch (e) {
      if (!mounted) return;
      if (_isOfflineError(e)) {
        setState(() => _error = 'offline');
      } else {
        toast(context, 'Edit failed: $e');
      }
    }
  }

  /// FIX 7 (2026-11-21, captain only): set/change the team photo.
  /// Same pick + upload path as the profile photo
  /// (ProfilePage._changePhoto): gallery pick compressed to
  /// 85% / 1024 px (fast on a slow connection), FilePicker fallback
  /// if the ImagePicker plugin is missing at runtime, ImgBB upload.
  /// The URL is saved device-locally (SharedPreferences, keyed by
  /// team id) AND written to `teams.photo_url` on the server on a
  /// best-effort basis — the column does not exist yet, so that
  /// write is expected to fail until the backend adds it (BACKEND
  /// ADDENDUM); the failure is swallowed and the local copy still
  /// shows the photo on this device. Once the column exists, the
  /// same code persists server-wide with no app change. Plain
  /// failure toast only — raw exception text never reaches the user.
  Future<void> _changeTeamPhoto() async {
    if (!_isCaptain || _photoBusy) return;
    try {
      File? file;
      try {
        final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 1024);
        if (picked != null) file = File(picked.path);
      } on MissingPluginException {
        final res = await FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: false);
        if (res != null && res.files.isNotEmpty) {
          final path = res.files.single.path;
          if (path != null && path.isNotEmpty) file = File(path);
        }
      }
      if (file == null) return;
      if (!mounted) return;
      setState(() => _photoBusy = true);
      toast(context, tr('Uploading photo…', 'Photo upload ho rahi hai…'));
      final url = await ImgbbService.uploadImage(file);
      if (url.isEmpty) throw Exception('Upload returned an empty URL.');
      // Local first (guaranteed to show on this device), then the
      // server write on a best-effort basis (see doc above).
      await saveTeamPhotoLocal(SupaDb.strOf(_team['id']), url);
      try {
        await SupaDb.client.from('teams').update({'photo_url': url}).eq('id', SupaDb.strOf(_team['id']));
      } catch (_) {
        // Expected until the backend adds `teams.photo_url` — the
        // local copy already covers this device.
      }
      if (!mounted) return;
      setState(() {
        _team['photo_url'] = url;
        _localPhotoUrl = url;
      });
      if (mounted) toast(context, tr('Team photo updated.', 'Team photo lag gayi!'));
    } catch (e) {
      if (mounted) toast(context, tr('Photo upload failed — please try again', 'Photo upload nahi ho saki — dobara koshish karein'));
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  void _copyInviteCode() {
    Clipboard.setData(ClipboardData(text: SupaDb.strOf(_team['invite_code'])));
    toast(context, 'Invite code copy ho gaya!');
  }

  /// Mockup #3 "INVITE PLAYER +": sends a REAL in-app team invitation
  /// (027). Enter a @username, look it up, insert the
  /// team_invitations row + the invitee's notification — the invitee
  /// gets Accept/Decline on their Notifications page (mockup #22).
  /// Only a captain or member may invite (RLS enforces the same rule
  /// server-side; this gate just fails fast with a clear message).
  /// The old share-code action is kept as a secondary link in the
  /// same dialog — the invite code remains the team's join key.
  Future<void> _invitePlayer() async {
    final isMember = _isCaptain || _members.any((m) => SupaDb.strOf(m['firebase_uid']) == widget.uid);
    if (!isMember) {
      toast(context, 'Sirf team members invite kar sakte hain.');
      return;
    }
    // 081 CAP: a full roster takes no more invites — fail fast
    // before opening the dialog (the send step re-checks with a
    // fresh count, in case the roster filled since the page loaded).
    final cap = teamRosterSize(_team);
    if (teamIsFull(_members.length, cap)) {
      toast(context, 'Team full hai (${_members.length}/$cap) — naye members join nahi kar sakte.');
      return;
    }
    final ctrl = TextEditingController();
    String? errorText;
    bool sending = false;
    final sent = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> send() async {
            final name = ctrl.text.trim().replaceFirst(RegExp(r'^@'), '');
            if (name.isEmpty) {
              setDialogState(() => errorText = 'Username likho (e.g. zehri5).');
              return;
            }
            setDialogState(() {
              sending = true;
              errorText = null;
            });
            final found = await SupaDb.findUserByUsername(name);
            if (found.isEmpty) {
              setDialogState(() {
                sending = false;
                errorText = 'Is username ka koi player nahi mila.';
              });
              return;
            }
            final inviteeUid = SupaDb.strOf(found['firebase_uid']);
            if (inviteeUid.isEmpty) {
              setDialogState(() {
                sending = false;
                errorText = 'Is player ka account nahi mila.';
              });
              return;
            }
            if (inviteeUid == widget.uid) {
              setDialogState(() {
                sending = false;
                errorText = 'Apne aap ko invite nahi kar sakte.';
              });
              return;
            }
            if (_members.any((m) => SupaDb.strOf(m['firebase_uid']) == inviteeUid)) {
              setDialogState(() {
                sending = false;
                errorText = 'Ye player pehle se team mein hai.';
              });
              return;
            }
            // 081 CAP (fresh count — the roster may have filled
            // since the page loaded; the entry check above only
            // saw the state at dialog-open time).
            final sendCap = teamRosterSize(_team);
            if (sendCap != null) {
              final freshCount = (await SupaDb.getList('team_members', eqCol: 'team_id', eqVal: SupaDb.strOf(_team['id']))).length;
              if (teamIsFull(freshCount, sendCap)) {
                setDialogState(() {
                  sending = false;
                  errorText = 'Team full hai ($freshCount/$sendCap) — naye members join nahi kar sakte.';
                });
                return;
              }
            }
            final res = await SupaDb.sendTeamInvite(
              teamId: SupaDb.strOf(_team['id']),
              teamName: SupaDb.strOf(_team['name'], 'Your team'),
              invitedUid: inviteeUid,
              inviterUid: widget.uid,
              inviteCode: SupaDb.strOf(_team['invite_code']),
            );
            if (!context.mounted) return;
            if (res['ok'] == true) {
              Navigator.pop(context, true);
            } else {
              setDialogState(() {
                sending = false;
                errorText = SupaDb.strOf(res['error'], 'Invite nahi bheji ja saki.');
              });
            }
          }

          return AlertDialog(
            backgroundColor: kCardPurpleMid,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
            title: Text('Invite Player', style: TextStyle(color: kGold)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Player ka username likho — usko app mein Team Invitation milegi, Accept/Decline ke saath.', style: TextStyle(color: kMuted, fontSize: 13)),
                  const SizedBox(height: 12),
                  field(controller: ctrl, label: 'Username (e.g. zehri5)'),
                  if (errorText != null) ...[
                    const SizedBox(height: 8),
                    Text(errorText!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
                  ],
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context, false);
                      Share.share('Join my Arena Hub team "${SupaDb.strOf(_team['name'])}"! Invite code: ${SupaDb.strOf(_team['invite_code'])}');
                    },
                    child: Text('Invite code share karo', style: TextStyle(color: kGold, fontSize: 13)),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: sending ? null : () => Navigator.pop(context, false), child: Text('Cancel', style: TextStyle(color: kMuted))),
              TextButton(
                onPressed: sending ? null : send,
                child: sending
                    ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: kGold))
                    : Text('Send Invite', style: TextStyle(color: kGold)),
              ),
            ],
          );
        },
      ),
    );
    if (sent == true && mounted) toast(context, 'Invitation bhej di!');
  }

  Widget _memberCard(Map<String, dynamic> m) {
    final memberUid = SupaDb.strOf(m['firebase_uid']);
    final role = SupaDb.strOf(m['role'], 'member');
    final isCaptain = role == 'captain';
    final pres = _presence[memberUid] ?? {};
    // ONE rule, same as the Status sheet (SupaDb.presenceIsOnline):
    // online = last_seen within the last 2 minutes.
    final online = SupaDb.presenceIsOnline(pres);
    final profile = _profiles[memberUid] ?? {};
    final photoUrl = SupaDb.strOf(profile['photo_url']);
    // FIX 10 (2026-11-21): mockup #3 "UID:" is the in-game player
    // ID (profiles.game_uid). When a member has no game_uid saved
    // the line shows a placeholder — NEVER the Firebase UID (the
    // old fallback leaked Firebase UIDs onto the roster).
    // (rosterUidLine below reads the game UID from [profile].)
    // 081 POSITIONS (migration 081, team_members.position):
    // the captain shows the mockup's "IGL / Leader"; a member
    // shows their stored position (IGL / Assaulter / Support /
    // Entry Fragger) when the captain set one, else their real
    // role ('Member'). Unset is never faked as a position.
    final position = SupaDb.strOf(m['position']);
    final roleText = isCaptain ? 'IGL / Leader' : (isValidTeamPosition(position) ? position : role[0].toUpperCase() + role.substring(1));
    final name = SupaDb.strOf(m['user_name']);
    // Mockup #3 roster row — the layout lives in TeamMemberCard
    // (PRINTER-COPY 2026-11-21, measured); this adapter only
    // resolves the member's role / presence / profile first.
    final card = TeamMemberCard(
      name: name,
      uidLine: rosterUidLine(profile, emptyLabel: tr('Game UID not set', 'Game UID set nahi hai')),
      roleText: roleText,
      photoUrl: photoUrl,
      isCaptain: isCaptain,
      online: online,
      // LAST SEEN (2026-11-22): the member's real last_seen from
      // the presence row (0 when the member has no presence row).
      lastSeenMs: SupaDb.parseTs(pres['last_seen']),
    );
    // Captain-only position picker (081): the captain sets each
    // member's position below their row; the captain's own role
    // is fixed as IGL / Leader, so no picker on that row.
    if (!_isCaptain || isCaptain) return card;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        card,
        _positionPicker(m, position),
        const SizedBox(height: 8),
      ],
    );
  }

  /// 081: captain-only position picker for one member row.
  /// Writes team_members.position directly (permissive UPDATE
  /// policy in 081 §4 — the app has no Supabase Auth session, so
  /// the captain-only gate lives here, not in RLS). 'No position'
  /// clears it back to NULL.
  Widget _positionPicker(Map<String, dynamic> m, String current) {
    final memberId = SupaDb.strOf(m['id']);
    final busy = _savingPositions.contains(memberId);
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4, top: 2),
      child: Row(
        children: [
          Icon(Icons.sports_esports, color: kGold, size: 16),
          const SizedBox(width: 6),
          Text('Position', style: TextStyle(color: kMuted, fontSize: 12)),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                value: isValidTeamPosition(current) ? current : null,
                hint: Text('Set position', style: TextStyle(color: kMuted, fontSize: 13)),
                dropdownColor: kCard,
                isExpanded: true,
                style: TextStyle(color: kText, fontSize: 13),
                icon: busy
                    ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: kGold))
                    : Icon(Icons.arrow_drop_down, color: kGold),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('No position')),
                  for (final p in teamPositions) DropdownMenuItem<String?>(value: p, child: Text(p)),
                ],
                onChanged: busy ? null : (v) => _setPosition(m, v),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _setPosition(Map<String, dynamic> m, String? position) async {
    final memberId = SupaDb.strOf(m['id']);
    if (memberId.isEmpty) return;
    setState(() => _savingPositions.add(memberId));
    try {
      await SupaDb.client.from('team_members').update({'position': position}).eq('id', memberId);
      if (mounted) {
        setState(() {
          final i = _members.indexWhere((e) => SupaDb.strOf(e['id']) == memberId);
          if (i >= 0) _members[i] = {..._members[i], 'position': position};
        });
      }
    } catch (e) {
      if (mounted) toast(context, 'Position save nahi hui — dobara koshish karein.');
    } finally {
      if (mounted) setState(() => _savingPositions.remove(memberId));
    }
  }


  @override
  Widget build(BuildContext context) {
    // Mockup #3 "4/4": the roster cap for this team (null —
    // no cap: FIX 11 removed the Squad 4 default, FIX 12 G5 the
    // clan type) — drives the
    // stats row, the ROSTER header and the
    // honest empty slots below. (081: the cap now reads the real
    // teams.max_members column when it exists.)
    final cap = teamRosterSize(_team);
    return Scaffold(
      // Mockup #3: ARENA HUB lockup top-right.
      appBar: AppBar(
        title: _mockAppBarTitle('MY TEAM'),
        centerTitle: true,
        actions: const [Padding(padding: EdgeInsets.only(right: 12), child: Center(child: ArenaLogo(crownSize: 28, fontSize: 13)))],
      ),
      // Mockup #3: bottom nav — the highlight follows navIndex
      // (2 My Matches by default, 4 Community when opened from
      // the nav Community tab's teams list).
      bottomNavigationBar: MyTeamBottomNav(activeIndex: widget.navIndex),
      body: _busy
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: const [
                LoadingSkeleton(height: 96),
                SizedBox(height: 16),
                LoadingSkeleton(height: 64),
                SizedBox(height: 8),
                LoadingSkeleton(height: 64),
              ],
            )
          : _error == 'offline'
              ? Center(child: OfflineState(message: 'Check your internet connection and try again.', onRetry: _load))
              : _error != null
                  ? Center(child: ErrorState(message: _error!, onRetry: _load))
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        // Mockup #3 team header card (MockupCard:
                        // the 2-line shine, no full border — user
                        // correction 2026-11-20): shield icon, italic
                        // gold team name, stats row
                        // (real members N/max + real matches; Rank is
                        // the real teams.team_rank from 081 — "Rank —"
                        // while unranked, never a fake rank),
                        // EDIT TEAM / TEAM HISTORY buttons.
                        MockupCard(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                // FIX 7: uploaded team photo (server
                                // value first, device-local fallback)
                                // or the gold shield when none; the
                                // captain gets the camera affordance
                                // to set/change it. CAPTAIN GATE
                                // (2026-11-22): a member tapping the
                                // photo got NOTHING (no camera icon,
                                // no tap handler) — "click lagta hi
                                // nahi". The tap now explains why.
                                // onTap is null for the captain, so
                                // this detector never competes with
                                // the camera InkWell inside the badge.
                                GestureDetector(
                                  onTap: _isCaptain ? null : () => toast(context, 'Sirf captain team photo badal sakta hai$_captainSuffix.'),
                                  child: TeamPhotoBadge(
                                    photoUrl: _teamPhotoUrl,
                                    isCaptain: _isCaptain,
                                    onChangePhoto: _changeTeamPhoto,
                                    size: 52,
                                    busy: _photoBusy,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    SupaDb.strOf(_team['name']),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Color(0xFFFDC903), fontStyle: FontStyle.italic, fontWeight: FontWeight.w900, fontSize: 28),
                                  ),
                                ),
                              ]),
                              const SizedBox(height: 12),
                              // FIX 5a: this strip used to be kField
                              // (#10131A, near-black) — a big black
                              // slab in the middle of the team card,
                              // the main thing that made the card
                              // read as "black" in the user's
                              // screenshot. It now carries the same
                              // kCard gradient as the card itself, so
                              // the whole header reads as the proper
                              // light-grey card.
                              Container(
                                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                                // FIX 23 item 23: same purple fill
                                // as the card itself.
                                decoration: cardFillDecoration(radius: 12),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                        Icon(Icons.group, color: kGold, size: 18),
                                        const SizedBox(width: 4),
                                        // 081: "4/4" when the cap is
                                        // known (mockup #3), bare
                                        // count for a team.
                                        Text(cap == null ? '${_members.length}' : '${_members.length}/$cap', style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 16)),
                                        const SizedBox(width: 4),
                                        Text('Members', style: TextStyle(color: kMuted, fontSize: 12)),
                                      ]),
                                    ),
                                    Container(width: 1, height: 22, color: kBorder),
                                    Expanded(
                                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                        Icon(Icons.sports_esports, color: kGold, size: 18),
                                        const SizedBox(width: 4),
                                        Text(_teamMatches == null ? '—' : '$_teamMatches', style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 16)),
                                        const SizedBox(width: 4),
                                        Text('Matches', style: TextStyle(color: kMuted, fontSize: 12)),
                                      ]),
                                    ),
                                    Container(width: 1, height: 22, color: kBorder),
                                    Expanded(
                                      // 081: the real teams.team_rank
                                      // ("Rank #8"); "Rank —" while
                                      // unranked — never a fake rank.
                                      child: Text(teamRankLabel(_team['team_rank']), textAlign: TextAlign.center, style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 16)),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              // FIX 5b: extracted row — smaller font
                              // (13) + FittedBox, so both labels fit
                              // fully inside the card at 360dp.
                              TeamActionButtons(
                                isCaptain: _isCaptain,
                                onEdit: _editTeam,
                                onHistory: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TeamHistoryPage(team: _team, members: _members))),
                              ),
                              if (_isCaptain) ...[
                                const SizedBox(height: 8),
                                Center(
                                  child: TextButton(
                                    onPressed: _toggleLock,
                                    child: Text(_locked ? 'Roster lock ON — tap to unlock' : 'Roster lock OFF — tap to lock', style: TextStyle(color: kMuted, fontSize: 12)),
                                  ),
                                ),
                              ] else ...[
                                // CAPTAIN GATE (2026-11-22): the
                                // member's EDIT TEAM button is
                                // disabled with no explanation — it
                                // looks broken. This note says why
                                // and names the captain.
                                const SizedBox(height: 8),
                                Center(
                                  child: Text(
                                    'Sirf captain team edit kar sakta hai$_captainSuffix.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: kMuted, fontSize: 12),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        _goldBarHeader('INVITE PLAYERS'),
                        const SizedBox(height: 10),
                        // Mockup #3 invite card (MockupCard: the
                        // 2-line shine, no full border and no glow —
                        // user correction 2026-11-20): invite code +
                        // COPY + INVITE PLAYER + on ONE row. Compact
                        // buttons with FittedBox labels so the row
                        // can never overflow on a narrow phone.
                        MockupCard(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('INVITE CODE', style: TextStyle(color: kMuted, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.6)),
                                    const SizedBox(height: 2),
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerLeft,
                                      child: Text(SupaDb.strOf(_team['invite_code'], '—'), style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 18)),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              InkWell(
                                onTap: _copyInviteCode,
                                borderRadius: BorderRadius.circular(10),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                  decoration: BoxDecoration(color: kGold.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10), border: Border.all(color: kGold)),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      // Mockup #3: "COPY" text first,
                                      // then the copy icon.
                                      Text('COPY', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 12)),
                                      const SizedBox(width: 4),
                                      Icon(Icons.copy, color: kGold, size: 14),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              InkWell(
                                onTap: _invitePlayer,
                                borderRadius: BorderRadius.circular(10),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  decoration: BoxDecoration(color: kGold, borderRadius: BorderRadius.circular(10)),
                                  child: const FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text('INVITE PLAYER +', style: TextStyle(color: Color(0xFF0A0A0F), fontWeight: FontWeight.bold, fontSize: 12)),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        // 081: "ROSTER (3/4)" when the cap is known
                        // (mockup #3), "ROSTER (3)" for a team.
                        _goldBarHeader(rosterHeaderLabel(_members.length, cap)),
                        const SizedBox(height: 10),
                        if (_members.isEmpty)
                          const EmptyState(
                            icon: Icons.group_outlined,
                            title: 'No members',
                            body: 'Is team me abhi koi member nahi dikh raha.',
                          ),
                        for (final m in _members) _memberCard(m),
                        // 081: honest empty slots — one
                        // [EmptyRosterSlot] per open roster place,
                        // never a fake member.
                        for (var i = 0; i < emptySlotCount(_members.length, cap); i++) const EmptyRosterSlot(),
                        const SizedBox(height: 8),
                        GoldButton(label: 'Open Team Chat', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TeamChatPage(team: _team, uid: widget.uid, navIndex: widget.navIndex)))),
                        // TOURNAMENT CHAT REMOVED (2026-11-22 user
                        // order): the "TOURNAMENT CHAT" heading +
                        // per-tournament chat buttons are gone from
                        // My Team. "Open Team Chat" above is the
                        // only chat entry here now. TeamChatPage
                        // itself is untouched — its tournamentId
                        // mode currently has no entry point left,
                        // and can be re-wired later if wanted.
                      ],
                    ),
    );
  }
}

/// Team History (§6.1 #3): recent match_history rows of ALL current
/// members, newest first. A team has no match table of its own, so
/// history is honestly the members' recorded matches — real rows
/// only, never invented.
class TeamHistoryPage extends StatefulWidget {
  final Map<String, dynamic> team;
  final List<Map<String, dynamic>> members;
  const TeamHistoryPage({super.key, required this.team, required this.members});
  @override
  State<TeamHistoryPage> createState() => _TeamHistoryPageState();
}

class _TeamHistoryPageState extends State<TeamHistoryPage> {
  List<Map<String, dynamic>> _rows = [];
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final names = <String, String>{};
      for (final m in widget.members) {
        names[SupaDb.strOf(m['firebase_uid'])] = SupaDb.strOf(m['user_name'], 'Player');
      }
      final all = <Map<String, dynamic>>[];
      for (final uid in names.keys) {
        final rows = await SupaDb.getMatchHistory(uid);
        for (final r in rows) {
          all.add({...r, '_memberName': names[uid] ?? 'Player'});
        }
      }
      all.sort((a, b) => SupaDb.intOf(b['timestamp']).compareTo(SupaDb.intOf(a['timestamp'])));
      if (mounted) setState(() => _rows = all);
    } catch (e) {
      // Defensive only: getMatchHistory swallows read errors.
      if (mounted) setState(() => _error = 'History load nahi ho saki: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Team History — ${SupaDb.strOf(widget.team['name'])}', style: TextStyle(color: kGold))),
      body: _busy
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: const [
                LoadingSkeleton(height: 72),
                SizedBox(height: 8),
                LoadingSkeleton(height: 72),
                SizedBox(height: 8),
                LoadingSkeleton(height: 72),
              ],
            )
          : _error != null
              ? Center(child: ErrorState(message: _error!, onRetry: _load))
              : _rows.isEmpty
                  ? const Center(
                      child: EmptyState(
                        icon: Icons.history,
                        title: 'No team history yet',
                        body: 'Team members ke abhi koi match record nahi — admin jab result credit karega, tab yahan history dikhegi.',
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _rows.length,
                      itemBuilder: (context, i) {
                        final r = _rows[i];
                        final rank = SupaDb.intOf(r['rank']);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: MockupCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Expanded(child: Text(SupaDb.strOf(r['tournamentName']), style: TextStyle(color: kText, fontWeight: FontWeight.bold))),
                                  Text(fmtRs(SupaDb.numOf(r['earnings'])), style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 13)),
                                ]),
                                const SizedBox(height: 2),
                                Text('${SupaDb.strOf(r['_memberName'])}  •  ${fmtDate(SupaDb.intOf(r['timestamp']))}', style: TextStyle(color: kMuted, fontSize: 12)),
                                Text(rank > 0 ? 'Rank #$rank  •  ${SupaDb.intOf(r['kills'])} kills  •  ${SupaDb.intOf(r['damage'])} damage' : '${SupaDb.intOf(r['kills'])} kills  •  ${SupaDb.intOf(r['damage'])} damage', style: TextStyle(color: kMuted, fontSize: 12)),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}

/// FIX 3 (2026-11-22): one row of the Members dropdown — an online
/// user in THIS room. Pure data, built by [onlineRoomMembers].
class RoomMemberEntry {
  final String uid;
  final String name;
  final String photoUrl;
  const RoomMemberEntry({required this.uid, required this.name, this.photoUrl = ''});
}

/// FIX 3: online users in THIS team room — team members whose
/// presence row is online (the single 2-minute freshness rule,
/// [SupaDb.presenceIsOnline]). Team rooms carry no presence
/// context field (room_screen's _presenceInRoom returns true for
/// team scope), so an online team member IS in the room. Offline
/// members, members with no presence row, and presence rows for
/// non-members never appear. Names: team_members.user_name first,
/// then the profile's display_name/username — NEVER the Firebase
/// UID (FIX 10 rule). Pure (no Supabase calls) so unit-testable.
List<RoomMemberEntry> onlineRoomMembers({
  required List<Map<String, dynamic>> members,
  required Map<String, Map<String, dynamic>> presence,
  required Map<String, Map<String, dynamic>> profiles,
}) {
  final out = <RoomMemberEntry>[];
  for (final m in members) {
    final uid = SupaDb.strOf(m['firebase_uid']);
    if (uid.isEmpty) continue;
    if (!SupaDb.presenceIsOnline(presence[uid] ?? {})) continue;
    final profile = profiles[uid] ?? {};
    var name = SupaDb.strOf(m['user_name']);
    if (name.isEmpty) name = SupaDb.strOf(profile['display_name']);
    if (name.isEmpty) name = SupaDb.strOf(profile['username']);
    if (name.isEmpty) name = 'Player';
    out.add(RoomMemberEntry(uid: uid, name: name, photoUrl: SupaDb.strOf(profile['photo_url'])));
  }
  return out;
}

/// Mockup #28 is the TOURNAMENT-wide chat ("SQUAD SHOWDOWN CHAT"),
/// while the original entry point (TeamDetailPage "Open Team Chat")
/// is the team/squad chat. This page therefore has two modes:
///  - team mode (default): scope 'team', squad_id 'team_' + team id —
///    the original behaviour, unchanged.
///  - tournament mode: pass tournamentId (+ tournamentName); loads
///    scope 'tournament' messages via SupaDb.getChat, shows the
///    pinned banner, squad tags, and the report flag — all real data.
///    Opened from TeamDetailPage "Tournament Chat" (below).
/// Flat crown painter for the chat ORGANIZER pill (mockup #27).
/// Same path as the leaderboard _CrownPainter in more_screens.dart.
class TeamChatPage extends StatefulWidget {
  final Map<String, dynamic> team;
  final String uid;
  final String? tournamentId;
  final String? tournamentName;
  // NAV HIGHLIGHT (2026-11-22): passed through to TeamDetailPage
  // via _openMembers so the bottom-nav highlight survives the
  // Detail → Chat → Detail round trip.
  final int navIndex;
  const TeamChatPage({super.key, required this.team, required this.uid, this.tournamentId, this.tournamentName, this.navIndex = 2});
  @override
  State<TeamChatPage> createState() => _TeamChatPageState();
}

class _TeamChatPageState extends State<TeamChatPage> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription<List<Map<String, dynamic>>>? _chatSub;
  List<Map<String, dynamic>> _msgs = [];
  bool _busy = true;
  // MESSAGE SOUNDS (Sameer's picks, 2026-11-22): the in-chat pop
  // plays only AFTER the first stream emission has primed the list
  // — opening the chat must not beep for its loaded history.
  bool _chatPrimed = false;
  // P1-7: emoji picker + photo upload state (shared ArenaEmojiPicker,
  // built-in set — no new package). _isAdmin/_adminUid gate the
  // in-chat pin action (designated admin only, fail-closed).
  bool _showEmoji = false;
  bool _uploadingImage = false;
  bool _isAdmin = false;
  String _adminUid = '';
  bool _myLevelLoaded = false;
  // v2017 INLINE VOICE (user order 2026-11-22): the Voice toggle
  // state — true while the inline voice panel is open (voice
  // connects on open, disconnects on close via the panel's
  // dispose). _voiceRequestStatus/_voiceRequestBusy/_voiceUnlocked
  // are the fix-14 lock/request state (locked team only).
  bool _voicePanelOpen = false;
  // FIX 16 (2026-11-23): the voice settings bridge — the embedded
  // panel binds its Music / Room Settings / RJ / Close actions
  // into this controller, and the header Settings button opens the
  // sheet that calls them. Owned here (the panel mounts/unmounts
  // with the toggle); disposed with the chat page.
  final _voiceController = VoicePanelController();
  String _voiceRequestStatus = '';
  bool _voiceRequestBusy = false;
  bool _voiceUnlocked = false;
  // Tournament mode (mockup #28) — all derived from real rows:
  // _pinned = latest pinned_messages row for the tournament;
  // _squadOf = sender firebase_uid -> squad number (registration
  // order of distinct team_names); _playerCount = registrations;
  // _players = registered players for the Members dialog.
  bool get _isTournament => SupaDb.strOf(widget.tournamentId).isNotEmpty;
  String get _tournamentId => SupaDb.strOf(widget.tournamentId);
  Map<String, dynamic>? _pinned;
  Map<String, int> _squadOf = {};
  int _playerCount = 0;
  List<Map<String, String>> _players = [];
  // Mockup #27 header thumb: the tournament's real cover photo
  // (fetched in _loadTournamentExtras); empty = shield fallback.
  String _tournamentBanner = '';
  // Mockup #27 header counts — REAL team data only: member count
  // from team_members, online count from presence (same 2-minute
  // rule as the Status sheet). No fake capacity ("250/1000").
  int _memberCount = 0;
  int _onlineCount = 0;
  // FIX 22 item 15: the CAPTAIN's profile followers count for
  // the sidebar Followers icon (same count feeds the item-19
  // blue-tick 1000 rule). Null until the best-effort read
  // lands (or when it fails) — the icon shows '—', never a
  // fake number.
  int? _captainFollowers;
  // PRESENCE REFRESH (2026-11-22): the header's "N Online" count
  // used to freeze at page-load time (one-shot read in
  // _loadExtras). The uid list is kept so a 30s timer can re-read
  // presence for the same members/players while the chat is open.
  List<String> _presenceUids = [];
  Timer? _presenceTimer;
  // FIX 3 (2026-11-22): Members = inline online-in-room list.
  // _roomMembersOpen toggles the dropdown under the header;
  // _teamMemberRows keeps the team_members rows _loadExtras
  // fetched (uid + user_name); _roomPresence/_roomProfiles hold
  // the rows the list renders (presence refreshed on open + by
  // the 30s timer while open; profiles cached after first load).
  bool _roomMembersOpen = false;
  List<Map<String, dynamic>> _teamMemberRows = [];
  Map<String, Map<String, dynamic>> _roomPresence = {};
  Map<String, Map<String, dynamic>> _roomProfiles = {};
  // Sender profiles for avatars (mockup #27 shows each sender's
  // photo). Own level for the "Lv.N" pill on own messages (real
  // profiles.level, same source as Rewards).
  Map<String, Map<String, dynamic>> _profiles = {};
  int _myLevel = 1;

  @override
  void initState() {
    super.initState();
    _loadExtras();
    _loadCaptainFollowers();
    _subscribeChat();
    _loadAdminUid();
    // v2017 INLINE VOICE (fix-14 gating): a locked team reads its
    // open request status so the banner/sheet show PENDING
    // instead of a second request button.
    if (_voiceLocked) _loadVoiceRequestStatus();
    // PRESENCE REFRESH (2026-11-22): 30s re-read of the header's
    // online count (see _presenceTimer).
    _presenceTimer = Timer.periodic(const Duration(seconds: 30), (_) => _refreshOnlineCount());
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();
    _chatSub?.cancel();
    _voiceController.dispose();
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// FIX 22 item 15: the captain's profile followers count
  /// for the sidebar Followers icon (same count feeds the
  /// item-19 blue-tick 1000 rule). Best-effort, never blocks
  /// the page; a failed read leaves null (icon shows '—').
  Future<void> _loadCaptainFollowers() async {
    try {
      if (_captainUid.isEmpty) return;
      final followers = await CommunityService.followers(_captainUid);
      if (mounted) setState(() => _captainFollowers = followers.length);
    } catch (_) {}
  }

  /// Re-reads presence for the members/players whose uids
  /// _loadExtras stored, and refreshes the header's "N Online"
  /// count. Best-effort: a failed read keeps the last good count.
  Future<void> _refreshOnlineCount() async {
    if (!mounted || _presenceUids.isEmpty) return;
    final presence = await SupaDb.getPresenceMap(_presenceUids);
    if (!mounted) return;
    setState(() {
      _onlineCount = presence.values.where(SupaDb.presenceIsOnline).length;
      // FIX 3: while the Members list is open, the same refresh
      // keeps its rows live (someone going offline drops out).
      if (_roomMembersOpen) _roomPresence = presence;
    });
  }

  /// Designated admin (admin_config.admin_firebase_uid) — the only
  /// UID that may pin/unpin in-chat. Fail-closed: unreadable = not
  /// admin. Same rule the room chat uses for its ORGANIZER badge.
  Future<void> _loadAdminUid() async {
    final adminUid = await SupaDb.designatedAdminUid();
    if (!mounted) return;
    setState(() {
      _adminUid = adminUid;
      _isAdmin = adminUid.isNotEmpty && adminUid == widget.uid;
    });
  }

  /// P1-7 REALTIME: subscribe to chat_messages via the same
  /// postgres_changes pattern the DM/community chat use
  /// (SupaDb.streamChat → streamList: initial fetch + refetch on
  /// every change). New messages now arrive without re-sending; the
  /// old one-shot _load() only fetched once. Auto-scrolls to the
  /// bottom only when the reader was already there (or the new
  /// message is mine) — never yanks while reading older messages.
  void _subscribeChat() {
    final stream = SupaDb.streamChat(
      _isTournament ? 'tournament' : 'team',
      _isTournament ? _tournamentId : _scopeId,
    );
    _chatSub = stream.listen((rows) {
      if (!mounted) return;
      // FIX 22 item 23: same sticky-marker fix as community
      // chat — legacy CHAT_CLEARED rows (written by the room
      // clear before this fix) never render in team chat.
      // Filtered FIRST so grew/lastMine/sound all see the
      // visible rows only (a marker arrival must not beep).
      // PHASE E (E14): also the plain-text legacy notice
      // ("— Chat history clear kar di gayi —", no prefix).
      final visible = rows
          .where((m) =>
              !SupaDb.strOf(m['message']).startsWith('CHAT_CLEARED::') &&
              !SupaDb.strOf(m['message'])
                  .contains('Chat history clear kar di gayi'))
          .toList();
      final wasAtBottom = !_scroll.hasClients ||
          _scroll.position.pixels >= _scroll.position.maxScrollExtent - 80;
      final grew = visible.length > _msgs.length;
      final lastMine = visible.isNotEmpty &&
          SupaDb.strOf(visible.last['firebase_uid']) == widget.uid;
      // MESSAGE SOUNDS: new message from someone else while inside
      // this chat -> the short in-chat pop (chat_08). Own sends and
      // the first load never beep (see MessageSounds).
      final playChat = MessageSounds.shouldPlayChatSound(
          primed: _chatPrimed, grew: grew, lastIsMine: lastMine);
      _chatPrimed = true;
      setState(() {
        _msgs = visible;
        _busy = false;
      });
      if (playChat) MessageSounds.play(MessageSound.chat);
      _refreshProfiles(visible);
      if (grew && (wasAtBottom || lastMine)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients && mounted) {
            _scroll.animateTo(
              _scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
            );
          }
        });
      }
    }, onError: (_) {
      if (mounted) setState(() => _busy = false);
    });
  }

  /// Sender profiles for avatars + own level, refreshed incrementally
  /// as new senders appear on the realtime stream (the old _load()
  /// fetched them once for the first batch only).
  Future<void> _refreshProfiles(List<Map<String, dynamic>> rows) async {
    try {
      final missing = rows
          .map((m) => SupaDb.strOf(m['firebase_uid']))
          .where((u) => u.isNotEmpty && !_profiles.containsKey(u))
          .toSet()
          .toList();
      Map<String, Map<String, dynamic>> add = {};
      if (missing.isNotEmpty) add = await SupaDb.getProfilesMap(missing);
      var myLevel = _myLevel;
      var levelChanged = false;
      if (!_myLevelLoaded) {
        try {
          final me = await SupaDb.getRow('profiles', 'firebase_uid', widget.uid);
          myLevel = SupaDb.intOf(me['level'], 1);
          levelChanged = true;
        } catch (_) {}
      }
      if (!mounted) return;
      if (add.isNotEmpty || levelChanged) {
        setState(() {
          _profiles = {..._profiles, ...add};
          if (levelChanged) {
            _myLevel = myLevel;
            _myLevelLoaded = true;
          }
        });
      }
    } catch (_) {}
  }

  String get _scopeId => 'team_${SupaDb.strOf(widget.team['id'])}';
  String get _captainUid => SupaDb.strOf(widget.team['captain_uid']);

  String get _teamId => SupaDb.strOf(widget.team['id']);

  /// v2017 INLINE VOICE (fix-14 gating): is voice LOCKED for this
  /// team? Only an EXPLICIT false locks it — teams carry no
  /// flag and have voice by default (no approval), exactly
  /// as before. (CommunityGroups.isVoiceEnabled is fail-closed and
  /// would lock every flag-less team — the wrong default here.)
  /// `_voiceUnlocked` flips live when a request comes back
  /// already-approved (stale locked row, backend already enabled).
  bool get _voiceLocked =>
      !_voiceUnlocked &&
      (widget.team['voice_enabled'] == false ||
          widget.team['voiceEnabled'] == false);

  /// v2017 INLINE VOICE (fix-14 gating): may THIS user file a
  /// voice request? The team creator — `created_by_uid` when the
  /// row carries it (community-backed), else the captain.
  bool get _isVoiceRequester {
    final creatorUid = SupaDb.strOf(widget.team['created_by_uid']);
    if (creatorUid.isNotEmpty) return creatorUid == widget.uid;
    return _captainUid.isNotEmpty && _captainUid == widget.uid;
  }

  bool get _canRequestVoice => CommunityGroups.canRequestVoiceAccess(
      isCreator: _isVoiceRequester,
      voiceEnabled: !_voiceLocked,
      requestStatus: _voiceRequestStatus);

  /// v2017 INLINE VOICE (fix-14 gating): the open request status
  /// for a locked team, so the banner/sheet show PENDING instead
  /// of a second request button. Only read while locked.
  Future<void> _loadVoiceRequestStatus() async {
    final status = await CommunityGroups.voiceRequestStatus(_teamId);
    if (mounted && status.isNotEmpty) setState(() => _voiceRequestStatus = status);
  }

  /// One-shot extras (counts, squad numbers, pinned banner, members)
  /// — everything the old _load() did EXCEPT the message fetch, which
  /// the realtime stream now owns. Runs once at init; the pinned row
  /// is re-read after every pin/unpin via [_refreshPinned].
  Future<void> _loadExtras() async {
    if (_isTournament) {
      await _loadTournamentExtras();
    } else {
      // Header counts: best-effort, never block the chat.
      try {
        final members = await SupaDb.getList('team_members', eqCol: 'team_id', eqVal: SupaDb.strOf(widget.team['id']));
        final memberUids = members.map((m) => SupaDb.strOf(m['firebase_uid'])).where((s) => s.isNotEmpty).toList();
        // PRESENCE REFRESH (2026-11-22): keep the uids for the 30s timer.
        _presenceUids = memberUids;
        // FIX 3: keep the member rows for the Members dropdown
        // (uid + user_name); the list filters them by presence.
        _teamMemberRows = members;
        final presence = await SupaDb.getPresenceMap(memberUids);
        final online = presence.values.where(SupaDb.presenceIsOnline).length;
        if (mounted) {
          setState(() {
            _memberCount = members.length;
            _onlineCount = online;
          });
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Tournament mode extras (best-effort, never blocks the chat):
  /// real player/online counts from registrations + presence, squad
  /// numbers from registration order, the latest pinned message, and
  /// sender profiles + own level for avatars / the Lv.N pill.
  Future<void> _loadTournamentExtras() async {
    try {
      final regs = await SupaDb.getList('tournament_registrations', eqCol: 'tournament_id', eqVal: _tournamentId);
      final uids = regs.map((r) => SupaDb.strOf(r['firebase_uid'])).where((s) => s.isNotEmpty).toSet().toList();
      // PRESENCE REFRESH (2026-11-22): keep the uids for the 30s timer.
      _presenceUids = uids;
      final presence = await SupaDb.getPresenceMap(uids);
      final online = presence.values.where(SupaDb.presenceIsOnline).length;
      // Squad numbers = registration order of distinct team_names
      // (earliest joined_at first). Solo registrations have no
      // team_name and get no SQUAD pill.
      final earliest = <String, int>{};
      final uidToTeam = <String, String>{};
      for (final r in regs) {
        final name = SupaDb.strOf(r['team_name']);
        final uid = SupaDb.strOf(r['firebase_uid']);
        final ts = SupaDb.intOf(r['joined_at_ms'], 0);
        if (uid.isNotEmpty && name.isNotEmpty) uidToTeam[uid] = name;
        if (name.isNotEmpty) {
          final prev = earliest[name];
          if (prev == null || ts < prev) earliest[name] = ts;
        }
      }
      final ordered = earliest.keys.toList()..sort((a, b) => earliest[a]!.compareTo(earliest[b]!));
      final numOf = <String, int>{for (var i = 0; i < ordered.length; i++) ordered[i]: i + 1};
      final squadOf = <String, int>{};
      for (final e in uidToTeam.entries) {
        final n = numOf[e.value];
        if (n != null) squadOf[e.key] = n;
      }
      Map<String, dynamic>? pinned;
      try {
        final pins = await SupaDb.getList('pinned_messages', eqCol: 'tournament_id', eqVal: _tournamentId, orderBy: 'created_at', ascending: false, limit: 1);
        if (pins.isNotEmpty) pinned = pins.first;
      } catch (_) {}
      final senderUids = _msgs.map((m) => SupaDb.strOf(m['firebase_uid'])).where((s) => s.isNotEmpty).toSet().toList();
      final profiles = await SupaDb.getProfilesMap(senderUids);
      var myLevel = 1;
      try {
        final me = await SupaDb.getRow('profiles', 'firebase_uid', widget.uid);
        myLevel = SupaDb.intOf(me['level'], 1);
      } catch (_) {}
      final players = regs.map((r) => <String, String>{'name': SupaDb.strOf(r['username'], SupaDb.strOf(r['game_uid'], 'Player')), 'team': SupaDb.strOf(r['team_name'])}).toList();
      // Mockup #27 header thumb: the real tournament cover (banner
      // / banner_url / image_url — whichever the row carries).
      var banner = '';
      try {
        final trow = await SupaDb.getRow('tournaments', 'id', _tournamentId);
        banner = SupaDb.strOf(trow['banner'], SupaDb.strOf(trow['banner_url'], SupaDb.strOf(trow['image_url'], SupaDb.strOf(trow['image'], ''))));
      } catch (_) {}
      if (mounted) {
        setState(() {
          _playerCount = regs.length;
          _onlineCount = online;
          _squadOf = squadOf;
          _pinned = pinned;
          _profiles = profiles;
          _myLevel = myLevel;
          _players = players;
          _tournamentBanner = banner;
        });
      }
    } catch (_) {}
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    // Admin close-comments (decided): a chat-restricted user is
    // refused with the exact toast, in BOTH modes — tournament mode
    // used to skip this check entirely.
    if (await SupaDb.isChatRestricted(widget.uid)) {
      if (mounted) toast(context, 'Aap ke comments admin ne band kiye hue hain.');
      return;
    }
    _ctrl.clear();
    if (_showEmoji && mounted) setState(() => _showEmoji = false);
    try {
      final profile = await SupaDb.getProfile(widget.uid);
      final name = SupaDb.strOf(profile['displayName'], 'User');
      await SupaDb.sendChat(
        scope: _isTournament ? 'tournament' : 'team',
        scopeId: _isTournament ? _tournamentId : _scopeId,
        uid: widget.uid,
        displayName: name,
        message: text,
      );
      // No _load() re-fetch: the realtime stream echoes the row.
    } catch (e) {
      if (mounted) toast(context, 'Send failed: $e');
    }
  }

  /// P1-7 PHOTO SHARE — same proven path as the DM picture flow:
  /// pick (ImagePicker, compressed at pick time, file_picker fallback)
  /// -> probe the image_url column FIRST -> ImgBB upload (the same
  /// service as profile/banner/dispute/DM/room photos; no new Storage
  /// bucket — see report) -> send with the image URL. Renders via
  /// ArenaChatMessage(imageUrl:) + tap-to-view.
  Future<void> _sendImage() async {
    if (_uploadingImage) return;
    if (await SupaDb.isChatRestricted(widget.uid)) {
      if (mounted) toast(context, 'Aap ke comments admin ne band kiye hue hain.');
      return;
    }
    File? file;
    try {
      try {
        final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 1024);
        if (picked == null) return;
        file = File(picked.path);
      } on MissingPluginException {
        final res = await FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: false);
        if (res == null || res.files.isEmpty || res.files.single.path == null) return;
        file = File(res.files.single.path!);
      }
    } catch (_) {
      if (mounted) toast(context, 'Photo nahi khul saki — dobara koshish karein.');
      return;
    }
    final lower = file.path.toLowerCase();
    if (!lower.endsWith('.jpg') && !lower.endsWith('.jpeg') && !lower.endsWith('.png')) {
      if (mounted) toast(context, 'Sirf JPG ya PNG photo allowed hai.');
      return;
    }
    try {
      if (await file.length() > 5 * 1024 * 1024) {
        if (mounted) toast(context, 'Photo 5MB se bari hai — chhoti photo chunen.');
        return;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _uploadingImage = true);
    final ready = await CommunityService.dmImageColumnReady();
    if (!mounted) return;
    if (!ready) {
      setState(() => _uploadingImage = false);
      toast(context, 'Photo messages abhi available nahi — backend update pending hai.');
      return;
    }
    String url;
    try {
      url = await ImgbbService.uploadImage(file);
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploadingImage = false);
      toast(context, 'Photo upload failed: $e');
      return;
    }
    try {
      final profile = await SupaDb.getProfile(widget.uid);
      final name = SupaDb.strOf(profile['displayName'], 'User');
      await SupaDb.sendChat(
        scope: _isTournament ? 'tournament' : 'team',
        scopeId: _isTournament ? _tournamentId : _scopeId,
        uid: widget.uid,
        displayName: name,
        message: '',
        imageUrl: url,
      );
    } catch (e) {
      if (mounted) toast(context, 'Photo send failed: $e');
    } finally {
      if (mounted) setState(() => _uploadingImage = false);
    }
  }

  /// Re-read the latest pinned_messages row (after pin/unpin; the
  /// chat stream does not cover the pinned_messages table).
  Future<void> _refreshPinned() async {
    if (!_isTournament) return;
    try {
      final pins = await SupaDb.getList('pinned_messages', eqCol: 'tournament_id', eqVal: _tournamentId, orderBy: 'created_at', ascending: false, limit: 1);
      if (mounted) setState(() => _pinned = pins.isEmpty ? null : pins.first);
    } catch (_) {}
  }

  /// P1-7 ADMIN PIN/UNPIN (in-chat): the designated admin long-presses
  /// a message -> Pin writes a pinned_messages row (tournament_id,
  /// message, pinned_by admin UID; created_at defaults server-side),
  /// Unpin deletes the currently pinned row. Same write shape as the
  /// Host Tools pin path — no admin_tournaments.dart change. The
  /// banner always shows the latest row, so pinning a new message
  /// supersedes the old one. Photo-only messages cannot pin (the
  /// pinned row carries text only).
  Future<void> _showMessageActions(Map<String, dynamic> m) async {
    if (!_isTournament || !_isAdmin) return;
    final text = SupaDb.strOf(m['message']);
    final isPinned = _pinned != null && SupaDb.strOf(_pinned!['message']) == text && text.isNotEmpty;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: kCardPurpleMid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.push_pin, color: kGold),
              title: Text(isPinned ? 'Unpin message' : 'Pin message', style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
              subtitle: Text(isPinned ? 'Ye pinned banner se hat jayega.' : 'Ye message sab ke liye upar pin ho jayega.', style: TextStyle(color: kMuted, fontSize: 12)),
              onTap: () => Navigator.pop(ctx, isPinned ? 'unpin' : 'pin'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    try {
      if (action == 'pin') {
        if (text.isEmpty) {
          toast(context, 'Photo message pin nahi ho sakta — sirf text pin hota hai.');
          return;
        }
        await SupaDb.client.from('pinned_messages').insert({
          'tournament_id': _tournamentId,
          'message': text,
          'pinned_by': widget.uid,
        });
        await _refreshPinned();
        if (mounted) toast(context, 'Message pin ho gaya.');
      } else {
        final pinId = SupaDb.strOf(_pinned!['id']);
        if (pinId.isNotEmpty) {
          await SupaDb.client.from('pinned_messages').delete().eq('id', pinId);
        }
        if (mounted) setState(() => _pinned = null);
        if (mounted) toast(context, 'Message unpin ho gaya.');
      }
    } catch (e) {
      if (mounted) toast(context, 'Pin failed: $e');
    }
  }

  /// P1-8 INVITE from chat (squad + tournament mode — widget.team is
  /// the user's team in both): shared username dialog -> existing
  /// SupaDb.sendTeamInvite -> invitee's Notifications + push.
  Future<void> _inviteFromChat() async {
    final teamId = SupaDb.strOf(widget.team['id']);
    if (teamId.isEmpty) {
      toast(context, 'Team nahi mili — pehle team banayen ya join karen.');
      return;
    }
    final sent = await showChatTeamInviteDialog(
      context: context,
      myUid: widget.uid,
      teamId: teamId,
      teamName: SupaDb.strOf(widget.team['name'], 'Your team'),
      inviteCode: SupaDb.strOf(widget.team['invite_code']),
    );
    if (sent && mounted) toast(context, 'Invitation bhej di!');
  }

  /// Reactions (mockup #27 👍👎 under a message): real shared
  /// reactions in chat_messages.reactions (jsonb emoji -> [uids],
  /// migration 011) — same pattern as room_screen._chatItem. Tap
  /// toggles your own reaction; counts are visible to everyone.
  /// Shared [ArenaReactionRow] renders the chips; [_toggleReaction]
  /// below still does the real Supabase update.
  Widget _reactionRow(Map<String, dynamic> m, {bool alignEnd = false}) {
    return ArenaReactionRow(
      reactions: SupaDb.asMap(m['reactions']),
      myUid: widget.uid,
      alignEnd: alignEnd,
      onToggle: (emoji) => _toggleReaction(m, emoji, SupaDb.asMap(m['reactions'])),
    );
  }

  Future<void> _toggleReaction(Map<String, dynamic> m, String emoji, Map<String, dynamic> raw) async {
    final id = SupaDb.strOf(m['id']);
    if (id.isEmpty) return;
    final next = Map<String, dynamic>.from(raw);
    final list = (next[emoji] as List?)?.map((x) => x.toString()).toList() ?? <String>[];
    if (list.contains(widget.uid)) {
      list.remove(widget.uid);
    } else {
      list.add(widget.uid);
    }
    if (list.isEmpty) {
      next.remove(emoji);
    } else {
      next[emoji] = list;
    }
    try {
      await SupaDb.client.from('chat_messages').update({'reactions': next}).eq('id', id);
      // Optimistic local update so the count changes instantly.
      if (mounted) {
        setState(() {
          final i = _msgs.indexWhere((x) => SupaDb.strOf(x['id']) == id);
          if (i >= 0) _msgs[i] = {..._msgs[i], 'reactions': next};
        });
      }
    } catch (e) {
      if (mounted) toast(context, 'Reaction failed: $e');
    }
  }

  /// Mockup #27 flag icon: report a message to the admin (real
  /// `disputes` row via SupaDb.reportChatMessage). Works in team mode
  /// too — the report carries no tournamentId there (audit fix
  /// 2026-11-21). The reason format MUST match the admin parser
  /// (AdminDbCare.parseChatReportReason): 'Chat report [message ID]
  /// REASON: "EXCERPT"' — the old 'Chat message ID: ...' format
  /// never reached the Chat Reports queue.
  Future<void> _reportMessage(Map<String, dynamic> m) async {
    final senderUid = SupaDb.strOf(m['firebase_uid']);
    if (senderUid.isEmpty || senderUid == widget.uid) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text('Report message?', style: TextStyle(color: kText)),
        content: Text('Ye message admin ko report hoga.', style: TextStyle(color: kMuted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel', style: TextStyle(color: kMuted))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text('Report', style: TextStyle(color: kGold))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final profile = await SupaDb.getProfile(widget.uid);
      final excerpt = SupaDb.strOf(m['message']);
      await SupaDb.reportChatMessage(
        tournamentId: _isTournament ? _tournamentId : null,
        raisedBy: widget.uid,
        raisedByName: SupaDb.strOf(profile['displayName'], 'User'),
        againstUid: senderUid,
        reason: 'Chat report [message ${SupaDb.strOf(m['id'])}] Inappropriate: "${excerpt.length > 120 ? excerpt.substring(0, 120) : excerpt}"',
      );
      if (mounted) toast(context, 'Report admin ko bhej diya.');
    } catch (e) {
      if (mounted) toast(context, 'Report failed: $e');
    }
  }

  /// Tournament mode Members: the real registered players of this
  /// tournament (name + squad team, or Solo). Read-only list.
  void _showPlayers() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text('${SupaDb.strOf(widget.tournamentName, 'Tournament')} — Players', style: TextStyle(color: kGold)),
        content: SizedBox(
          width: double.maxFinite,
          child: _players.isEmpty
              ? Text('Abhi koi registered player nahi.', style: TextStyle(color: kMuted))
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: _players.length,
                  itemBuilder: (_, i) {
                    final p = _players[i];
                    final team = p['team'] ?? '';
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(child: Text(p['name'] ?? 'Player', style: TextStyle(color: kText))),
                          if (team.isNotEmpty) Text(team, style: TextStyle(color: kMuted, fontSize: 12)),
                        ],
                      ),
                    );
                  },
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text('Close', style: TextStyle(color: kGold)))],
      ),
    );
  }

  /// Pinned banner (mockup #27): the latest real `pinned_messages`
  /// row for this tournament. Tournament mode only — pinned messages
  /// are keyed by tournament_id, which team mode has none. "View"
  /// shows the full pinned text. Shared [ArenaPinnedBanner] renders
  /// it (including the mockup's gold "Check lobby" span).
  Widget _pinnedBanner() {
    final msg = SupaDb.strOf(_pinned!['message']);
    if (msg.isEmpty) return const SizedBox.shrink();
    return ArenaPinnedBanner(
      message: msg,
      onView: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: kCardPurpleMid,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
          title: Text('Pinned Message', style: TextStyle(color: kGold)),
          content: Text(msg, style: TextStyle(color: kText)),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text('Close', style: TextStyle(color: kGold)))],
        ),
      ),
    );
  }

  void _openMembers() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => TeamDetailPage(team: widget.team, uid: widget.uid, navIndex: widget.navIndex)));
  }

  // FIX 3 (2026-11-22, user order): the header Members button no
  // longer opens the My Team screen — it toggles an inline
  // dropdown under the header listing the ONLINE users in THIS
  // room. First tap opens, second tap closes. My Team stays
  // reachable via More -> Team settings (_openMembers above).
  // Tournament mode is untouched (its Members still shows the
  // players dialog via _showPlayers).
  void _toggleRoomMembers() {
    final opening = !_roomMembersOpen;
    setState(() => _roomMembersOpen = opening);
    if (opening) _loadRoomMembers();
  }

  /// FIX 3: (re)reads presence + profiles for the team members
  /// when the dropdown opens. Best-effort: a failed read keeps
  /// the last good rows (or the empty state) — never a crash.
  Future<void> _loadRoomMembers() async {
    if (_isTournament || _presenceUids.isEmpty) return;
    final presence = await SupaDb.getPresenceMap(_presenceUids);
    var profiles = _roomProfiles;
    if (profiles.isEmpty) profiles = await SupaDb.getProfilesMap(_presenceUids);
    if (!mounted) return;
    setState(() {
      _roomPresence = presence;
      _roomProfiles = profiles;
    });
  }

  /// FIX 3: the inline dropdown under the header — online users
  /// in this room only (see [onlineRoomMembers]). Capped height
  /// (320) with a scrollable ListView, so a long roster scrolls
  /// up/down instead of covering the chat.
  Widget _roomMembersPanel() {
    final entries = onlineRoomMembers(
      members: _teamMemberRows,
      presence: _roomPresence,
      profiles: _roomProfiles,
    );
    return Container(
      key: const Key('room_members_panel'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      decoration: cardFillDecoration(radius: 14).copyWith(
        border: Border.all(color: kGold.withValues(alpha: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.group, color: kGold, size: 16),
              const SizedBox(width: 6),
              Text('ONLINE IN ROOM', style: TextStyle(color: kGold, fontSize: 12, fontWeight: FontWeight.w800)),
              const SizedBox(width: 6),
              Text('(${entries.length})', style: TextStyle(color: kMuted, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 6),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('Abhi koi member online nahi hai.', style: TextStyle(color: kMuted, fontSize: 13)),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: entries.length,
                itemBuilder: (_, i) => _roomMemberRow(entries[i]),
              ),
            ),
        ],
      ),
    );
  }

  /// FIX 3: one compact dropdown row — avatar (photo or initial),
  /// name, green online dot + "Online". No mic state: mic on/off
  /// lives in the voice panel's engines, not in presence data.
  Widget _roomMemberRow(RoomMemberEntry e) {
    final initial = e.name.isNotEmpty ? e.name[0].toUpperCase() : '?';
    return Padding(
      key: ValueKey('room_member_${e.uid}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: kGold.withValues(alpha: 0.15),
            backgroundImage: e.photoUrl.isNotEmpty ? NetworkImage(e.photoUrl) : null,
            child: e.photoUrl.isEmpty ? Text(initial, style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 14)) : null,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(e.name, style: TextStyle(color: kText, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis)),
          Container(width: 10, height: 10, decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.greenAccent)),
          const SizedBox(width: 4),
          const Text('Online', style: TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // v2017 INLINE VOICE (user order 2026-11-22): the Voice button
  // is a TOGGLE now, not a new screen — ON opens the inline voice
  // panel (same room page, embedded mode: host strip + mic seats
  // + music/settings, voice connects on open); OFF hides it and
  // voice disconnects on dispose. Mic seats: 6 (FIX 11 — Squad
  // removed, every team room has 6). Team rooms need no approval
  // (fix 14's approval is for public communities only) — unless
  // the team row
  // explicitly locks voice, in which case the lock/request flow
  // runs instead of the panel.
  void _toggleVoice() {
    if (_voiceLocked) {
      _onLockedVoiceTap();
      return;
    }
    setState(() => _voicePanelOpen = !_voicePanelOpen);
  }

  /// v2017 INLINE VOICE: the panel — the team room page in
  /// embedded mode (same room identity `squad_<teamId>`, same team
  /// scope, same mic counts). Mounting connects voice; unmounting
  /// (toggle OFF / Close) disconnects it. FIX 12 G5: no is_clan
  /// read here — the clan type is gone, every team gets 6 seats.
  Widget _buildVoicePanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        UnifiedRoomPage(
          scope: 'team',
          teamId: SupaDb.strOf(widget.team['id']),
          teamName: SupaDb.strOf(widget.team['name'], 'Team'),
          captainUid: _captainUid,
          // FIX 22 item 14: dimmed cover behind the host card
          // (team photo; teams have no description field, so
          // the tagline is the captain's bio or nothing).
          hostCardCoverUrl: SupaDb.strOf(widget.team['photo_url']),
          micCount: teamMicCount(),
          embedded: true,
          onCloseVoice: () => setState(() => _voicePanelOpen = false),
          // FIX 16: the header Settings sheet reaches the panel's
          // voice functions through this controller.
          voiceController: _voiceController,
          // FIX 22 item 15 (SUPERSEDES items 5 + 12e): the
          // embedded sidebar's round-icon entries — Followers,
          // Music, RJ Panel, Settings, Power, Leave Room (FIX 23
          // item 11 adds Power; item 6 makes them neon). Room
          // Home + Participants are REMOVED (exit is Leave Room).
          // FIX 23 item 12b: the host card's tappable members
          // button (FIX 22 item 16) is REMOVED — the hostCard*
          // params are gone; members live behind the sidebar
          // Followers entry instead (team scope keeps its
          // FanListPage; no Follow pill — onSidebarFollowToggle
          // stays null for teams).
          sidebarFollowersCount: _captainFollowers,
          onSidebarFollowers: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => FanListPage(
                uid: _captainUid,
                title: 'Followers',
              ),
            ),
          ),
          onSidebarSettings: () =>
              showVoiceSettingsSheet(context, _voiceController),
          onSidebarLeaveRoom: () => _voiceController.leaveVoice(),
          onSidebarRjPanel: () => _voiceController.openRjConsole(),
          onSidebarMusic: () => _voiceController.openMusic(),
          // FIX 22 item 19: the verified flag from the team row
          // when the key exists (absent = false — no flag
          // exists in the data today).
          hostCardVerified: profileVerifiedFlag(widget.team),
        ),
        Divider(color: kBorder, height: 1),
      ],
    );
  }

  /// v2017 INLINE VOICE (fix-14 gating) — locked Voice button tap.
  /// Non-creators only ever see the lock message (no button
  /// anywhere). The creator with a pending request gets the honest
  /// wait message; otherwise the request sheet opens (fresh
  /// request, or re-request after a reject). Same flow as the
  /// public community chat's lock handling.
  void _onLockedVoiceTap() {
    if (!_isVoiceRequester) {
      toast(context, 'Voice abhi lock hai — admin approval ke baad milegi.');
      return;
    }
    if (_voiceRequestStatus == 'pending') {
      toast(context, 'Voice request pending hai — admin approval ka intezar karen.');
      return;
    }
    _showVoiceRequestSheet();
  }

  /// v2017 INLINE VOICE (fix-14 gating) — creator-only sheet: why
  /// voice is locked + the request button. Same copy as the public
  /// community chat's sheet.
  void _showVoiceRequestSheet() {
    final rejected = _voiceRequestStatus == 'rejected';
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCardPurpleMid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.lock, color: kGold, size: 22),
                  const SizedBox(width: 8),
                  Text('Voice Locked hai', style: TextStyle(color: kText, fontSize: 17, fontWeight: FontWeight.w900)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                  rejected
                      ? 'Pichli voice request reject ho gayi thi — dobara request kar sakte hain. Admin approve karega to voice is community mein hamesha ke liye unlock ho jayegi.'
                      : 'Is community mein voice sirf admin approval ke baad milegi. Request bhejen — admin approve karega to voice hamesha ke liye unlock ho jayegi.',
                  style: TextStyle(color: kMuted, fontSize: 13)),
              const SizedBox(height: 16),
              GoldButton(
                label: 'SEND VOICE REQUEST',
                busy: _voiceRequestBusy,
                onPressed: _voiceRequestBusy
                    ? null
                    : () async {
                        final ok = await _requestVoiceAccess();
                        if (ok && sheetCtx.mounted) {
                          Navigator.pop(sheetCtx);
                        }
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// v2017 INLINE VOICE (fix-14 gating) — file the voice request
  /// (creator only; the service re-checks the creator rule).
  /// Returns true when the request landed (or was already
  /// pending/approved) — the caller pops the sheet. An
  /// already-approved answer means the locked row was stale and
  /// the backend already enabled voice: unlock live.
  Future<bool> _requestVoiceAccess() async {
    if (_voiceRequestBusy) return false;
    setState(() => _voiceRequestBusy = true);
    final res = await CommunityGroups.requestVoiceAccess(communityId: _teamId, requesterUid: widget.uid);
    if (!mounted) return false;
    setState(() => _voiceRequestBusy = false);
    if (res['ok'] == true) {
      final status = SupaDb.strOf(res['status'], 'pending');
      setState(() {
        _voiceRequestStatus = status;
        if (status == 'approved') _voiceUnlocked = true;
      });
      toast(context, res['already'] == true ? 'Voice request pehle se pending hai.' : 'Voice request bhej di gayi — admin approval ka intezar karen.');
      return true;
    }
    toast(context, res['offline'] == true ? 'Voice requests abhi online nahi hain.' : 'Failed: ${res['error']}');
    return false;
  }

  /// v2017 INLINE VOICE (fix-14 gating) — lock banner under the
  /// header, shown ONLY while voice is locked. Everyone sees the
  /// lock message; ONLY the creator sees the request button
  /// (pending -> a PENDING label instead of the button). Same
  /// pattern as the public community chat's banner.
  Widget _voiceLockBanner() {
    final pending = _voiceRequestStatus == 'pending';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: kCardFillColor,
        border: Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: [
          Icon(Icons.lock, color: kGold, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(pending ? 'Voice request pending hai — admin approval ka intezar karen.' : 'Voice locked hai — admin approval ke baad milegi.', style: TextStyle(color: kMuted, fontSize: 13)),
          ),
          if (_isVoiceRequester) ...[
            const SizedBox(width: 8),
            if (pending)
              Text('PENDING', style: TextStyle(color: kGold, fontSize: 12, fontWeight: FontWeight.w900))
            else
              GoldButton(
                label: 'REQUEST VOICE ACCESS',
                busy: _voiceRequestBusy,
                fullWidth: false,
                onPressed: _canRequestVoice ? () => _requestVoiceAccess() : null,
              ),
          ],
        ],
      ),
    );
  }

  Widget _senderAvatar(String senderUid) {
    final photoUrl = SupaDb.strOf((_profiles[senderUid] ?? {})['photo_url']);
    return ArenaCachedAvatar(
      photoUrl: photoUrl,
      radius: 20,
      backgroundColor: kField,
      fallback: Icon(Icons.person, color: kGold, size: 22),
    );
  }

  /// Mockup #27 other-player message (shared [ArenaChatMessage]):
  /// avatar left, "Name [TEAM n] time" header ABOVE the dark bubble,
  /// 👍👎 reaction row below, flag icon right (real report via
  /// disputes). Admin bubbles are gold-bordered with the ORGANIZER
  /// pill straddling the top edge and "Admin • time" INSIDE the
  /// bubble; captain bubbles carry the CAPTAIN pill (team mode only —
  /// captain is team-scoped). Tournament mode adds the grey SQUAD N
  /// pill (real registration order). ORGANIZER = the row's real
  /// is_admin flag OR the sender being the designated admin —
  /// sendChat never persists is_admin, so the flag alone would almost
  /// never fire (same fallback the room chat uses). Never shown
  /// without the matching real flag. Photo messages render the image
  /// inside the bubble (tap = full-size view). Designated admin
  /// long-presses a message to pin/unpin it (tournament mode).
  Widget _otherMessage(Map<String, dynamic> m) {
    final senderUid = SupaDb.strOf(m['firebase_uid']);
    final isAdmin = m['is_admin'] == true ||
        (_adminUid.isNotEmpty && senderUid.isNotEmpty && senderUid == _adminUid);
    final isCaptain = senderUid.isNotEmpty && senderUid == _captainUid;
    final isRole = isAdmin || (isCaptain && !_isTournament);
    final imageUrl = SupaDb.strOf(m['image_url']);
    return ArenaChatMessage(
      isMine: false,
      text: SupaDb.strOf(m['message']),
      imageUrl: imageUrl,
      onImageTap: imageUrl.isEmpty ? null : () => showChatImageDialog(context, imageUrl),
      timeLabel: _fmtClock(m['timestamp']),
      senderName: SupaDb.strOf(m['display_name'], 'User'),
      squadLabel: _isTournament && _squadOf.containsKey(senderUid) ? 'SQUAD ${_squadOf[senderUid]}' : '',
      avatar: _senderAvatar(senderUid),
      isOrganizer: isRole,
      roleLabel: isAdmin ? 'ORGANIZER' : 'CAPTAIN',
      reactions: _reactionRow(m),
      onReport: () => _reportMessage(m),
      onLongPress: (_isTournament && _isAdmin) ? () => _showMessageActions(m) : null,
    );
  }

  /// Mockup #27 own message (shared [ArenaChatMessage]):
  /// right-aligned, DARK GOLD-TINTED bubble with a gold border and
  /// white text (the mockup's own bubble is tinted dark gold, NOT
  /// solid gold), "Name (You)" + real Lv.N pill + time ABOVE it, and
  /// the 👍👎 reaction row below the bubble. Photo messages render
  /// the image inside the bubble (tap = full-size view).
  Widget _ownMessage(Map<String, dynamic> m) {
    final imageUrl = SupaDb.strOf(m['image_url']);
    return ArenaChatMessage(
      isMine: true,
      text: SupaDb.strOf(m['message']),
      imageUrl: imageUrl,
      onImageTap: imageUrl.isEmpty ? null : () => showChatImageDialog(context, imageUrl),
      timeLabel: _fmtClock(m['timestamp']),
      senderName: SupaDb.strOf(m['display_name'], 'You'),
      showYouSuffix: true,
      level: _myLevel,
      reactions: _reactionRow(m, alignEnd: true),
      onLongPress: (_isTournament && _isAdmin) ? () => _showMessageActions(m) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final teamName = SupaDb.strOf(widget.team['name'], 'Team').toUpperCase();
    // Tournament mode (mockup #27): the TOURNAMENT name + CHAT,
    // real player/online counts (no fake capacity).
    final titleName = _isTournament ? SupaDb.strOf(widget.tournamentName, 'Tournament').toUpperCase() : teamName;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Mockup #27 header (shared [ArenaChatHeader]): back +
            // photo thumb, "NAME CHAT" (name white italic, CHAT
            // gold), real counts, Members + More circle buttons
            // (both modes — the mockup shows Members + More in
            // tournament mode too).
            ArenaChatHeader(
              onBack: () => Navigator.maybePop(context),
              thumbnailUrl: _isTournament ? _tournamentBanner : '',
              titleName: titleName,
              subtitle: _isTournament ? '$_playerCount Players • $_onlineCount Online' : '$_memberCount Members • $_onlineCount Online',
              onMembers: _isTournament ? _showPlayers : _toggleRoomMembers,
              // FIX 3: gold/active while the online list is open.
              membersActive: _roomMembersOpen,
              // v2017 INLINE VOICE: Voice button (team mode only) —
              // tournament chat has no team room. Toggles the
              // inline voice panel; gold/active while it is open.
              onVoice: _isTournament ? null : _toggleVoice,
              voiceActive: _voicePanelOpen,
              // FIX 16 (2026-11-23): while the voice panel is open
              // the More button becomes Settings — it opens the
              // voice settings sheet (music / settings / RJ /
              // close voice). Panel closed = the More menu as
              // before (invite / copy / team settings).
              onSettings: (_voicePanelOpen && !_isTournament) ? () => showVoiceSettingsSheet(context, _voiceController) : null,
              moreItems: _isTournament
                  ? const [
                      ArenaChatMenuItem('invite', 'Invite player'),
                      ArenaChatMenuItem('players', 'View players'),
                      ArenaChatMenuItem('copy', 'Copy tournament name'),
                    ]
                  : const [
                      ArenaChatMenuItem('invite', 'Invite player'),
                      ArenaChatMenuItem('copy', 'Copy invite code'),
                      // v2016 FIX 13: the detail page (edit/history/
                      // roster/invite) lives here as Team settings —
                      // the "Members & Chat" card button now opens
                      // this chat directly, not the detail page.
                      ArenaChatMenuItem('team', 'Team settings'),
                    ],
              onMoreSelected: (v) {
                if (v == 'invite') {
                  _inviteFromChat();
                } else if (_isTournament) {
                  if (v == 'players') {
                    _showPlayers();
                  } else if (v == 'copy') {
                    Clipboard.setData(ClipboardData(text: SupaDb.strOf(widget.tournamentName, 'Tournament')));
                    toast(context, 'Tournament name copy ho gaya!');
                  }
                } else {
                  if (v == 'copy') {
                    Clipboard.setData(ClipboardData(text: SupaDb.strOf(widget.team['invite_code'])));
                    toast(context, 'Invite code copy ho gaya!');
                  } else if (v == 'team') {
                    _openMembers();
                  }
                }
              },
            ),
            Divider(color: kBorder, height: 1),
            // FIX 3 (2026-11-22): the Members dropdown — inline
            // under the header, above the voice panel/messages.
            if (_roomMembersOpen && !_isTournament) _roomMembersPanel(),
            // v2017 INLINE VOICE (fix-14 gating): the lock banner
            // shows while voice is locked (creator gets the request
            // button); the inline voice panel shows while the Voice
            // toggle is ON (team mode only — tournament chat has
            // no team room).
            if (_voiceLocked) _voiceLockBanner(),
            if (_voicePanelOpen && !_isTournament) _buildVoicePanel(),
            if (_isTournament && _pinned != null) _pinnedBanner(),
            Expanded(
              child: _busy
                  ? Center(child: CircularProgressIndicator(color: kGold))
                  : _msgs.isEmpty
                      ? proEmpty('Abhi koi message nahi. Pehla message bhejen!')
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.all(14),
                          itemCount: _msgs.length,
                          itemBuilder: (context, i) {
                            final m = _msgs[i];
                            final mine = SupaDb.strOf(m['firebase_uid']) == widget.uid;
                            return mine ? _ownMessage(m) : _otherMessage(m);
                          },
                        ),
            ),
            // Mockup #27 composer (shared [ArenaChatInputBar]):
            // pill field (emoji + photo inside), gold circular send.
            // Emoji opens the shared built-in picker above the bar;
            // photo sends via ImgBB + chat_messages.image_url.
            if (_showEmoji)
              ArenaEmojiPicker(
                onSelected: (e) => insertEmojiAtCursor(_ctrl, e),
              ),
            ArenaChatInputBar(
              controller: _ctrl,
              onSend: _send,
              onEmoji: () => setState(() => _showEmoji = !_showEmoji),
              onAttach: _sendImage,
              attachIcon: Icons.image,
              attachTooltip: 'Send a photo',
              busy: _uploadingImage,
            ),
          ],
        ),
      ),
    );
  }
}

/// ---------------- CHECK-IN ----------------

class CheckInPage extends StatefulWidget {
  final String uid;
  const CheckInPage({super.key, required this.uid});
  @override
  State<CheckInPage> createState() => _CheckInPageState();
}

class _CheckInPageState extends State<CheckInPage> {
  List<Map<String, dynamic>> _joined = [];
  Set<String> _checked = {};
  bool _pending = false;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final regs = await SupaDb.getList('tournament_registrations', eqCol: 'firebase_uid', eqVal: widget.uid);
      final mine = <Map<String, dynamic>>[];
      for (final r in regs) {
        final t = await SupaDb.getTournament(SupaDb.strOf(r['tournament_id']));
        if (t.isNotEmpty && SupaDb.strOf(t['status']) == 'upcoming') mine.add(t);
      }
      final checks = await SupaDb.getList('match_checkins', eqCol: 'firebase_uid', eqVal: widget.uid);
      if (mounted) setState(() {
        _joined = mine;
        _checked = checks.map((c) => SupaDb.strOf(c['tournament_id'])).toSet();
      });
    } catch (e) {
      if (proTableMissing(e) && mounted) setState(() => _pending = true);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _checkIn(Map<String, dynamic> t) async {
    try {
      final profile = await SupaDb.getProfile(widget.uid);
      await SupaDb.client.from('match_checkins').insert({
        'tournament_id': SupaDb.strOf(t['id']),
        'firebase_uid': widget.uid,
        'user_name': SupaDb.strOf(profile['displayName'], 'User'),
      });
      if (mounted) toast(context, 'Check-in ho gaya! Match ke liye ready.');
      _load();
    } catch (e) {
      if (mounted) toast(context, proTableMissing(e) ? 'Backend pending — migration 008 chalani hogi.' : 'Check-in failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Match Check-in', style: TextStyle(color: kGold))),
      body: _busy
          ? Center(child: CircularProgressIndicator(color: kGold))
          : _pending
              ? ListView(padding: const EdgeInsets.all(16), children: [proPendingCard('Match Check-in')])
              : _joined.isEmpty
                  ? proEmpty('Aapne koi upcoming tournament join nahi kiya. Pehle tournament join karen, phir yahan check-in karen.')
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _joined.length,
                      itemBuilder: (context, i) {
                        final t = _joined[i];
                        final done = _checked.contains(SupaDb.strOf(t['id']));
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: MockupCard(
                            child: Row(children: [
                              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(SupaDb.strOf(t['name']), style: TextStyle(color: kText, fontWeight: FontWeight.bold)), Text(SupaDb.strOf(t['status']), style: TextStyle(color: kMuted, fontSize: 12))])),
                              done
                                  ? Text('✓ Checked in', style: TextStyle(color: kGold, fontWeight: FontWeight.bold))
                                  : TextButton(onPressed: () => _checkIn(t), child: Text('Check-in', style: TextStyle(color: kGold, fontWeight: FontWeight.bold))),
                            ]),
                          ),
                        );
                      },
                    ),
    );
  }
}

/// ---------------- USER-CREATED TOURNAMENTS ----------------

/// N-create-tournament (2026-11-20): professional Create Tournament.
///
/// WORKFLOW (parent's decisions, implemented exactly):
///   user creates -> status 'pending' -> admin approves in the
///   Tournament Approvals queue (Admin Mode) -> status 'upcoming'/live
///   -> players join -> match -> result -> prize distribution.
///   'pending' needs migration 029 (status CHECK); on a pre-029 DB the
///   insert falls back to 'draft' (the 020 pre-approval state) so
///   creation never hard-fails.
/// ADMIN PROFIT: PAID tournaments — entry fee ka 10% platform
///   commission, baaki 90% prize pool. Recorded per paid entry as a
///   'platform_commission' transaction (see SupaDb.joinTournament) and
///   shown in Prize Escrow & Proof. FREE tournaments: BILKUL FREE — no
///   creation fee, no player fee, no commission.
/// CREATION QUOTA (user decisions, voice calls 2026-11-20):
///   ~18:04 PKT — PAID tournaments (entry fee > 0): NO daily limit —
///   agar user pay karta hai to jitne chahe bana sakta hai (3, 5, 10,
///   koi limit nahi). Spam is stopped by (1) the payment itself and
///   (2) admin approval of EVERY tournament before it goes live.
///   ~18:05 PKT — FREE tournaments (entry fee == 0): max 1 per WEEK
///   per user (ISO calendar week, Mon-Sun — see
///   SupaDb.countFreeTournamentsCreatedThisWeek + creationQuotaBlocked).
///   SUPERSEDES the old 3/day cap (kMaxTournamentsPerDay, retired).
///   Every tournament — paid or free — still goes to the approval
///   queue as 'pending'/'draft' and only goes live when the admin
///   approves it (SupaDb.approveTournament).
/// CREATOR: cannot join their own tournament (enforced in
///   SupaDb.joinTournament).
/// FIELDS (all real data, never hardcoded mock values):
///   game = dropdown from the admin-managed `games` table
///   (SupaDb.getGamesForPicker); no games configured -> honest empty
///   state + free-text fallback, never fake PUBG/BGMI defaults.
///   map = dropdown from the selected game's admin-configured maps
///   (games.maps, 029 draft) or free text when none configured.
///   start date+time, registration deadline, lobby opens time,
///   rules/description, per-kill prize, 1st/2nd/3rd prize split
///   (must total 100%), banner via ImgBB, perspective (TPP/FPP),
///   level gate. New columns live in 029 (DRAFT — never applied).

const double kPlatformCommissionPct = 10.0;
const List<int> kDefaultPrizeSplit = [50, 30, 20];

/// CREATION QUOTA — user decisions, voice calls 2026-11-20:
///   ~18:04 PKT: PAID tournaments (entry fee > 0) have NO limit —
///   agar user pay karta hai to jitne chahe bana sakta hai.
///   ~18:05 PKT: FREE tournaments (entry fee == 0): max 1 per WEEK
///   per user (ISO calendar week, Mon-Sun — enforced via
///   SupaDb.countFreeTournamentsCreatedThisWeek).
/// SUPERSEDED: the old daily cap (kMaxTournamentsPerDay = 3) is
/// retired — do NOT reintroduce a daily cap for paid creations.
/// 'Paid' = entry fee > 0, decided from the create form's fee field
/// at the gate in _create() (see creationQuotaBlocked).
const int kMaxFreeTournamentsPerWeek = 1;

/// Pure gate decision for the creation quota (unit-testable; the page
/// calls this after fetching the free-this-week count from SupaDb).
/// PAID (entryFee > 0): never blocked, no matter the count.
/// FREE (entryFee == 0): blocked once [freeCreatedThisWeek] reaches
/// [kMaxFreeTournamentsPerWeek] (1/week) — UNLESS the admin has turned
/// the quota OFF ([quotaEnabled] == false, app_settings
/// free_tournament_quota_enabled, user decision 2026-11-20 ~18:45
/// PKT). Default true = quota ON (missing setting = quota ON).
bool creationQuotaBlocked({required double entryFee, required int freeCreatedThisWeek, bool quotaEnabled = true}) {
  if (entryFee > 0) return false;
  if (!quotaEnabled) return false;
  return freeCreatedThisWeek >= kMaxFreeTournamentsPerWeek;
}

/// Funding rule (automation addendum): a PAID tournament's prize pool
/// must be fundable from its entry fees AFTER the platform commission
/// (prize <= fee x maxPlayers - commission). Free tournaments are
/// exempt — their prize is sponsor-funded, not entry-funded.
bool prizeFundable({required double prizePool, required double entryFee, required int maxPlayers, required double commissionPct}) {
  if (entryFee <= 0) return true;
  final collectable = maxCollectable(entryFee, maxPlayers);
  return prizePool <= collectable - platformCommissionFor(collectable, commissionPct);
}

/// Platform commission for one paid entry, rounded to paise.
double platformCommissionFor(double entryFee, double pct) =>
    (entryFee * pct / 100 * 100).round() / 100;

/// Prize split is valid only when 1st+2nd+3rd total exactly 100%.
bool prizeSplitValid(int first, int second, int third) =>
    first + second + third == 100;

/// Max the entry fees can collect if every slot fills.
double maxCollectable(double entryFee, int maxPlayers) =>
    entryFee * maxPlayers;

String _fmtDT(DateTime dt) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final h12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final ampm = dt.hour < 12 ? 'AM' : 'PM';
  final mm = dt.minute.toString().padLeft(2, '0');
  return '${dt.day} ${months[dt.month - 1]} ${dt.year}, $h12:$mm $ampm';
}

/// Designated-admin UID read (same source as fetchDesignatedAdminUid
/// in services/admin_config.dart, re-read here so this file needs no
/// new import). '' = unreadable -> fail closed.
Future<String> _designatedAdminUid() async {
  try {
    final rows = await SupaDb.getList('admin_config', eqCol: 'id', eqVal: 1);
    if (rows.isNotEmpty) return SupaDb.strOf(rows.first['admin_firebase_uid']);
  } catch (_) {}
  return '';
}

class CreateTournamentPage extends StatefulWidget {
  final String uid;
  final Map<String, dynamic>? clanWarTeam;
  const CreateTournamentPage({super.key, required this.uid, this.clanWarTeam});
  @override
  State<CreateTournamentPage> createState() => _CreateTournamentPageState();
}

class _CreateTournamentPageState extends State<CreateTournamentPage> {
  final _name = TextEditingController();
  final _gameText = TextEditingController();
  final _fee = TextEditingController(text: '0');
  final _prize = TextEditingController(text: '0');
  final _max = TextEditingController(text: '100');
  final _perKill = TextEditingController(text: '0');
  final _levelReq = TextEditingController(text: '0');
  final _rules = TextEditingController();
  final _mapText = TextEditingController();
  final _split1 = TextEditingController(text: '50');
  final _split2 = TextEditingController(text: '30');
  final _split3 = TextEditingController(text: '20');
  String _mode = 'Solo';
  String _perspective = ''; // '' = not set, else TPP / FPP
  bool _clanWar = false;
  bool _streamerHosted = false;
  bool _busy = false;
  bool _bannerBusy = false;
  DateTime _start = DateTime.now().add(const Duration(days: 1));
  DateTime? _deadline;
  DateTime? _lobby;
  String? _bannerUrl;
  List<Map<String, dynamic>> _games = [];
  bool _gamesLoaded = false;
  String? _selectedGameId;
  String? _selectedMap;

  List<String> get _mapsForGame {
    if (_selectedGameId == null) return [];
    final g = _games.where((e) => SupaDb.strOf(e['id']) == _selectedGameId).toList();
    if (g.isEmpty) return [];
    return SupaDb.asList(g.first['maps']).map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
  }

  String get _gameName {
    if (_selectedGameId != null) {
      final g = _games.where((e) => SupaDb.strOf(e['id']) == _selectedGameId).toList();
      if (g.isNotEmpty) return SupaDb.strOf(g.first['name']);
    }
    return _gameText.text.trim();
  }

  String get _mapName {
    if (_mapText.text.trim().isNotEmpty) return _mapText.text.trim();
    return _selectedMap ?? '';
  }

  @override
  void initState() {
    super.initState();
    _clanWar = widget.clanWarTeam != null;
    // Live commission/funding preview: rebuild when money fields change.
    for (final c in [_fee, _prize, _max, _split1, _split2, _split3]) {
      c.addListener(() {
        if (mounted) setState(() {});
      });
    }
    _loadGames();
  }

  @override
  void dispose() {
    _name.dispose();
    _gameText.dispose();
    _fee.dispose();
    _prize.dispose();
    _max.dispose();
    _perKill.dispose();
    _levelReq.dispose();
    _rules.dispose();
    _mapText.dispose();
    _split1.dispose();
    _split2.dispose();
    _split3.dispose();
    super.dispose();
  }

  Future<void> _loadGames() async {
    final games = await SupaDb.getGamesForPicker();
    if (mounted) {
      setState(() {
        _games = games;
        _gamesLoaded = true;
        // PUBG focus (user order 2026-11-20 ~11:39): the first game in
        // the ordered list (PUBG Mobile when configured) is
        // pre-selected — the user can change it.
        if (_selectedGameId == null && games.isNotEmpty) {
          _selectedGameId = SupaDb.strOf(games.first['id']);
        }
      });
    }
  }

  Future<DateTime?> _pickDateTime(DateTime initial) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null) return null;
    if (!mounted) return null;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _pickBanner() async {
    setState(() => _bannerBusy = true);
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
      if (picked == null) return;
      final url = await ImgbbService.uploadImage(File(picked.path));
      if (mounted) setState(() => _bannerUrl = url);
    } catch (e) {
      if (mounted) toast(context, 'Banner upload failed: $e');
    } finally {
      if (mounted) setState(() => _bannerBusy = false);
    }
  }

  Map<String, dynamic> _fullRow() {
    final fee = double.tryParse(_fee.text.trim()) ?? 0;
    final prize = double.tryParse(_prize.text.trim()) ?? 0;
    final tags = <String>[];
    if (_clanWar) tags.add('clan-war');
    if (_streamerHosted) tags.add('streamer-hosted');
    final split = prize > 0
        ? {'first': int.tryParse(_split1.text.trim()) ?? 50, 'second': int.tryParse(_split2.text.trim()) ?? 30, 'third': int.tryParse(_split3.text.trim()) ?? 20}
        : null;
    return {
      'name': _name.text.trim(),
      'game_name': _gameName,
      'game_id': _selectedGameId ?? '',
      'mode': _mode,
      'entry_fee': fee,
      'prize_pool': prize,
      'per_kill_prize': double.tryParse(_perKill.text.trim()) ?? 0,
      'max_players': int.tryParse(_max.text.trim()) ?? 100,
      'status': 'pending',
      'start_time': _start.toUtc().toIso8601String(),
      'created_by': widget.uid,
      'tags': tags,
      'description': _rules.text.trim(),
      'rules': _rules.text.trim(),
      'map': _mapName,
      'perspective': _perspective.isEmpty ? null : _perspective,
      'level_required': int.tryParse(_levelReq.text.trim()) ?? 0,
      'registration_deadline': _deadline?.toUtc().toIso8601String(),
      'lobby_opens_at': _lobby?.toUtc().toIso8601String(),
      'banner_url': _bannerUrl ?? '',
      'prize_distribution': split,
      'commission_pct': kPlatformCommissionPct,
    };
  }

  Map<String, dynamic> _coreRow(Map<String, dynamic> row) {
    // Columns guaranteed by migrations 001 + 010 (production): the
    // pre-029 fallback when a new column is unknown to PostgREST.
    return {
      'name': row['name'],
      'game_name': row['game_name'],
      'game_id': row['game_id'],
      'mode': row['mode'],
      'entry_fee': row['entry_fee'],
      'prize_pool': row['prize_pool'],
      'max_players': row['max_players'],
      'status': row['status'],
      'start_time': row['start_time'],
      'created_by': row['created_by'],
      'tags': row['tags'],
    };
  }

  Future<bool> _insertRow(Map<String, dynamic> row) async {
    // Retry ladder for DBs that predate migration 029 (DRAFT):
    //  1. full row, status 'pending'
    //  2. unknown column (PGRST204) -> core columns only, status 'pending'
    //  3. status CHECK rejects 'pending' -> same row, status 'draft'
    // Returns true when the row was created with the FULL field set.
    var attempt = Map<String, dynamic>.from(row);
    var triedCore = false;
    var triedDraft = false;
    var full = true;
    for (var i = 0; i < 3; i++) {
      try {
        await SupaDb.client.from('tournaments').insert(attempt);
        return full;
      } catch (e) {
        final s = e.toString();
        final unknownCol = s.contains('PGRST204') || (s.contains('Could not find') && s.contains('column'));
        final statusCheck = s.contains('check constraint') || s.contains('violates check');
        if (unknownCol && !triedCore) {
          triedCore = true;
          full = false;
          attempt = _coreRow(row);
          continue;
        }
        if (statusCheck && !triedDraft) {
          triedDraft = true;
          attempt = Map<String, dynamic>.from(attempt)..['status'] = 'draft';
          continue;
        }
        rethrow;
      }
    }
    return full;
  }

  Future<void> _create() async {
    final fee = double.tryParse(_fee.text.trim()) ?? -1;
    final prize = double.tryParse(_prize.text.trim()) ?? -1;
    final perKill = double.tryParse(_perKill.text.trim()) ?? -1;
    final maxP = int.tryParse(_max.text.trim()) ?? 0;
    final levelReq = int.tryParse(_levelReq.text.trim()) ?? -1;
    if (_name.text.trim().isEmpty) {
      toast(context, 'Tournament name zaroori hai.');
      return;
    }
    if (_gameName.isEmpty) {
      toast(context, 'Game select karen ya naam likhen.');
      return;
    }
    if (fee < 0 || prize < 0 || perKill < 0 || levelReq < 0) {
      toast(context, 'Fee, prize, per-kill aur level 0 ya zyada hone chahiye.');
      return;
    }
    if (maxP < 2) {
      toast(context, 'Max players kam se kam 2 hone chahiye.');
      return;
    }
    if (!_start.isAfter(DateTime.now())) {
      toast(context, 'Start time aane wale waqt me hona chahiye.');
      return;
    }
    if (_deadline != null && !_deadline!.isBefore(_start)) {
      toast(context, 'Registration deadline start time se pehle honi chahiye.');
      return;
    }
    if (_lobby != null && !_lobby!.isBefore(_start)) {
      toast(context, 'Lobby time start time se pehle hona chahiye.');
      return;
    }
    if (prize > 0) {
      final s1 = int.tryParse(_split1.text.trim()) ?? -1;
      final s2 = int.tryParse(_split2.text.trim()) ?? -1;
      final s3 = int.tryParse(_split3.text.trim()) ?? -1;
      if (s1 < 0 || s2 < 0 || s3 < 0 || !prizeSplitValid(s1, s2, s3)) {
        toast(context, 'Prize split ka total 100% hona chahiye (1st + 2nd + 3rd).');
        return;
      }
    }
    // AUTOMATION addendum — strict validation, no manual mistake:
    // a PAID tournament whose prize cannot be funded from its entry
    // fees (after commission) is BLOCKED here, not just warned.
    if (fee > 0 && !prizeFundable(prizePool: prize, entryFee: fee, maxPlayers: maxP, commissionPct: kPlatformCommissionPct)) {
      final collectable = maxCollectable(fee, maxP);
      final maxPrize = collectable - platformCommissionFor(collectable, kPlatformCommissionPct);
      toast(context, 'Prize pool entry fees se fund nahi ho sakta. Max prize: ${fmtRs(maxPrize)} (fee x players - 10% commission).');
      return;
    }
    // CREATION QUOTA (user decisions, voice calls 2026-11-20):
    //   ~18:04 PKT — PAID (fee > 0): NO limit, no DB count needed.
    //   ~18:05 PKT — FREE (fee == 0): max 1 per ISO calendar week.
    //   ~18:45 PKT — the admin can turn the free quota OFF from the
    //   admin panel (app_settings.free_tournament_quota_enabled);
    //   missing setting = quota ON (SupaDb.isFreeTournamentQuotaEnabled).
    // Spam is stopped by the payment itself + admin approval of every
    // tournament (insert is always 'pending'/'draft', never live).
    if (fee <= 0) {
      final quotaEnabled = await SupaDb.isFreeTournamentQuotaEnabled();
      if (!mounted) return;
      final freeThisWeek = await SupaDb.countFreeTournamentsCreatedThisWeek(widget.uid);
      if (!mounted) return;
      if (creationQuotaBlocked(entryFee: fee, freeCreatedThisWeek: freeThisWeek, quotaEnabled: quotaEnabled)) {
        toast(context, 'Is hafte ka free quota poora ho gaya — hafte mein sirf $kMaxFreeTournamentsPerWeek free tournament bana sakte hain. Paid tournament ki koi limit nahi hai.');
        return;
      }
    }
    setState(() => _busy = true);
    try {
      final full = await _insertRow(_fullRow());
      if (mounted) {
        toast(
          context,
          full
              ? 'Tournament create ho gaya — status Pending. Admin approve karega to live hoga.'
              : 'Tournament create ho gaya (status Pending), lekin kuch naye fields abhi save nahi hue — admin ko batayen.',
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) toast(context, friendlyDbError(e, 'Create'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Align(alignment: Alignment.centerLeft, child: Text(title, style: TextStyle(color: kSectionLabel, fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1))),
      );

  Widget _dateRow(String label, DateTime? value, String emptyHint, VoidCallback onTap, {bool optional = false}) => InkWell(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(color: kCardFillColor, borderRadius: BorderRadius.circular(10), border: Border.all(color: kGold.withOpacity(0.35))),
          child: Row(children: [
            Icon(Icons.calendar_today, color: kGold, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label + (optional ? ' (optional)' : ''), style: TextStyle(color: kMuted, fontSize: 12)),
                Text(value == null ? emptyHint : _fmtDT(value), style: TextStyle(color: value == null ? kMuted : kText, fontWeight: FontWeight.bold)),
              ]),
            ),
            Text('Change', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final fee = double.tryParse(_fee.text.trim()) ?? 0;
    final maxP = int.tryParse(_max.text.trim()) ?? 100;
    final collectable = maxCollectable(fee, maxP);
    final commission = platformCommissionFor(collectable, kPlatformCommissionPct);
    final prize = double.tryParse(_prize.text.trim()) ?? 0;
    final splitOk = prize <= 0 ||
        prizeSplitValid(int.tryParse(_split1.text.trim()) ?? 0, int.tryParse(_split2.text.trim()) ?? 0, int.tryParse(_split3.text.trim()) ?? 0);
    final maps = _mapsForGame;
    return Scaffold(
      appBar: AppBar(title: boardAppBarTitle('Create Tournament')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (widget.clanWarTeam != null)
              MockupCard(
                child: Text('Clan War — aapki team: ${SupaDb.strOf(widget.clanWarTeam!['name'])} (tag: ${SupaDb.strOf(widget.clanWarTeam!['tag'])})',
                    style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
              ),
            field(controller: _name, label: 'Tournament name'),
            const SizedBox(height: 10),
            if (!_gamesLoaded)
              Center(child: Padding(padding: EdgeInsets.symmetric(vertical: 8), child: CircularProgressIndicator(color: kGold)))
            else if (_games.isEmpty) ...[
              field(controller: _gameText, label: 'Game'),
              Text('Admin ne abhi koi game add nahi ki — game ka naam likhen. Admin games table me games add karega to yahan list aayegi.',
                  style: TextStyle(color: kMuted, fontSize: 12)),
            ] else
              DropdownButtonFormField<String>(
                value: _selectedGameId,
                dropdownColor: kCard,
                style: TextStyle(color: kText),
                decoration: InputDecoration(
                  labelText: 'Game',
                  labelStyle: TextStyle(color: kMuted),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: kGold.withOpacity(0.35))),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: kGold)),
                ),
                hint: Text('Game select karen', style: TextStyle(color: kMuted)),
                items: _games.map((g) => DropdownMenuItem<String>(value: SupaDb.strOf(g['id']), child: Text(SupaDb.strOf(g['name'])))).toList(),
                onChanged: (v) => setState(() {
                  _selectedGameId = v;
                  _selectedMap = null;
                  _mapText.clear();
                }),
              ),
            _section('Schedule'),
            _dateRow('Start date & time', _start, 'Select karen', () async {
              final picked = await _pickDateTime(_start);
              if (picked != null) setState(() => _start = picked);
            }),
            const SizedBox(height: 10),
            _dateRow('Registration deadline', _deadline, 'Set nahi — start tak open', () async {
              final picked = await _pickDateTime(_deadline ?? _start);
              if (picked != null) setState(() => _deadline = picked);
            }, optional: true),
            const SizedBox(height: 10),
            _dateRow('Lobby opens', _lobby, 'Set nahi — start se 30 min pehle', () async {
              final picked = await _pickDateTime(_lobby ?? _start);
              if (picked != null) setState(() => _lobby = picked);
            }, optional: true),
            _section('Game details'),
            if (maps.isNotEmpty) ...[
              DropdownButtonFormField<String>(
                value: _selectedMap,
                dropdownColor: kCard,
                style: TextStyle(color: kText),
                decoration: InputDecoration(
                  labelText: 'Map',
                  labelStyle: TextStyle(color: kMuted),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: kGold.withOpacity(0.35))),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: kGold)),
                ),
                hint: Text('Map select karen', style: TextStyle(color: kMuted)),
                items: maps.map((m) => DropdownMenuItem<String>(value: m, child: Text(m))).toList(),
                onChanged: (v) => setState(() => _selectedMap = v),
              ),
              const SizedBox(height: 10),
              field(controller: _mapText, label: 'Ya apna map likhen (optional)'),
            ] else
              field(controller: _mapText, label: 'Map (optional)'),
            const SizedBox(height: 10),
            field(controller: _rules, label: 'Rules / description', maxLines: 4),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: field(controller: _fee, label: 'Entry fee (Rs)', keyboardType: TextInputType.number)),
              const SizedBox(width: 10),
              Expanded(child: field(controller: _prize, label: 'Prize pool (Rs)', keyboardType: TextInputType.number)),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: field(controller: _perKill, label: 'Per-kill prize (Rs)', keyboardType: TextInputType.number)),
              const SizedBox(width: 10),
              Expanded(child: field(controller: _max, label: 'Max players', keyboardType: TextInputType.number)),
            ]),
            const SizedBox(height: 10),
            field(controller: _levelReq, label: 'Minimum level (0 = koi limit nahi)', keyboardType: TextInputType.number),
            _section('Prize split (total 100% hona chahiye)'),
            Row(children: [
              Expanded(child: field(controller: _split1, label: '1st %', keyboardType: TextInputType.number)),
              const SizedBox(width: 10),
              Expanded(child: field(controller: _split2, label: '2nd %', keyboardType: TextInputType.number)),
              const SizedBox(width: 10),
              Expanded(child: field(controller: _split3, label: '3rd %', keyboardType: TextInputType.number)),
            ]),
            if (!splitOk) Text('Split ka total 100% hona chahiye.', style: TextStyle(color: Colors.red, fontSize: 12)),
            _section('Banner'),
            if (_bannerUrl != null && _bannerUrl!.isNotEmpty)
              ClipRRect(borderRadius: BorderRadius.circular(12), child: ArenaCachedImage(imageUrl: _bannerUrl!, height: 150, width: double.infinity))
            else
              Container(
                height: 90,
                width: double.infinity,
                decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kGold.withOpacity(0.35))),
                child: Center(child: Text('Koi banner nahi — optional', style: TextStyle(color: kMuted))),
              ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: goldButton(label: _bannerBusy ? 'Uploading…' : 'Banner Upload', onPressed: _bannerBusy ? null : _pickBanner)),
              if (_bannerUrl != null && _bannerUrl!.isNotEmpty) ...[
                const SizedBox(width: 10),
                TextButton(onPressed: () => setState(() => _bannerUrl = null), child: Text('Remove', style: TextStyle(color: Colors.red))),
              ],
            ]),
            _section('Format'),
            Row(children: [
              for (final m in ['Solo', 'Duo', 'Squad'])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(m),
                    selected: _mode == m,
                    selectedColor: kGold,
                    labelStyle: TextStyle(color: _mode == m ? Colors.black : kText),
                    onSelected: (_) => setState(() => _mode = m),
                  ),
                ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              for (final p in ['', 'TPP', 'FPP'])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(p.isEmpty ? 'Any view' : p),
                    selected: _perspective == p,
                    selectedColor: kGold,
                    labelStyle: TextStyle(color: _perspective == p ? Colors.black : kText),
                    onSelected: (_) => setState(() => _perspective = p),
                  ),
                ),
            ]),
            SwitchListTile(
              value: _clanWar,
              activeColor: kGold,
              title: Text('Clan War tournament', style: TextStyle(color: kText)),
              subtitle: Text('Clan-vs-clan format', style: TextStyle(color: kMuted, fontSize: 12)),
              onChanged: (v) => setState(() => _clanWar = v),
            ),
            SwitchListTile(
              value: _streamerHosted,
              activeColor: kGold,
              title: Text('Streamer-hosted', style: TextStyle(color: kText)),
              subtitle: Text('Is tournament ko streamer-hosted tag milega', style: TextStyle(color: kMuted, fontSize: 12)),
              onChanged: (v) => setState(() => _streamerHosted = v),
            ),
            _section('Admin commission & funding'),
            MockupCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (fee <= 0)
                    Text('FREE tournament — bilkul free: no creation fee, no player fee, no commission.', style: TextStyle(color: kText, fontWeight: FontWeight.bold))
                  else ...[
                    Text('Collectable (fee x max players): ${fmtRs(collectable)}', style: TextStyle(color: kText)),
                    Text('Platform commission (10%): ${fmtRs(commission)}', style: TextStyle(color: kText)),
                    Text('Prize pool ke liye: ${fmtRs(collectable - commission)}', style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
                  ],
                  if (fee > 0 && prize > collectable)
                    Text('Warning: prize pool (Rs ${prize.toStringAsFixed(0)}) entry fees se zyada hai — admin approval par ye warning dikhegi.',
                        style: TextStyle(color: Colors.red, fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            goldButton(label: 'Create Tournament', onPressed: _create, busy: _busy),
            const SizedBox(height: 8),
            Text(
              'Workflow: aap create karen → status Pending → admin approve karega → live → players join karen ge → result → prize. Creator apne tournament mein join nahi kar sakta. Free tournament bilkul free hota hai.',
              style: TextStyle(color: kMuted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// N-create-tournament PREP-FIRST (2026-11-20): prize-split amounts
/// for the runbook payout preview. Pure function (unit-tested).
/// [prizePool] x [first/second/third]% -> [first, second, third] Rs.
List<double> splitAmounts(double prizePool, int first, int second, int third) {
  double round2(double v) => (v * 100).round() / 100;
  return [round2(prizePool * first / 100), round2(prizePool * second / 100), round2(prizePool * third / 100)];
}

enum _CheckState { pass, fail, info }

class _RunbookCheck {
  final String title;
  final String detail;
  final _CheckState state;
  final String? action;
  const _RunbookCheck({required this.title, required this.detail, required this.state, this.action});
}

/// NO-SHOW RULE (user decision, voice call 2026-11-20 ~18:36 PKT):
///   jo player time pe nahi aaya, match 5–10 minute delay hoga
///   (grace period, [kNoShowGraceMinutes] = 10). Agar uske baad bhi
///   nahi aaya to uski entry fee WAPAS NAHI hogi — gayi to gayi,
///   FORFEIT. Koi refund nahi. Ye procedural hai (organizer wait
///   karta hai, koi automatic match-delay timer nahi hai) aur forfeit
///   code me pehle se sach hai: registration remove karne par koi
///   refund nahi hota (AdminDbTournaments.removeRegistration) aur
///   refunds sirf rejected withdrawals ke liye hain (admin_cash).
///   No-show player ki result kabhi approve nahi hoti, is liye usko
///   prize bhi nahi milta (runbook "No-show handling" check).
const int kNoShowGraceMinutes = 10;

/// N-create-tournament PREP-FIRST (2026-11-20, user standing principle):
/// NOTHING about running a tournament may be figured out after launch.
/// The Organizer Runbook prepares everything IN ADVANCE, inside Admin
/// Mode: BEFORE (approve, funding, split, schedule, slots, room),
/// DURING (check-in, no-shows, result intake), AFTER (verify, auto
/// prize distribution, dispute window). Every step is CHECKABLE:
/// automatic checks are computed LIVE from the database (green = done,
/// red = blocked, grey = info), and the three human-judgment steps are
/// manual checkboxes saved on the admin's device. The payout preview
/// at the top answers BEFORE the tournament starts: result kaise
/// banega (auto from verified results) aur kisko kitne paise milenge
/// (prize split + commission). GAPS (honest, also in the checkpoint):
/// no-show players ko remove karne ka button abhi nahi hai, aur room
/// credentials admin set nahi karta — system lobby open hote hi
/// auto-release karta hai (get_room_credentials). NO-SHOW RULE (user
/// decision 2026-11-20 ~18:36 PKT): $kNoShowGraceMinutes minute grace
/// delay, phir entry fee forfeit, koi refund nahi — see
/// [kNoShowGraceMinutes] and the "No-show handling" check below.
class OrganizerRunbookPage extends StatefulWidget {
  final String tournamentId;
  final String uid;
  const OrganizerRunbookPage({super.key, required this.tournamentId, required this.uid});
  @override
  State<OrganizerRunbookPage> createState() => _OrganizerRunbookPageState();
}

class _OrganizerRunbookPageState extends State<OrganizerRunbookPage> {
  Map<String, dynamic> _t = {};
  List<Map<String, dynamic>> _regs = [];
  List<Map<String, dynamic>> _checkins = [];
  List<Map<String, dynamic>> _results = [];
  List<Map<String, dynamic>> _payouts = [];
  List<Map<String, dynamic>> _disputes = [];
  double _commissionRecorded = 0;
  bool _busy = true;
  // Manual confirmations (human-judgment steps), device-local.
  bool _roomShared = false;
  bool _noshowDone = false;
  bool _disputeClosed = false;
  // ADMIN GATE (2026-11-20 fix): _verify() and _load() used to run
  // CONCURRENTLY in initState, so a non-admin could see the full
  // runbook (payouts, disputes, registrations) flash — and that
  // sensitive data LOAD — before the toast+pop landed. The guard was
  // toothless. Now _init() awaits verification FIRST; _load() runs
  // and the body renders only when _verified is true, so a player
  // never sees — or loads — any runbook content.
  bool _verified = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final ok = await _verify();
    if (!mounted || !ok) return;
    setState(() => _verified = true);
    _load();
  }

  Future<bool> _verify() async {
    final adminUid = await _designatedAdminUid();
    if (!mounted) return false;
    if (widget.uid.isEmpty || adminUid.isEmpty || widget.uid != adminUid) {
      toast(context, 'Sirf admin runbook dekh sakta hai.');
      Navigator.pop(context);
      return false;
    }
    return true;
  }

  String _prefKey(String step) => 'runbook:${widget.tournamentId}:$step';

  Future<void> _loadManual() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() {
          _roomShared = prefs.getBool(_prefKey('room_shared')) ?? false;
          _noshowDone = prefs.getBool(_prefKey('noshow_done')) ?? false;
          _disputeClosed = prefs.getBool(_prefKey('dispute_closed')) ?? false;
        });
      }
    } catch (_) {}
  }

  Future<void> _setManual(String step, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey(step), value);
    } catch (_) {}
    if (mounted) {
      setState(() {
        if (step == 'room_shared') _roomShared = value;
        if (step == 'noshow_done') _noshowDone = value;
        if (step == 'dispute_closed') _disputeClosed = value;
      });
    }
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    _loadManual();
    final t = await SupaDb.getTournament(widget.tournamentId);
    final regs = await SupaDb.getRegistrations(widget.tournamentId);
    final checkins = await SupaDb.getList('match_checkins', eqCol: 'tournament_id', eqVal: widget.tournamentId);
    final results = await SupaDb.getTournamentResults(widget.tournamentId);
    final payouts = await SupaDb.getList('tournament_payouts', eqCol: 'tournament_id', eqVal: widget.tournamentId);
    final disputes = await SupaDb.getList('disputes', eqCol: 'tournament_id', eqVal: widget.tournamentId);
    var commission = 0.0;
    try {
      final rows = await SupaDb.getList('transactions', eqCol: 'type', eqVal: 'platform_commission', limit: 1000);
      for (final row in rows) {
        if (SupaDb.strOf(row['tournament_id']) == widget.tournamentId) commission += SupaDb.numOf(row['amount']);
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _t = t;
        _regs = regs;
        _checkins = checkins;
        _results = results;
        _payouts = payouts;
        _disputes = disputes;
        _commissionRecorded = commission;
        _busy = false;
      });
    }
  }

  List<_RunbookCheck> get _before {
    final t = _t;
    final status = SupaDb.strOf(t['status']).toLowerCase();
    final fee = SupaDb.numOf(t['entryFee']);
    final prize = SupaDb.numOf(t['prizePool']);
    final maxP = SupaDb.intOf(t['maxPlayers']);
    final pct = SupaDb.numOf(t['commissionPct'], 10);
    final split = SupaDb.asMap(t['prizeDistribution']);
    final s1 = SupaDb.intOf(split['first'], 50);
    final s2 = SupaDb.intOf(split['second'], 30);
    final s3 = SupaDb.intOf(split['third'], 20);
    final startMs = SupaDb.parseTs(t['start_time'] ?? t['startTime']);
    final deadlineMs = SupaDb.parseTs(t['registration_deadline'] ?? t['registrationDeadline']);
    final lobbyMs = SupaDb.parseTs(t['lobby_opens_at'] ?? t['lobbyOpensAt']);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final approved = status == 'upcoming' || status == 'live' || status == 'ongoing';
    final collectable = maxCollectable(fee, maxP);
    return [
      _RunbookCheck(
        title: 'Tournament approved & live',
        detail: approved ? 'Status: ${status.toUpperCase()} — players join kar sakte hain.' : 'Status: ${status.toUpperCase()} — abhi live nahi hai.',
        state: approved ? _CheckState.pass : (status == 'cancelled' ? _CheckState.fail : _CheckState.fail),
        action: approved ? null : 'Tournament Approvals me approve karen.',
      ),
      _RunbookCheck(
        title: 'Prize funding verified',
        detail: fee <= 0
            ? 'FREE tournament — prize sponsor-funded hai, funding check nahi lagta.'
            : 'Collectable ${fmtRs(collectable)} (fee x $maxP) - commission ${fmtRs(platformCommissionFor(collectable, pct))} = ${fmtRs(collectable - platformCommissionFor(collectable, pct))} available; prize pool ${fmtRs(prize)}.',
        state: fee <= 0
            ? _CheckState.info
            : (prizeFundable(prizePool: prize, entryFee: fee, maxPlayers: maxP, commissionPct: pct) ? _CheckState.pass : _CheckState.fail),
        action: fee > 0 && !prizeFundable(prizePool: prize, entryFee: fee, maxPlayers: maxP, commissionPct: pct)
            ? 'Prize pool kam karen ya entry fee / slots barhayen — warna approve nahi hoga.'
            : null,
      ),
      _RunbookCheck(
        title: 'Prize split totals 100%',
        detail: '1st $s1% • 2nd $s2% • 3rd $s3% = ${s1 + s2 + s3}%.',
        state: prizeSplitValid(s1, s2, s3) ? _CheckState.pass : _CheckState.fail,
        action: prizeSplitValid(s1, s2, s3) ? null : 'Split theek karen — total 100% hona chahiye.',
      ),
      _RunbookCheck(
        title: 'Commission rule set',
        detail: fee <= 0 ? 'FREE tournament — koi commission nahi.' : 'Platform commission ${pct.toStringAsFixed(0)}% har paid entry par.',
        state: _CheckState.pass,
      ),
      _RunbookCheck(
        title: 'Schedule set',
        detail: startMs > 0
            ? 'Start: ${_fmtDT(DateTime.fromMillisecondsSinceEpoch(startMs))}${deadlineMs > 0 ? ' • Deadline set hai' : ' • Deadline set nahi (start tak open)'}${lobbyMs > 0 ? ' • Lobby set hai' : ' • Lobby set nahi'}'
            : 'Start time set nahi hai.',
        state: startMs > 0 ? (startMs > nowMs ? _CheckState.pass : _CheckState.info) : _CheckState.fail,
        action: startMs > 0 ? null : 'Start date/time set karen.',
      ),
      _RunbookCheck(
        title: 'Game, map & banner',
        detail:
            'Game: ${SupaDb.strOf(t['gameName']).isEmpty ? '—' : SupaDb.strOf(t['gameName'])} • Map: ${SupaDb.strOf(t['map']).isEmpty ? 'set nahi (optional)' : SupaDb.strOf(t['map'])} • Banner: ${SupaDb.strOf(t['banner']).isEmpty ? 'nahi (optional)' : 'set hai'}',
        state: SupaDb.strOf(t['gameName']).isEmpty ? _CheckState.fail : _CheckState.pass,
        action: SupaDb.strOf(t['gameName']).isEmpty ? 'Game select karen.' : null,
      ),
      _RunbookCheck(
        title: 'Slots',
        detail: '${_regs.length} / $maxP slots filled.',
        state: _CheckState.info,
      ),
      _RunbookCheck(
        title: 'Room credentials ready',
        detail: (t['show_id_pass'] == true || lobbyMs > 0)
            ? 'Lobby open hote hi system credentials auto-release karega (get_room_credentials).'
            : 'Lobby time set nahi — credentials kab release honge, ye tay nahi.',
        state: (t['show_id_pass'] == true || lobbyMs > 0) ? _CheckState.pass : _CheckState.fail,
        action: (t['show_id_pass'] == true || lobbyMs > 0) ? null : 'Lobby opens time set karen.',
      ),
    ];
  }

  List<_RunbookCheck> get _during {
    final checkedIn = _checkins.map((c) => SupaDb.strOf(c['firebase_uid'])).toSet();
    final noShow = _regs.where((r) => !checkedIn.contains(SupaDb.strOf(r['firebase_uid']))).length;
    final submitted = _results.where((r) => SupaDb.strOf(r['status']).toLowerCase() == 'submitted').length;
    return [
      _RunbookCheck(
        title: 'Check-in window',
        detail: '${checkedIn.length} / ${_regs.length} players checked in (Match Check-in se).',
        state: _CheckState.info,
      ),
      _RunbookCheck(
        title: 'No-show handling',
        detail: '$noShow player(s) ne check-in nahi kiya. RULE (user decision 2026-11-20): match $kNoShowGraceMinutes minute delay karen (grace period); phir bhi na aaye to entry fee FORFEIT — wapas nahi hogi, koi refund nahi. GAP: no-show ko remove karne ka button abhi nahi hai — unki result approve nahi hogi to prize bhi nahi milega.',
        state: noShow > 0 ? _CheckState.info : _CheckState.pass,
      ),
      _RunbookCheck(
        title: 'Result intake',
        detail: '$submitted result(s) submitted, ${_results.where((r) => SupaDb.strOf(r['status']).toLowerCase() == 'approved').length} approved.',
        state: _CheckState.info,
        action: submitted > 0 ? 'Result Reviews me verify karen.' : null,
      ),
    ];
  }

  List<_RunbookCheck> get _after {
    final t = _t;
    final fee = SupaDb.numOf(t['entryFee']);
    final pct = SupaDb.numOf(t['commissionPct'], 10);
    final submitted = _results.where((r) => SupaDb.strOf(r['status']).toLowerCase() == 'submitted').length;
    final approved = _results.where((r) => SupaDb.strOf(r['status']).toLowerCase() == 'approved').length;
    final paidUids = _payouts.map((p) => SupaDb.strOf(p['firebase_uid'])).toSet();
    final allPaid = _regs.isNotEmpty && _regs.every((r) => paidUids.contains(SupaDb.strOf(r['firebase_uid'])));
    // P0-1: entry fee x PLAYERS (not rows x teamSize — RPC rows
    // are one-per-member, legacy rows one-per-team).
    final collected = fee * SupaDb.registrationPlayerCount(_regs);
    final expectedCommission = (collected * pct / 100 * 100).round() / 100;
    final openDisputes = _disputes.where((d) => SupaDb.strOf(d['status']).toLowerCase() == 'open').length;
    return [
      _RunbookCheck(
        title: 'Results verified',
        detail: '$approved / ${_results.length} results approved ($submitted abhi pending).',
        state: _results.isNotEmpty && submitted == 0 && approved > 0 ? _CheckState.pass : _CheckState.info,
        action: submitted > 0 ? 'Result Reviews me baaki verify karen.' : null,
      ),
      _RunbookCheck(
        title: 'Auto prize distribution',
        detail: '${_payouts.length} / ${_regs.length} players ko payout record mila; winnings_credited: ${t['winnings_credited'] == true ? 'YES' : 'NO'}.',
        state: allPaid ? _CheckState.pass : _CheckState.info,
        action: allPaid ? null : 'Baaki results approve karte hi payout automatic ho jayega.',
      ),
      _RunbookCheck(
        title: 'Commission recorded',
        detail: fee <= 0
            ? 'FREE tournament — koi commission nahi.'
            : 'Recorded ${fmtRs(_commissionRecorded)} / expected ${fmtRs(expectedCommission)} (collected ${fmtRs(collected)} par ${pct.toStringAsFixed(0)}%).',
        state: fee <= 0
            ? _CheckState.info
            : (_commissionRecorded + 0.009 >= expectedCommission ? _CheckState.pass : _CheckState.info),
      ),
      _RunbookCheck(
        title: 'Dispute window',
        detail: '$openDisputes open dispute(s).',
        state: openDisputes == 0 ? _CheckState.pass : _CheckState.info,
        action: openDisputes > 0 ? 'Disputes & Reports me resolve karen.' : null,
      ),
    ];
  }

  Widget _checkTile(_RunbookCheck c) {
    final icon = c.state == _CheckState.pass
        ? Icons.check_circle
        : c.state == _CheckState.fail
            ? Icons.cancel
            : Icons.info;
    final color = c.state == _CheckState.pass
        ? Colors.green
        : c.state == _CheckState.fail
            ? Colors.red
            : kMuted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MockupCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.title, style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
                  Text(c.detail, style: TextStyle(color: kMuted, fontSize: 12)),
                  if (c.action != null) Text(c.action!, style: TextStyle(color: kGold, fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Align(alignment: Alignment.centerLeft, child: Text(title, style: TextStyle(color: kSectionLabel, fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1))),
      );

  Widget _manualTile(String title, bool value, ValueChanged<bool?> onChanged) => MockupCard(
        child: CheckboxListTile(
          value: value,
          activeColor: kGold,
          checkColor: Colors.black,
          title: Text(title, style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
          subtitle: Text('Manual confirmation — admin ke device par save hota hai.', style: TextStyle(color: kMuted, fontSize: 12)),
          onChanged: onChanged,
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final fee = SupaDb.numOf(t['entryFee']);
    final prize = SupaDb.numOf(t['prizePool']);
    final split = SupaDb.asMap(t['prizeDistribution']);
    final s1 = SupaDb.intOf(split['first'], 50);
    final s2 = SupaDb.intOf(split['second'], 30);
    final s3 = SupaDb.intOf(split['third'], 20);
    final amounts = splitAmounts(prize, s1, s2, s3);
    final autoChecks = [..._before, ..._during, ..._after];
    final passed = autoChecks.where((c) => c.state == _CheckState.pass).length;
    return Scaffold(
      appBar: AppBar(title: Text('Organizer Runbook', style: TextStyle(color: kGold))),
      // ADMIN GATE: nothing renders until _verified — a non-admin
      // sees only a spinner, then the toast + pop. No runbook
      // content (payouts, disputes, checklists) ever flashes.
      body: !_verified || _busy
          ? Center(child: CircularProgressIndicator(color: kGold))
          : _t.isEmpty
              ? ListView(padding: const EdgeInsets.all(16), children: [proEmpty('Tournament nahi mila.')])
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    MockupCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Expanded(child: Text(SupaDb.strOf(t['name']), style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 18))),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(color: kGold, borderRadius: BorderRadius.circular(20)),
                              child: Text(SupaDb.strOf(t['status']).toUpperCase(), style: TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold)),
                            ),
                          ]),
                          Text('${SupaDb.strOf(t['gameName'])} • ${SupaDb.strOf(t['mode'])}', style: TextStyle(color: kMuted, fontSize: 12)),
                          const SizedBox(height: 6),
                          Text('Auto checks: $passed / ${autoChecks.length} pass', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                    _section('Payout preview — kisko kitne paise milenge (shuru se tay)'),
                    MockupCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Prize pool: ${fmtRs(prize)}', style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
                          Text('1st ($s1%): ${fmtRs(amounts[0])}  •  2nd ($s2%): ${fmtRs(amounts[1])}  •  3rd ($s3%): ${fmtRs(amounts[2])}', style: TextStyle(color: kText)),
                          Text('Per-kill prize: ${fmtRs(SupaDb.numOf(t['perKillPrize']))} har kill par (jeetne wale ko kills x per-kill + placement bonus).', style: TextStyle(color: kText)),
                          if (fee > 0)
                            Text(
                              'Platform commission: ${SupaDb.numOf(t['commissionPct'], 10).toStringAsFixed(0)}% har entry par (prize pool se pehle kat-ti hai).',
                              style: TextStyle(color: kText),
                            )
                          else
                            Text('FREE tournament — koi commission nahi.', style: TextStyle(color: kText)),
                          Text('Result kaise banega: player screenshot + placement submit karega → admin verify karega → approve hote hi prize automatic credit hoga. Live game kills dekhna possible nahi (PUBG ki koi public API nahi) — is liye screenshot + admin check hi verification hai.',
                              style: TextStyle(color: kMuted, fontSize: 12)),
                        ],
                      ),
                    ),
                    _section('BEFORE — tournament shuru hone se pehle'),
                    for (final c in _before) _checkTile(c),
                    _manualTile('Room ID/password players ko bhej diya', _roomShared, (v) => _setManual('room_shared', v ?? false)),
                    _section('DURING — match chal raha hai'),
                    for (final c in _during) _checkTile(c),
                    _manualTile('No-show players handle kar liye', _noshowDone, (v) => _setManual('noshow_done', v ?? false)),
                    _section('AFTER — match khatm, prize & disputes'),
                    for (final c in _after) _checkTile(c),
                    _manualTile('Dispute window band kar di', _disputeClosed, (v) => _setManual('dispute_closed', v ?? false)),
                    const SizedBox(height: 8),
                    Text('Note: manual confirmations admin ke device par save hoti hain. Auto checks har dafa database se live bante hain.',
                        style: TextStyle(color: kMuted, fontSize: 12)),
                  ],
                ),
    );
  }
}

/// N-create-tournament PREP-FIRST: runbook tournament picker (Admin
/// Mode). Lists all non-cancelled tournaments, newest start first;
/// tap one to open its Organizer Runbook.
class RunbookPickerPage extends StatefulWidget {
  final String uid;
  const RunbookPickerPage({super.key, required this.uid});
  @override
  State<RunbookPickerPage> createState() => _RunbookPickerPageState();
}

class _RunbookPickerPageState extends State<RunbookPickerPage> {
  List<Map<String, dynamic>> _rows = [];
  bool _busy = true;
  // ADMIN GATE (2026-11-20 fix): same toothless-guard fix as
  // OrganizerRunbookPage — _verify() and _load() used to run
  // concurrently, so the tournament list could flash for a
  // non-admin before the pop. _load() now runs only after
  // verification, and the body renders only when _verified.
  bool _verified = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final ok = await _verify();
    if (!mounted || !ok) return;
    setState(() => _verified = true);
    _load();
  }

  Future<bool> _verify() async {
    final adminUid = await _designatedAdminUid();
    if (!mounted) return false;
    if (widget.uid.isEmpty || adminUid.isEmpty || widget.uid != adminUid) {
      toast(context, 'Sirf admin runbook dekh sakta hai.');
      Navigator.pop(context);
      return false;
    }
    return true;
  }

  Future<void> _load() async {
    final all = await SupaDb.getTournaments();
    final rows = all.where((t) => SupaDb.strOf(t['status']).toLowerCase() != 'cancelled').toList();
    rows.sort((a, b) => SupaDb.parseTs(b['start_time'] ?? b['startTime']).compareTo(SupaDb.parseTs(a['start_time'] ?? a['startTime'])));
    if (mounted) {
      setState(() {
        _rows = rows;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Organizer Runbook', style: TextStyle(color: kGold))),
      // ADMIN GATE: nothing renders until _verified — a non-admin
      // sees only a spinner, then the toast + pop.
      body: !_verified || _busy
          ? Center(child: CircularProgressIndicator(color: kGold))
          : _rows.isEmpty
              ? ListView(padding: const EdgeInsets.all(16), children: [proEmpty('Koi tournament nahi hai.')])
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _rows.length,
                  itemBuilder: (context, i) {
                    final t = _rows[i];
                    final startMs = SupaDb.parseTs(t['start_time'] ?? t['startTime']);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: MockupCard(
                        child: InkWell(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => OrganizerRunbookPage(tournamentId: SupaDb.strOf(t['id']), uid: widget.uid)),
                          ),
                          child: Row(children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(SupaDb.strOf(t['name']), style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
                                  Text('${SupaDb.strOf(t['gameName'])} • ${SupaDb.strOf(t['status']).toUpperCase()}${startMs > 0 ? ' • ${_fmtDT(DateTime.fromMillisecondsSinceEpoch(startMs))}' : ''}',
                                      style: TextStyle(color: kMuted, fontSize: 12)),
                                ],
                              ),
                            ),
                            Icon(Icons.chevron_right, color: kGold),
                          ]),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}


/// ---------------- DISPUTES & REPORTS ----------------

class DisputeReportHubPage extends StatelessWidget {
  final String uid;
  const DisputeReportHubPage({super.key, required this.uid});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Disputes & Reports', style: TextStyle(color: kGold))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          MockupCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Raise a Dispute', style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 16)),
                Text('Match result ya kill count par aitraaz ho to dispute raise karen. Admin verification queue me jayega.', style: TextStyle(color: kMuted, fontSize: 12)),
                const SizedBox(height: 10),
                goldButton(label: 'Raise Dispute', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DisputePage(uid: uid)))),
              ],
            ),
          ),
          const SizedBox(height: 12),
          MockupCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Report a Player', style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 16)),
                Text('Cheating, abuse ya suspicious activity report karen. Report admin ko jayega; block karne se us player ke messages aapko nahi dikhenge.', style: TextStyle(color: kMuted, fontSize: 12)),
                const SizedBox(height: 10),
                goldButton(label: 'Report / Block Player', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ReportPage(uid: uid)))),
              ],
            ),
          ),
          const SizedBox(height: 12),
          MockupCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Fair Play Policy', style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 16)),
                Text('• No hacks, mods ya emulator abuse\n• No teaming with opponents in Solo\n• No fake screenshots — result proof verify hota hai\n• 3 warnings ke baad account ban ho sakta hai (admin decision)\n• Duplicate accounts (ek device, kayi accounts) flag hote hain', style: TextStyle(color: kMuted, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DisputePage extends StatefulWidget {
  final String uid;

  /// #16: optional deep-link — when a tournament screen opens this
  /// page for ONE tournament, its id (and name when already known)
  /// pre-select the tournament card below, so the player never has
  /// to pick it by hand. Null = the old behaviour (latest filed
  /// dispute's tournament, else the placeholder card).
  final String? tournamentId;
  final String? tournamentName;
  const DisputePage(
      {super.key,
      required this.uid,
      this.tournamentId,
      this.tournamentName});
  @override
  State<DisputePage> createState() => _DisputePageState();
}

class _DisputePageState extends State<DisputePage> {
  final _description = TextEditingController();
  String _issueType = 'Incorrect Placement';
  File? _evidence;
  String? _evidenceUrl;
  bool _uploading = false;
  bool _submitting = false;
  List<Map<String, dynamic>> _mine = [];
  bool _busy = true;
  bool _pending = false;
  String? _error;
  // Mockup #2 "Tournament Details" card: the dispute is about ONE
  // tournament, shown in the card — there is no free-text tournament
  // field in the mockup. The card IS the selector: tap it to pick
  // from the live tournament list. Default selection is the latest
  // filed dispute's tournament (when one exists); a first-time user
  // sees the placeholder card and taps to choose.
  Map<String, dynamic>? _tournamentInfo;
  String _selectedTournamentId = '';
  List<Map<String, dynamic>> _allTournaments = [];

  // Mockup #2 issue types, element-for-element. The type is stored
  // in the real `disputes.issue_type` column (verified live on
  // production 2026-11-22 via anon PostgREST probe: 200) — see
  // _raise. Evidence goes in `disputes.evidence_url` the same way.
  static const _issueTypes = [
    'Incorrect Placement',
    'Missing Player',
    'Incorrect Match Statistics',
    'Other',
  ];

  @override
  void initState() {
    super.initState();
    // Live 0/500 counter for the description field.
    _description.addListener(() {
      if (mounted) setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _mine = await SupaDb.getList('disputes', eqCol: 'raised_by', eqVal: widget.uid, orderBy: 'created_at', ascending: false);
      // Live tournament list, cached once for the card picker and
      // for resolving the latest dispute's tournament. A miss leaves
      // _tournamentInfo null — never invented.
      try {
        _allTournaments = await SupaDb.getTournaments();
      } catch (_) {
        _allTournaments = [];
      }
      // #16: caller-supplied tournament wins over the latest-dispute
      // default below. Resolve it against the live list first (real
      // name/date/mode/banner on the card); when it matches no live
      // row, keep the caller-supplied name if one was given (real
      // caller data, not invented), else the raw id — the same
      // fallback the typed-ID path already uses.
      final preselectId = (widget.tournamentId ?? '').trim();
      if (preselectId.isNotEmpty) {
        final lower = preselectId.toLowerCase();
        for (final t in _allTournaments) {
          if (SupaDb.strOf(t['id']).toLowerCase() == lower ||
              SupaDb.strOf(t['name']).toLowerCase() == lower) {
            _tournamentInfo = t;
            _selectedTournamentId = SupaDb.strOf(t['id'], preselectId);
            break;
          }
        }
        if (_tournamentInfo == null) {
          final preselectName = (widget.tournamentName ?? '').trim();
          if (preselectName.isNotEmpty) {
            _tournamentInfo = {'id': preselectId, 'name': preselectName};
            _selectedTournamentId = preselectId;
          } else {
            _selectedTournamentId = preselectId;
          }
        }
      }
      if (_selectedTournamentId.isEmpty && _mine.isNotEmpty) {
        final typed = SupaDb.strOf(_mine.first['tournament_id']).trim();
        if (typed.isNotEmpty) {
          final lower = typed.toLowerCase();
          for (final t in _allTournaments) {
            if (SupaDb.strOf(t['id']).toLowerCase() == lower || SupaDb.strOf(t['name']).toLowerCase() == lower) {
              _tournamentInfo = t;
              _selectedTournamentId = SupaDb.strOf(t['id'], typed);
              break;
            }
          }
          // Typed ID matches no live tournament: keep the typed ID
          // as the selection so the card still names it.
          if (_tournamentInfo == null) _selectedTournamentId = typed;
        }
      }
    } catch (e) {
      // Defensive only: getList swallows read errors, so a throw here
      // means the table itself is missing.
      if (proTableMissing(e)) {
        _pending = true;
      } else if (_isOfflineError(e)) {
        _error = 'offline';
      } else {
        _error = 'Disputes load nahi ho sake: $e';
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Mockup #2 card-as-selector: pick the disputed tournament from
  /// the live list (newest first). Real rows only.
  Future<void> _pickTournament() async {
    if (_allTournaments.isEmpty) {
      toast(context, 'Koi tournament nahi mila — pehle tournaments load karen.');
      return;
    }
    final reversed = _allTournaments.reversed.toList();
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text('Tournament chunen', style: TextStyle(color: kGold)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: reversed.length,
            itemBuilder: (context, i) {
              final t = reversed[i];
              final id = SupaDb.strOf(t['id']);
              final selected = id.isNotEmpty && id == _selectedTournamentId;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(SupaDb.strOf(t['name'], 'Tournament'), style: TextStyle(color: selected ? kGold : kText, fontWeight: selected ? FontWeight.bold : FontWeight.normal)),
                subtitle: Text(
                  SupaDb.intOf(t['startTime']) > 0 ? '${_fmtShortWhen(SupaDb.intOf(t['startTime']))}  •  ${SupaDb.strOf(t['mode'], 'Solo').toUpperCase()}' : SupaDb.strOf(t['mode'], 'Solo').toUpperCase(),
                  style: TextStyle(color: kMuted, fontSize: 12),
                ),
                trailing: selected ? Icon(Icons.check, color: kGold) : null,
                onTap: () => Navigator.pop(context, t),
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel', style: TextStyle(color: kMuted))),
        ],
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _tournamentInfo = picked;
        _selectedTournamentId = SupaDb.strOf(picked['id'], SupaDb.strOf(picked['name']));
      });
    }
  }

  /// Mockup #2 "Tournament Details" card: always visible, tappable
  /// selector (see _pickTournament). Shows the selected live
  /// tournament (real name / date / mode + banner), the typed ID when
  /// it matches no live tournament, or the placeholder for a
  /// first-time user. Never an invented name.
  Widget _tournamentCard() {
    final info = _tournamentInfo;
    final title = info != null
        ? SupaDb.strOf(info['name'], _selectedTournamentId)
        : _selectedTournamentId.isNotEmpty
            ? _selectedTournamentId
            : 'Tournament select karen';
    final subtitle = info != null && SupaDb.intOf(info['startTime']) > 0
        ? '${_fmtShortWhen(SupaDb.intOf(info['startTime']))}  •  ${SupaDb.strOf(info['mode'], 'Solo').toUpperCase()}'
        : info != null
            ? SupaDb.strOf(info['mode'], 'Solo').toUpperCase()
            : _selectedTournamentId.isNotEmpty
                ? 'Is tournament ki details nahi mili — dobara select karen'
                : 'Card par tap kar ke tournament chunen';
    return InkWell(
      onTap: _pickTournament,
      borderRadius: BorderRadius.circular(16),
      // Mockup #2 tournament card (MockupCard: the 2-line shine, no
      // full border — user correction 2026-11-20).
      child: MockupCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: info != null && SupaDb.strOf(info['banner']).isNotEmpty
                  // Live tournament banner from the backend
                  // (real art, not a mock).
                  ? ArenaCachedImage(imageUrl: SupaDb.strOf(info['banner']), width: 64, height: 64, fit: BoxFit.cover, placeholderIcon: Icons.emoji_events)
                  : Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(12)),
                      child: Icon(Icons.emoji_events, color: kGold, size: 32),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(color: info != null || _selectedTournamentId.isNotEmpty ? kText : kMuted, fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 2),
                  // Mockup #2 subtitle: "Sat, Nov 22 • 8:00 PM |
                  // 👥 SQUAD" — pipe separator + group icon before
                  // the mode (real date + real mode, never invented).
                  if (info != null && SupaDb.intOf(info['startTime']) > 0)
                    RichText(
                      text: TextSpan(
                        style: TextStyle(color: kMuted, fontSize: 12),
                        children: [
                          TextSpan(text: _fmtShortWhen(SupaDb.intOf(info['startTime']))),
                          const TextSpan(text: '  |  '),
                          WidgetSpan(alignment: PlaceholderAlignment.middle, child: Icon(Icons.group, size: 13, color: kMuted)),
                          TextSpan(text: ' ${SupaDb.strOf(info['mode'], 'Solo').toUpperCase()}'),
                        ],
                      ),
                    )
                  else
                    Text(subtitle, style: TextStyle(color: kMuted, fontSize: 12)),
                ],
              ),
            ),
            // Mockup #2: no chevron on the card — the whole card is
            // the picker (tappable via the InkWell above).
          ],
        ),
      ),
    );
  }

  Future<void> _pickEvidence() async {
    final res = await _pickEvidenceImage();
    if (res.error != null) {
      if (mounted) toast(context, res.error!);
      return;
    }
    if (res.file == null) return;
    setState(() {
      _evidence = res.file;
      _evidenceUrl = null;
    });
  }

  /// Phase 3 #2 — dispute filing (Batch 3B, 2026-11-22).
  /// The picked issue type + ImgBB evidence URL are written to the
  /// REAL `disputes.issue_type` / `disputes.evidence_url` columns
  /// (verified live on production 2026-11-22: anon PostgREST probe
  /// `disputes?select=issue_type,evidence_url` returned 200; draft
  /// 076 adds the same columns + the flag_result_disputed RPC for
  /// staging). If a backend without those columns ever rejects the
  /// insert (PGRST204 / 42703 naming issue_type/evidence_url), the
  /// code falls back to the old fold-into-`reason` insert so filing
  /// still works — never a silent drop.
  /// Filing also flags the linked `tournament_results` row as
  /// 'disputed' via a direct status update (best-effort: the draft
  /// 076 RPC is NOT applied, so it is deliberately NOT called as
  /// the primary path). A failed flag never fails the filing; the
  /// toast says so honestly. No result row for this tournament =
  /// nothing to flag (the dispute still files).
  /// VIDEO evidence (MP4): BLOCKED — there is no live video host, so
  /// no video picker is shown; photo evidence (JPG/PNG) only.
  Future<void> _raise() async {
    // Wave 4b #2: description is genuinely optional — the mockup
    // labels it "(optional)" — so only the tournament ID/name is
    // required. An empty description still files (empty reason —
    // the issue type lives in its own column now).
    final desc = _description.text.trim();
    if (_selectedTournamentId.isEmpty) {
      toast(context, 'Tournament select karen — upar card par tap karen.');
      return;
    }
    if (desc.length > 500) {
      toast(context, 'Description 500 characters se zyada nahi ho sakti.');
      return;
    }
    setState(() => _submitting = true);
    try {
      var evidenceUrl = _evidenceUrl;
      if (_evidence != null && evidenceUrl == null) {
        setState(() => _uploading = true);
        try {
          evidenceUrl = await ImgbbService.uploadImage(_evidence!);
          if (mounted) setState(() => _evidenceUrl = evidenceUrl);
        } finally {
          if (mounted) setState(() => _uploading = false);
        }
      }
      final profile = await SupaDb.getProfile(widget.uid);
      final reason = desc;
      try {
        // Primary path: real issue_type / evidence_url columns.
        await SupaDb.client.from('disputes').insert({
          'tournament_id': _selectedTournamentId,
          'raised_by': widget.uid,
          'raised_by_name': SupaDb.strOf(profile['displayName'], 'User'),
          'reason': reason,
          'issue_type': _issueType,
          'evidence_url': evidenceUrl,
          'status': 'open',
        }).select('id').single();
      } catch (e) {
        // Fallback ONLY when the backend has no such columns
        // (PGRST204 unknown column / 42703 undefined column naming
        // issue_type or evidence_url): fold type + evidence into
        // `reason` exactly as before, so filing still works.
        // Any other error rethrows to the outer catch below.
        final msg = e.toString();
        final missingColumn = msg.contains('issue_type') || msg.contains('evidence_url') || msg.contains('PGRST204') || msg.contains('42703');
        if (!missingColumn) rethrow;
        var folded = desc.isEmpty ? '[$_issueType]' : '[$_issueType] $desc';
        if (evidenceUrl != null && evidenceUrl.isNotEmpty) {
          folded += '\nEvidence: $evidenceUrl';
        }
        // single() throws on 0 rows, so reaching here means the
        // fallback insert landed.
        await SupaDb.client.from('disputes').insert({
          'tournament_id': _selectedTournamentId,
          'raised_by': widget.uid,
          'raised_by_name': SupaDb.strOf(profile['displayName'], 'User'),
          'reason': folded,
          'status': 'open',
        }).select('id').single();
      }
      // Flag the linked result as disputed (direct update, best
      // effort — the draft-076 RPC is NOT applied, so it is never
      // called here). The linked row is the reporter's latest
      // result for this tournament. A failure here never fails
      // the filing; the toast below says so honestly.
      var flagState = 'flagged';
      try {
        final results = await SupaDb.getList(
          'tournament_results',
          eqCol: 'tournament_id',
          eqVal: _selectedTournamentId,
          eqCol2: 'firebase_uid',
          eqVal2: widget.uid,
          orderBy: 'created_at',
          ascending: false,
          limit: 1,
        );
        if (results.isEmpty) {
          flagState = 'no_result';
        } else {
          final resultId = SupaDb.strOf(results.first['id']);
          final oldStatus = SupaDb.strOf(results.first['status']);
          if (oldStatus == 'disputed') {
            flagState = 'flagged';
          } else if (resultId.isEmpty) {
            flagState = 'failed';
          } else {
            final updated = await SupaDb.client.from('tournament_results').update({'status': 'disputed'}).eq('id', resultId).select('id');
            // A PostgREST UPDATE dropped by RLS returns 0 rows,
            // not an error — an empty result means NOT flagged.
            flagState = (updated as List).isNotEmpty ? 'flagged' : 'failed';
          }
        }
      } catch (_) {
        flagState = 'failed';
      }
      if (mounted) {
        if (flagState == 'flagged') {
          toast(context, 'Dispute raise ho gaya — result disputed mark ho gaya, admin review karega.');
        } else if (flagState == 'no_result') {
          toast(context, 'Dispute raise ho gaya — is tournament ka koi result nahi mila, admin review karega.');
        } else {
          toast(context, 'Dispute raise ho gaya — lekin result disputed mark nahi ho saka, admin review karega.');
        }
      }
      _description.clear();
      setState(() {
        _evidence = null;
        _evidenceUrl = null;
      });
      _load();
    } catch (e) {
      if (mounted) {
        if (proTableMissing(e)) {
          setState(() => _pending = true);
          toast(context, 'Backend pending — migration 008 chalani hogi.');
        } else if (_isOfflineError(e)) {
          setState(() => _error = 'offline');
        } else {
          toast(context, 'Failed: $e');
        }
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 3-step tracker from the real `disputes.status` value.
  /// Live statuses are only 'open' today; Reviewing / Resolved light
  /// up only when an admin sets those statuses.
  int _stepFor(String status) {
    switch (status.toLowerCase()) {
      case 'reviewing':
      case 'in_review':
      case 'under_review':
        return 1;
      case 'resolved':
      case 'closed':
        return 2;
      default:
        return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final descLen = _description.text.length;
    // Tracker reflects the latest filed dispute's real status (mockup
    // #2 shows the Submitted step done). With no dispute yet it sits
    // at the Submitted step.
    final latest = _mine.isEmpty ? null : _mine.first;
    return Scaffold(
      appBar: AppBar(title: _mockAppBarTitle('REPORT RESULT ISSUE'), centerTitle: true),
      body: _busy
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: const [
                LoadingSkeleton(height: 48),
                SizedBox(height: 12),
                LoadingSkeleton(height: 140),
                SizedBox(height: 12),
                LoadingSkeleton(height: 96),
              ],
            )
          : _error == 'offline'
              ? Center(child: OfflineState(message: 'Check your internet connection and try again.', onRetry: _load))
              : _error != null
                  ? Center(child: ErrorState(message: _error!, onRetry: _load))
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (_pending) proPendingCard('Disputes'),
                        // Mockup #2: "Submitted" done (gold check),
                        // "Under Review" / "Resolved" plain grey.
                        _StepTracker(
                          steps: const ['Submitted', 'Under Review', 'Resolved'],
                          current: latest == null ? 1 : _stepFor(SupaDb.strOf(latest['status'], 'open')) + 1,
                          highlightCurrent: false,
                        ),
                        const SizedBox(height: 16),
                        // Mockup #2 "Tournament Details" card: always
                        // visible at the top; the card is the
                        // tournament selector (tap to pick) — the
                        // mockup has no TOURNAMENT ID / NAME field.
                        _mockSectionLabel('Tournament Details'),
                        const SizedBox(height: 8),
                        _tournamentCard(),
                        const SizedBox(height: 16),
                        _mockSectionLabel('SELECT ISSUE TYPE'),
                        const SizedBox(height: 8),
                        for (final t in _issueTypes)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: InkWell(
                              onTap: () => setState(() => _issueType = t),
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                                decoration: BoxDecoration(
                                  color: _issueType == t ? kGold.withValues(alpha: 0.08) : kField,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: _issueType == t ? kGold : kBorder, width: _issueType == t ? 1.5 : 1),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 22,
                                      height: 22,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(color: _issueType == t ? kGold : kMuted, width: 2),
                                      ),
                                      child: _issueType == t
                                          ? Center(child: Container(width: 12, height: 12, decoration: const BoxDecoration(color: Color(0xFFFDC903), shape: BoxShape.circle)))
                                          : null,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(child: Text(t, style: TextStyle(color: _issueType == t ? kGold : kText, fontWeight: _issueType == t ? FontWeight.bold : FontWeight.normal, fontSize: 15))),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        _mockSectionLabel('DESCRIPTION'),
                        const SizedBox(height: 4),
                        Text('Describe the issue (optional)', style: TextStyle(color: kMuted, fontSize: 13)),
                        const SizedBox(height: 8),
                        // FIX 23 item 29: card look via CardFieldShell.
                        CardFieldShell(
                          child: TextField(
                          controller: _description,
                          maxLines: 4,
                          style: TextStyle(color: kText),
                          decoration: InputDecoration(
                            hintText: 'Explain the issue in detail...',
                            hintStyle: TextStyle(color: kMuted),
                            contentPadding: const EdgeInsets.symmetric(vertical: 13, horizontal: 14),
                            border: const OutlineInputBorder(borderSide: BorderSide.none),
                            enabledBorder: const OutlineInputBorder(borderSide: BorderSide.none),
                            focusedBorder: const OutlineInputBorder(borderSide: BorderSide.none),
                          ),
                        ),
                        ),
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Text('$descLen / 500', style: TextStyle(color: descLen > 500 ? Colors.redAccent : kMuted, fontSize: 12)),
                        ),
                        const SizedBox(height: 8),
                        _mockSectionLabel('UPLOAD EVIDENCE'),
                        const SizedBox(height: 8),
                        if (_evidence != null) ...[
                          ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(_evidence!, height: 150, width: double.infinity, fit: BoxFit.cover)),
                          Row(children: [
                            Expanded(child: Text('Evidence photo ready (${(_evidence!.lengthSync() / 1024).toStringAsFixed(0)} KB)', style: TextStyle(color: kMuted, fontSize: 12))),
                            TextButton(onPressed: () => setState(() => _evidence = null), child: Text('Remove', style: TextStyle(color: kGold))),
                          ]),
                          const SizedBox(height: 8),
                        ] else
                          _dashedUploadBox(
                            onTap: _pickEvidence,
                            child: Column(
                              children: [
                                Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(color: kGold.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
                                  // Mockup #2: upload arrow with a
                                  // small "+" badge at its lower right.
                                  child: Stack(
                                    children: [
                                      const Center(child: Icon(Icons.upload, color: Color(0xFFFDC903), size: 26)),
                                      Positioned(
                                        right: 5,
                                        bottom: 5,
                                        child: Container(
                                          width: 14,
                                          height: 14,
                                          decoration: const BoxDecoration(color: Color(0xFFFDC903), shape: BoxShape.circle),
                                          child: const Icon(Icons.add, color: Colors.black, size: 10),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text('Upload screenshot or video evidence', style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 14), textAlign: TextAlign.center),
                                const SizedBox(height: 2),
                                Text('Supports JPG, PNG (Max 5MB)', style: TextStyle(color: kMuted, fontSize: 12), textAlign: TextAlign.center),
                              ],
                            ),
                          ),
                        const SizedBox(height: 6),
                        Text('Video evidence (MP4) abhi support nahi hai — koi video host live nahi hai. Photo evidence hi lagayen.', style: TextStyle(color: kMuted, fontSize: 12)),
                        const SizedBox(height: 12),
                        // Mockup #2 rules reminder: gold-tinted fill,
                        // NO border (user correction 2026-11-20 — no
                        // full border on cards).
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: kGold.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(12)),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(color: kGold, shape: BoxShape.circle),
                                child: const Center(child: Text('!', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 14))),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('RULES REMINDER', style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 14)),
                                    const SizedBox(height: 4),
                                    // Mockup #2 highlights the key
                                    // phrases in gold.
                                    RichText(
                                      text: TextSpan(
                                        style: TextStyle(color: kText, fontSize: 13),
                                        children: [
                                          const TextSpan(text: 'Please ensure your evidence is '),
                                          TextSpan(text: 'clear and unedited', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
                                          const TextSpan(text: '. False reporting will result in '),
                                          TextSpan(text: 'tournament penalties and a potential ban', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
                                          const TextSpan(text: '.'),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (_uploading) ...[LinearProgressIndicator(color: kGold, backgroundColor: kField), const SizedBox(height: 8)],
                        // Mockup #2: SUBMIT REPORT is a full pill,
                        // not the rectangular shared GoldButton.
                        _goldPillBtn(label: 'SUBMIT REPORT', icon: Icons.chevron_right, onPressed: _submitting ? null : _raise, busy: _submitting),
                      ],
                    ),
    );
  }
}
class ReportPage extends StatefulWidget {
  final String uid;
  const ReportPage({super.key, required this.uid});
  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  final _reported = TextEditingController();
  final _reason = TextEditingController();
  List<Map<String, dynamic>> _blocked = [];
  // FIX 10 (2026-11-21): display names for the blocked list, so
  // the rows never show raw Firebase UIDs.
  Map<String, String> _blockedNames = {};
  bool _pending = false;

  @override
  void initState() {
    super.initState();
    _loadBlocked();
  }

  Future<void> _loadBlocked() async {
    try {
      _blocked = await SupaDb.getList('blocked_users', eqCol: 'blocker_uid', eqVal: widget.uid);
      // FIX 10: resolve display names for the blocked rows — the
      // list shows names (or 'Blocked player'), never a UID.
      final uids = _blocked.map((b) => SupaDb.strOf(b['blocked_uid'])).where((s) => s.isNotEmpty).toList();
      final names = <String, String>{};
      if (uids.isNotEmpty) {
        final profiles = await SupaDb.getProfilesMap(uids);
        for (final e in profiles.entries) {
          final n = SupaDb.strOf(e.value['display_name'], SupaDb.strOf(e.value['displayName'], SupaDb.strOf(e.value['username'])));
          if (n.isNotEmpty) names[e.key] = n;
        }
      }
      if (mounted) setState(() => _blockedNames = names);
    } catch (e) {
      if (proTableMissing(e) && mounted) setState(() => _pending = true);
    }
  }

  Future<void> _report() async {
    if (_reported.text.trim().isEmpty || _reason.text.trim().isEmpty) {
      toast(context, 'Reported player UID aur reason zaroori hain.');
      return;
    }
    try {
      await SupaDb.client.from('player_reports').insert({
        'reporter_uid': widget.uid,
        'reported_uid': _reported.text.trim(),
        'reason': _reason.text.trim(),
        'status': 'open',
      });
      if (mounted) toast(context, 'Report submit ho gaya — admin review karega.');
      _reported.clear();
      _reason.clear();
    } catch (e) {
      if (mounted) toast(context, proTableMissing(e) ? 'Backend pending — migration 008 chalani hogi.' : 'Failed: $e');
    }
  }

  Future<void> _block() async {
    if (_reported.text.trim().isEmpty) {
      toast(context, 'Pehle player UID likhen.');
      return;
    }
    try {
      await SupaDb.client.from('blocked_users').insert({'blocker_uid': widget.uid, 'blocked_uid': _reported.text.trim()});
      if (mounted) toast(context, 'Player block ho gaya.');
      _loadBlocked();
    } catch (e) {
      if (mounted) toast(context, 'Block failed: $e');
    }
  }

  Future<void> _unblock(String blockedUid) async {
    try {
      await SupaDb.client.from('blocked_users').delete().eq('blocker_uid', widget.uid).eq('blocked_uid', blockedUid);
      _loadBlocked();
    } catch (e) {
      if (mounted) toast(context, 'Unblock failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Report / Block', style: TextStyle(color: kGold))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_pending) proPendingCard('Reports & Blocks'),
          field(controller: _reported, label: 'Reported player UID (Firebase UID)'),
          field(controller: _reason, label: 'Reason', hint: 'Cheating / abuse / suspicious play'),
          Row(children: [
            Expanded(child: goldButton(label: 'Submit Report', onPressed: _report)),
            const SizedBox(width: 10),
            Expanded(child: OutlinedButton(onPressed: _block, style: OutlinedButton.styleFrom(side: BorderSide(color: kGold)), child: Text('Block Player', style: TextStyle(color: kGold)))),
          ]),
          const SizedBox(height: 20),
          _mockSectionLabel('Blocked Players'),
          const SizedBox(height: 8),
          if (_blocked.isEmpty) proEmpty('Koi blocked player nahi.'),
          for (final b in _blocked)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              // FIX 10: name (or 'Blocked player') — never the raw
              // Firebase UID. Unblock still keys on the UID, which
              // is never displayed.
              child: MockupCard(child: Row(children: [Expanded(child: Text(_blockedNames[SupaDb.strOf(b['blocked_uid'])] ?? 'Blocked player', style: TextStyle(color: kText))), TextButton(onPressed: () => _unblock(SupaDb.strOf(b['blocked_uid'])), child: Text('Unblock', style: TextStyle(color: kGold)))])),
            ),
        ],
      ),
    );
  }
}

/// ---------------- FRIENDS & FOLLOW (real backend) ----------------

class PlayerLookupPage extends StatefulWidget {
  final String uid;
  const PlayerLookupPage({super.key, required this.uid});
  @override
  State<PlayerLookupPage> createState() => _PlayerLookupPageState();
}

class _PlayerLookupPageState extends State<PlayerLookupPage> {
  final _nameCtrl = TextEditingController();
  Map<String, dynamic>? _player;
  bool _following = false;
  bool _friend = false;
  List<Map<String, dynamic>> _friends = [];
  bool _pending = false;

  Future<void> _loadFriends() async {
    try {
      _friends = await SupaDb.getList('friends', eqCol: 'user_uid', eqVal: widget.uid);
      if (mounted) setState(() {});
    } catch (e) {
      if (proTableMissing(e) && mounted) setState(() => _pending = true);
    }
  }

  @override
  void initState() {
    super.initState();
    _loadFriends();
  }

  Future<void> _lookup() async {
    // USERNAME search (2026-11-20 correction): NEVER by Firebase UID —
    // the UID must not appear in user-facing UI or be a search key.
    final target = _nameCtrl.text.trim();
    if (target.isEmpty) return;
    final p = SupaDb.normProfile(await SupaDb.findUserByUsername(target));
    if (p.isEmpty) {
      if (mounted) toast(context, 'Is username ka koi player nahi mila.');
      return;
    }
    // Follow/friend state is keyed by UID internally (service layer
    // only — the UID never shows in the UI).
    final targetUid = SupaDb.strOf(p['uid']);
    var following = false;
    var friend = false;
    try {
      final f = await SupaDb.getList('follows', eqCol: 'follower_uid', eqVal: widget.uid, eqCol2: 'following_uid', eqVal2: targetUid);
      following = f.isNotEmpty;
      final fr = await SupaDb.getList('friends', eqCol: 'user_uid', eqVal: widget.uid, eqCol2: 'friend_uid', eqVal2: targetUid);
      friend = fr.isNotEmpty;
    } catch (_) {}
    if (mounted) setState(() {
      _player = p;
      _following = following;
      _friend = friend;
    });
  }

  Future<void> _toggleFollow() async {
    final target = SupaDb.strOf(_player!['uid']);
    try {
      if (_following) {
        await SupaDb.client.from('follows').delete().eq('follower_uid', widget.uid).eq('following_uid', target);
      } else {
        await SupaDb.client.from('follows').insert({'follower_uid': widget.uid, 'following_uid': target});
      }
      if (mounted) setState(() => _following = !_following);
    } catch (e) {
      if (mounted) toast(context, proTableMissing(e) ? 'Backend pending — migration 008 chalani hogi.' : 'Failed: $e');
    }
  }

  Future<void> _toggleFriend() async {
    final target = SupaDb.strOf(_player!['uid']);
    try {
      if (_friend) {
        await SupaDb.client.from('friends').delete().eq('user_uid', widget.uid).eq('friend_uid', target);
      } else {
        await SupaDb.client.from('friends').insert({'user_uid': widget.uid, 'friend_uid': target, 'friend_name': SupaDb.strOf(_player!['displayName'])});
      }
      if (mounted) setState(() => _friend = !_friend);
      _loadFriends();
    } catch (e) {
      if (mounted) toast(context, proTableMissing(e) ? 'Backend pending — migration 008 chalani hogi.' : 'Failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Friends & Follow', style: TextStyle(color: kGold))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_pending) proPendingCard('Friends & Follow'),
          field(controller: _nameCtrl, label: 'Username', hint: 'Jis player ko follow karna hai'),
          goldButton(label: 'Find Player', onPressed: _lookup),
          if (_player != null) ...[
            const SizedBox(height: 16),
            MockupCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(SupaDb.strOf(_player!['displayName']), style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 18)),
                  Text('Matches: ${SupaDb.intOf(_player!['totalMatches'])} • Wins: ${SupaDb.intOf(_player!['wonMatches'])} • Level: ${SupaDb.intOf(_player!['level'], 1)}', style: TextStyle(color: kMuted, fontSize: 12)),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: goldButton(label: _following ? 'Unfollow' : 'Follow', onPressed: _toggleFollow)),
                    const SizedBox(width: 10),
                    Expanded(child: OutlinedButton(onPressed: _toggleFriend, style: OutlinedButton.styleFrom(side: BorderSide(color: kGold)), child: Text(_friend ? 'Remove Friend' : 'Add Friend', style: TextStyle(color: kGold)))),
                  ]),
                  const SizedBox(height: 8),
                  TextButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ShareHubPage(uid: widget.uid, targetProfile: _player))), icon: Icon(Icons.share, color: kGold, size: 18), label: Text('Share this player card', style: TextStyle(color: kGold))),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          _mockSectionLabel('My Friends'),
          const SizedBox(height: 8),
          if (_friends.isEmpty) proEmpty('Abhi koi friend nahi. Username se player dhoondhen aur Add Friend dabayen.'),
          for (final f in _friends)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              // Never fall back to the friend UID as display text.
              child: MockupCard(child: Text(SupaDb.strOf(f['friend_name'], 'Player'), style: TextStyle(color: kText))),
            ),
        ],
      ),
    );
  }
}

/// ---------------- ESCROW & PROOF ----------------

class EscrowHubPage extends StatelessWidget {
  final String uid;
  const EscrowHubPage({super.key, required this.uid});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Prize Escrow & Proof', style: TextStyle(color: kGold))),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: SupaDb.getTournaments(),
        builder: (context, snap) {
          final list = snap.data ?? [];
          if (snap.connectionState == ConnectionState.waiting) return Center(child: CircularProgressIndicator(color: kGold));
          if (list.isEmpty) return proEmpty('Koi tournament nahi mila.');
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            itemBuilder: (context, i) {
              final t = list[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: MockupCard(
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(SupaDb.strOf(t['name']), style: TextStyle(color: kText, fontWeight: FontWeight.bold)), Text('Prize pool: ${fmtRs(SupaDb.numOf(t['prizePool']))} • Entry: ${fmtRs(SupaDb.numOf(t['entryFee']))}', style: TextStyle(color: kMuted, fontSize: 12))])),
                    TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => EscrowPage(tournament: t))), child: Text('View Escrow', style: TextStyle(color: kGold))),
                  ]),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class EscrowPage extends StatelessWidget {
  final Map<String, dynamic> tournament;
  const EscrowPage({super.key, required this.tournament});

  /// Escrow-style display, computed from REAL records only:
  /// pooled = entryFee × joined players (registrationPlayerCount
  /// handles the RPC one-row-per-member shape and the legacy
  /// one-row-per-team shape — never rows × teamSize);
  /// distributed = prize/winning transactions whose description names
  /// this tournament; pending = pooled − distributed (floor 0).
  /// This is a DISPLAY of records, not a bank escrow account.
  Future<Map<String, dynamic>> _escrow() async {
    final regs = await SupaDb.getRegistrations(SupaDb.strOf(tournament['id']));
    final pooled = SupaDb.numOf(tournament['entryFee']) * SupaDb.registrationPlayerCount(regs);
    final name = SupaDb.strOf(tournament['name']);
    final tid = SupaDb.strOf(tournament['id']);
    var distributed = 0.0;
    // N-create-tournament (2026-11-20): platform commission = SUM of
    // 'platform_commission' rows for this tournament (one per paid
    // entry, 10% of that entry's fee). Matched by tournament_id first,
    // falling back to the description name for older rows.
    var commission = 0.0;
    final log = <Map<String, dynamic>>[];
    try {
      final txs = await SupaDb.getList('transactions', limit: 500);
      for (final tx in txs) {
        final type = SupaDb.strOf(tx['type']);
        final desc = SupaDb.strOf(tx['description']);
        if (type == 'platform_commission' && (SupaDb.strOf(tx['tournament_id']) == tid || desc.contains(name))) {
          commission += SupaDb.numOf(tx['amount']);
          continue;
        }
        if ((type.contains('prize') || type.contains('winning') || type.contains('winnings')) && desc.contains(name)) {
          distributed += SupaDb.numOf(tx['amount']);
          log.add(tx);
        }
      }
    } catch (_) {}
    return {'pooled': pooled, 'distributed': distributed, 'commission': commission, 'pending': max(0.0, pooled - distributed - commission), 'joined': SupaDb.registrationPlayerCount(regs), 'log': log};
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Escrow — ${SupaDb.strOf(tournament['name'])}', style: TextStyle(color: kGold))),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _escrow(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) return Center(child: CircularProgressIndicator(color: kGold));
          final d = snap.data ?? {'pooled': 0.0, 'distributed': 0.0, 'commission': 0.0, 'pending': 0.0, 'joined': 0, 'log': <Map<String, dynamic>>[]};
          final log = d['log'] as List<Map<String, dynamic>>;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              MockupCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Prize Pool Escrow Display', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 8),
                    Text('Pooled (entry fees): ${fmtRs(d['pooled'] as double)}  (${d['joined']} players)', style: TextStyle(color: kText)),
                    Text('Distributed to winners: ${fmtRs(d['distributed'] as double)}', style: TextStyle(color: kText)),
                    Text('Platform commission (10%): ${fmtRs(d['commission'] as double)}', style: TextStyle(color: kText)),
                    Text('Pending distribution: ${fmtRs(d['pending'] as double)}', style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Text('Note: yeh records se bana display hai — koi alag bank escrow account nahi hai. Prize admin ke result declare karne ke baad winners ke wallet me credit hota hai.', style: TextStyle(color: kMuted, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _mockSectionLabel('Prize Distribution Log'),
              const SizedBox(height: 8),
              if (log.isEmpty) proEmpty('Abhi koi prize distribution record nahi mila.'),
              for (final tx in log)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: MockupCard(child: Row(children: [Expanded(child: Text(SupaDb.strOf(tx['description']), style: TextStyle(color: kText))), Text(fmtRs(SupaDb.numOf(tx['amount'])), style: TextStyle(color: kGold, fontWeight: FontWeight.bold))])),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// ---------------- PROGRESS: XP / MMR / SEASON ----------------

class ProgressPage extends StatelessWidget {
  final String uid;
  const ProgressPage({super.key, required this.uid});

  /// Season free track: tiers at XP 0 / 200 / 500 / 1000 / 2000.
  /// Rewards are in-app POINTS only (10 / 25 / 50 / 100 / 200) — no
  /// real money, no betting. Claim goes through the claim_reward RPC
  /// (challenge key season_tier_<xp>, seeded in migration 018) and
  /// writes community_points_ledger — one claim per tier (the RPC's
  /// UNIQUE guard rejects a second claim).
  /// NOTE (Phase 4): needs migrations 017–023 applied; do not build
  /// from this tree against the pre-apply backend.
  static const _tiers = [
    {'xp': 0, 'points': 10},
    {'xp': 200, 'points': 25},
    {'xp': 500, 'points': 50},
    {'xp': 1000, 'points': 100},
    {'xp': 2000, 'points': 200},
  ];

  Future<void> _claim(BuildContext context, int tierXp, int points) async {
    // Phase 4: season rewards are Community Points, claimed through
    // claim_reward (challenge key season_tier_<xp>, period 'once').
    // A second claim raises 'already claimed' from the RPC — same
    // toast as before. The old season_reward transactions row is no
    // longer written (existing rows were mirrored to the points
    // ledger by migration 018).
    // Failures NEVER show raw backend text to the user: a missing
    // claim_reward RPC (PGRST202) means the reward system is not
    // live yet — see _claimFailureMessage.
    try {
      final res = await SupaDb.claimReward('season_tier_$tierXp', 'once');
      if (res['ok'] == true) {
        if (context.mounted) toast(context, 'Season reward claim ho gaya: $points points!');
        return;
      }
      final err = SupaDb.strOf(res['error']);
      if (err.contains('already claimed')) {
        if (context.mounted) toast(context, 'Yeh tier reward pehle claim ho chuka hai.');
        return;
      }
      if (context.mounted) toast(context, _claimFailureMessage(err));
    } catch (_) {
      if (context.mounted) toast(context, 'Claim nahi ho saka — thori der baad koshish karein.');
    }
  }

  /// Plain-language claim failure — raw PostgrestException text is
  /// never shown to the user. A missing claim_reward function
  /// (PGRST202 / "Could not find the function") means the reward
  /// system is not live yet (Phase 4 migrations unapplied).
  static String _claimFailureMessage(String err) {
    final lower = err.toLowerCase();
    if (lower.contains('already claimed')) return 'Yeh tier reward pehle claim ho chuka hai.';
    if (lower.contains('pgrst202') || lower.contains('could not find the function') || lower.contains('claim_reward')) {
      return 'Reward system abhi tayyar ho raha hai — thori der baad koshish karein';
    }
    return 'Claim nahi ho saka — thori der baad koshish karein.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Season, XP & MMR', style: TextStyle(color: kGold))),
      body: FutureBuilder<Map<String, int>>(
        future: playerProgress(uid),
        builder: (context, snap) {
          final p = snap.data ?? {'xp': 0, 'level': 1, 'mmr': 1000, 'matches': 0, 'wins': 0, 'kills': 0};
          final xp = p['xp']!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              MockupCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FutureBuilder<Map<String, dynamic>>(
                      future: SupaDb.getProfile(uid),
                      builder: (context, profSnap) {
                        final prof = profSnap.data ?? {};
                        // Verified badge rule (documented, computed —
                        // NOT an admin grant): profile photo + 5 matches.
                        final verified = SupaDb.strOf(prof['photo_url']).isNotEmpty && (p['matches'] ?? 0) >= 5;
                        if (!verified) return const SizedBox.shrink();
                        // Verified badge row — plain Row inside the
                        // outer MockupCard (no nested card: two
                        // animated shines nested would look noisy).
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(children: [Icon(Icons.verified, color: kGold), SizedBox(width: 8), Expanded(child: Text('Verified Player ✓  (photo + 5 matches — auto rule)', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)))]),
                        );
                      },
                    ),
                    Text('Level ${p['level']}  •  XP $xp  •  MMR ${p['mmr']}', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 18)),
                    const SizedBox(height: 6),
                    Text('Matches: ${p['matches']} • Wins: ${p['wins']} • Kills: ${p['kills']}', style: TextStyle(color: kText)),
                    const SizedBox(height: 6),
                    Text('MMR formula: 1000 + wins×25 + kills×2 − losses×10. Yeh rank display hai — matchmaking par koi asar nahi (koi paid system nahi).', style: TextStyle(color: kMuted, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _mockSectionLabel('Career Graph — Damage & Headshots (aakhri 10 matches)'),
              const SizedBox(height: 8),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: SupaDb.getMatchHistory(uid),
                builder: (context, hSnap) {
                  final rows = (hSnap.data ?? []).take(10).toList();
                  if (rows.isEmpty) return Text('Abhi koi match record nahi — admin jab result credit karega, tab damage/headshot graph banega.', style: TextStyle(color: kMuted, fontSize: 12));
                  final maxDmg = rows.map((r) => SupaDb.intOf(r['damage'])).fold<int>(1, (a, b) => b > a ? b : a);
                  return Column(
                    children: [
                      for (final r in rows)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${SupaDb.strOf(r['tournamentName'])} • Kills ${SupaDb.intOf(r['kills'])} • Damage ${SupaDb.intOf(r['damage'])} • Headshots ${SupaDb.intOf(r['headshot'])}', style: TextStyle(color: kText, fontSize: 12)),
                              const SizedBox(height: 2),
                              Container(height: 8, width: 220 * (SupaDb.intOf(r['damage']) / maxDmg), decoration: BoxDecoration(color: kGold, borderRadius: BorderRadius.circular(4))),
                            ],
                          ),
                        ),
                      Text('Damage bar = match damage (admin prize entry se). Headshot sirf number me dikhaya gaya hai — damage/headshot tabhi aayenge jab admin ne result entry me likhe hon.', style: TextStyle(color: kMuted, fontSize: 11)),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              _mockSectionLabel('Season Pass — FREE Track (points only)'),
              const SizedBox(height: 8),
              for (final tier in _tiers)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: MockupCard(
                    child: Row(children: [
                      Expanded(child: Text('Tier ${tier['xp']} XP → ${tier['points']} points', style: TextStyle(color: kText, fontWeight: FontWeight.bold))),
                      xp >= (tier['xp'] as int)
                          ? TextButton(onPressed: () => _claim(context, tier['xp'] as int, tier['points'] as int), child: Text('Claim', style: TextStyle(color: kGold)))
                          : Text('Locked', style: TextStyle(color: kMuted, fontSize: 12)),
                    ]),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// ---------------- HALL OF FAME & SEASONAL LEADERBOARDS ----------------

class HallOfFamePage extends StatelessWidget {
  const HallOfFamePage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Hall of Fame', style: TextStyle(color: kGold))),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: SupaDb.getLeaderboard(),
        builder: (context, snap) {
          final list = snap.data ?? [];
          if (snap.connectionState == ConnectionState.waiting) return Center(child: CircularProgressIndicator(color: kGold));
          if (list.isEmpty) return proEmpty('Abhi koi leaderboard data nahi — Hall of Fame tab banegi jab players ke ranks honge.');
          final top = list.take(10).toList();
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: top.length,
            itemBuilder: (context, i) {
              final p = top[i];
              final medal = i == 0 ? '🥇' : i == 1 ? '🥈' : i == 2 ? '🥉' : '#${i + 1}';
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: MockupCard(
                  child: Row(children: [
                    Text(medal, style: const TextStyle(fontSize: 18)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(SupaDb.strOf(p['displayName']), style: TextStyle(color: kText, fontWeight: FontWeight.bold))),
                    Text('Wins: ${SupaDb.intOf(p['wonMatches'])} • Matches: ${SupaDb.intOf(p['totalMatches'])}', style: TextStyle(color: kMuted, fontSize: 12)),
                  ]),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class SeasonalLeaderboardPage extends StatefulWidget {
  const SeasonalLeaderboardPage({super.key});
  @override
  State<SeasonalLeaderboardPage> createState() => _SeasonalLeaderboardPageState();
}

class _SeasonalLeaderboardPageState extends State<SeasonalLeaderboardPage> {
  String _period = 'all'; // all | week | month | season

  /// Seasonal filtering from REAL match_history dates: week = last 7
  /// days, month = last 30 days, season = last 90 days. Wins/kills
  /// counted only in that window. All-time = no filter.
  Future<List<Map<String, dynamic>>> _board() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final windowMs = _period == 'week' ? 7 * 86400000 : _period == 'month' ? 30 * 86400000 : _period == 'season' ? 90 * 86400000 : 0;
    final profiles = await SupaDb.getLeaderboard();
    // ONE query for all recent history, grouped by player in Dart
    // (the old code awaited getMatchHistory per profile — up to
    // 100 sequential queries). Capped at the 500 most recent rows,
    // the same cap the Rankings Weekly tab uses.
    final allHistory = await SupaDb.getList('match_history', orderBy: 'played_at', ascending: false, limit: 500);
    final byUid = <String, List<Map<String, dynamic>>>{};
    for (final h in allHistory) {
      final uid = SupaDb.strOf(h['firebase_uid']);
      if (uid.isEmpty) continue;
      (byUid[uid] ??= []).add(h);
    }
    final rows = <Map<String, dynamic>>[];
    for (final p in profiles) {
      final history = byUid[SupaDb.strOf(p['uid'])] ?? const <Map<String, dynamic>>[];
      final inWindow = windowMs == 0 ? history : history.where((h) => SupaDb.parseTs(h['played_at'] ?? h['created_at']) >= now - windowMs).toList();
      final wins = inWindow.where((h) => SupaDb.intOf(h['rank']) == 1).length;
      final kills = inWindow.fold<int>(0, (s, h) => s + SupaDb.intOf(h['kills']));
      rows.add({'name': SupaDb.strOf(p['displayName']), 'wins': wins, 'kills': kills, 'matches': inWindow.length});
    }
    rows.sort((a, b) {
      final w = (b['wins'] as int).compareTo(a['wins'] as int);
      return w != 0 ? w : (b['kills'] as int).compareTo(a['kills'] as int);
    });
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Seasonal Leaderboards', style: TextStyle(color: kGold))),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              for (final f in [
                {'k': 'all', 'l': 'All-time'},
                {'k': 'week', 'l': 'Weekly'},
                {'k': 'month', 'l': 'Monthly'},
                {'k': 'season', 'l': 'Season (90 days)'},
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(label: Text(f['l']!), selected: _period == f['k'], selectedColor: kGold, labelStyle: TextStyle(color: _period == f['k'] ? Colors.black : kText), onSelected: (_) => setState(() => _period = f['k']!)),
                ),
            ]),
          ),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              key: ValueKey(_period),
              future: _board(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) return Center(child: CircularProgressIndicator(color: kGold));
                final rows = snap.data ?? [];
                if (rows.isEmpty || rows.every((r) => (r['matches'] as int) == 0)) return proEmpty('Is period me koi match record nahi mila.');
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final r = rows[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: MockupCard(child: Row(children: [Text('#${i + 1}', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)), SizedBox(width: 10), Expanded(child: Text(SupaDb.strOf(r['name']), style: TextStyle(color: kText, fontWeight: FontWeight.bold))), Text('Wins: ${r['wins']} • Kills: ${r['kills']}', style: TextStyle(color: kMuted, fontSize: 12))])),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// ---------------- RATINGS ----------------

class RatingPage extends StatefulWidget {
  final String uid;
  const RatingPage({super.key, required this.uid});
  @override
  State<RatingPage> createState() => _RatingPageState();
}

class _RatingPageState extends State<RatingPage> {
  List<Map<String, dynamic>> _completed = [];
  Set<String> _rated = {};
  bool _pending = false;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final regs = await SupaDb.getList('tournament_registrations', eqCol: 'firebase_uid', eqVal: widget.uid);
      final done = <Map<String, dynamic>>[];
      for (final r in regs) {
        final t = await SupaDb.getTournament(SupaDb.strOf(r['tournament_id']));
        if (t.isNotEmpty && (SupaDb.strOf(t['status']) == 'completed' || SupaDb.strOf(t['status']) == 'result')) done.add(t);
      }
      final ratings = await SupaDb.getList('tournament_ratings', eqCol: 'firebase_uid', eqVal: widget.uid);
      if (mounted) setState(() {
        _completed = done;
        _rated = ratings.map((x) => SupaDb.strOf(x['tournament_id'])).toSet();
      });
    } catch (e) {
      if (proTableMissing(e) && mounted) setState(() => _pending = true);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _rate(Map<String, dynamic> t) async {
    var stars = 5;
    final feedbackCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          backgroundColor: kCardPurpleMid,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
          title: Text('Rate — ${SupaDb.strOf(t['name'])}', style: TextStyle(color: kGold)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (var i = 1; i <= 5; i++) IconButton(onPressed: () => setD(() => stars = i), icon: Icon(i <= stars ? Icons.star : Icons.star_border, color: kGold))]),
                field(controller: feedbackCtrl, label: 'Feedback (optional)'),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel', style: TextStyle(color: kMuted))),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text('Submit', style: TextStyle(color: kGold))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await SupaDb.client.from('tournament_ratings').insert({
        'tournament_id': SupaDb.strOf(t['id']),
        'firebase_uid': widget.uid,
        'stars': stars,
        'feedback': feedbackCtrl.text.trim(),
      });
      if (mounted) toast(context, 'Rating submit ho gayi — shukriya!');
      _load();
    } catch (e) {
      if (mounted) toast(context, proTableMissing(e) ? 'Backend pending — migration 008 chalani hogi.' : 'Failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Rate Tournaments', style: TextStyle(color: kGold))),
      body: _busy
          ? Center(child: CircularProgressIndicator(color: kGold))
          : _pending
              ? ListView(padding: const EdgeInsets.all(16), children: [proPendingCard('Tournament Ratings')])
              : _completed.isEmpty
                  ? proEmpty('Aapne koi completed tournament nahi khela. Tournament khatam hone ke baad yahan rating de sakenge.')
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _completed.length,
                      itemBuilder: (context, i) {
                        final t = _completed[i];
                        final done = _rated.contains(SupaDb.strOf(t['id']));
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: MockupCard(child: Row(children: [Expanded(child: Text(SupaDb.strOf(t['name']), style: TextStyle(color: kText, fontWeight: FontWeight.bold))), done ? Text('✓ Rated', style: TextStyle(color: kGold)) : TextButton(onPressed: () => _rate(t), child: Text('Rate', style: TextStyle(color: kGold)))])),
                        );
                      },
                    ),
    );
  }
}

/// ---------------- FAQ ----------------

/// Shared FAQ copy (Phase 3 #13). Hardcoded list — there is NO faq
/// table live or in drafts 017–023, so copy is corrected here only
/// (see PREP §2.7); moving FAQs to `app_settings` is a Phase 6/admin
/// follow-up. Stale mentions REMOVED 2026-11-19: wallet fee deduction
/// ("fee wallet se kat jayegi"), "Recharge API pending", Google
/// error 10 — none of those reflect the live app anymore.
const _supportFaqs = [
  {'q': 'Tournament kaise join karen?', 'a': 'Tournaments tab se tournament kholen, Join dabayen aur team details bharen. Entry fee (agar hai) join karte waqt dikhayi jayegi. Slot confirm hone par notification milegi.'},
  {'q': 'Recharge kaise hota hai?', 'a': 'Wallet → Recharge se amount chunen aur wahan dikhaya gaya payment method use karen. Payment confirm hone par balance update hoga; koi issue ho to support ticket banayen.'},
  {'q': 'Room me mic kaise on karen?', 'a': 'Khaali seat par "Take mic" dabayen — mic seedha ON hoga. Apni seat dobara dabane se mute/unmute hoga. Koi PTT button nahi hai.'},
  {'q': 'Withdrawal kitne din me aata hai?', 'a': 'Withdrawal request ke baad admin approve karta hai. Winning balance se hi withdraw hota hai (minimum limit withdraw karte waqt dikhai deti hai). Status Wallet → Withdrawals me dekhen.'},
  {'q': 'Music sab ko kaise sunai de?', 'a': 'Room me Music → Local Upload → gaana chalayen, "Broadcast My Music" ON rakhen. Sab members ko sunai dega, aur koi bhi mic on hote hi volume 5% ho jayega (RJ ducking).'},
  {'q': 'Points kya hain? Kya yeh paisa hai?', 'a': 'Nahi. Points sirf in-app hain (Season track se milte hain). In se koi real money nahi milta aur koi betting nahi hoti.'},
  {'q': 'Dispute kaise raise karen?', 'a': 'Pro Features → Disputes & Reports → Raise Dispute. Issue type chunen, detail likhen aur photo evidence (JPG/PNG, 5MB tak) lagayen. Admin verification queue me jayega aur result dobara check hoga.'},
  {'q': 'Support ticket ka jawab kahan milega?', 'a': 'New Support Ticket se ticket banayen, phir My Tickets me ticket kholen — admin ka jawab wahin dikhega. Tickets usually 12–24 ghante me review hote hain.'},
  // Wave 4b #13: "Account & Login" category had no matching FAQ —
  // the category searches for "login", so each entry below contains
  // that word. Answers describe only the real login behaviour:
  // email+password (min 6 chars) or Google sign-in, password reset
  // via emailed link (no in-app password change exists), name/photo
  // edit via Profile → Edit Profile. No phone/OTP login exists.
  {'q': 'Login kaise karen — email ya Google?', 'a': 'Login screen par apna email aur password likhen aur LOGIN dabayen, ya "Continue with Google" se apne Google account se sign-in karen. Pehli baar hain to SIGN UP se naya account banayen — password kam se kam 6 characters ka hona chahiye.'},
  {'q': 'Password bhool gaye to login kaise karen?', 'a': 'Login screen par apna email likhen aur "Forgot Password?" dabayen — password reset email aapke inbox me aayega, us link se naya password set karen aur dobara login karen.'},
  {'q': 'Login ke baad apna naam ya profile photo kaise badlen?', 'a': 'Profile kholen aur Edit Profile dabayen — wahan apna display name badal kar save karen. Photo badalne ke liye profile photo par camera icon dabayen aur nayi photo chunen.'},
];

class FaqPage extends StatefulWidget {
  final String? initialQuery;
  const FaqPage({super.key, this.initialQuery});
  @override
  State<FaqPage> createState() => _FaqPageState();
}

class _FaqPageState extends State<FaqPage> {
  late final TextEditingController _search;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(text: widget.initialQuery ?? '');
    _search.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final faqs = q.isEmpty
        ? _supportFaqs
        : _supportFaqs.where((f) => '${f['q']} ${f['a']}'.toLowerCase().contains(q)).toList();
    return Scaffold(
      appBar: AppBar(title: Text('FAQ', style: TextStyle(color: kGold))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ArenaSearchBar(controller: _search, hint: 'Search FAQs...'),
          const SizedBox(height: 12),
          if (faqs.isEmpty)
            const EmptyState(
              icon: Icons.search_off_outlined,
              title: 'No FAQs found',
              body: 'Is sawal ka jawab FAQ me nahi hai — support ticket banayen, admin jawab dega.',
            ),
          for (final f in faqs)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: MockupCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(f['q']!, style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(f['a']!, style: TextStyle(color: kText, fontSize: 13)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// ---------------- HELP & SUPPORT HUB (Phase 3 #13, NEW) ----------------

class HelpSupportPage extends StatefulWidget {
  final String uid;
  const HelpSupportPage({super.key, required this.uid});
  @override
  State<HelpSupportPage> createState() => _HelpSupportPageState();
}

class _HelpSupportPageState extends State<HelpSupportPage> {
  final _search = TextEditingController();
  int _expanded = -1;

  // Mockup #13 categories, element-for-element. The query opens the
  // FAQ search; every category has matching FAQ entries (Wave 4b
  // #13 closed the "Account & Login" gap — its entries contain
  // "login", so the search returns them). Glyphs are the mockup's
  // pictograms (see _categoryGlyph): person+key, ticket+star,
  // crossed gamepads, 1/2/3 podium, crossed tools, book+shield.
  static const _categories = [
    {'label': 'Account & Login', 'glyph': 'account', 'query': 'login'},
    {'label': 'Tournament Registration', 'glyph': 'ticket', 'query': 'tournament'},
    {'label': 'Match Issues', 'glyph': 'gamepads', 'query': 'match'},
    {'label': 'Results & Rankings', 'glyph': 'podium', 'query': 'result'},
    {'label': 'Technical Problems', 'glyph': 'tools', 'query': 'mic'},
    {'label': 'Community Rules', 'glyph': 'rules', 'query': 'points'},
  ];

  /// Mockup #13 category pictograms, drawn from Material icons.
  Widget _categoryGlyph(String glyph) {
    switch (glyph) {
      case 'account':
        return Stack(
          alignment: Alignment.center,
          children: [
            const Icon(Icons.person, color: Color(0xFFFDC903), size: 26),
            Positioned(right: 2, bottom: 2, child: Icon(Icons.key, color: kGold, size: 13)),
          ],
        );
      case 'ticket':
        return Stack(
          alignment: Alignment.center,
          children: [
            const Icon(Icons.confirmation_number, color: Color(0xFFFDC903), size: 26),
            Positioned(right: 1, top: 1, child: Icon(Icons.star, color: kGold, size: 12)),
          ],
        );
      case 'gamepads':
        return Stack(
          alignment: Alignment.center,
          children: [
            Transform.rotate(angle: 0.45, child: Icon(Icons.sports_esports, color: kGold, size: 20)),
            Transform.rotate(angle: -0.45, child: Icon(Icons.sports_esports, color: kGold, size: 20)),
          ],
        );
      case 'podium':
        // Mockup #13: a 1/2/3 podium (gold steps, dark numbers),
        // order 2 – 1 – 3, centre tallest.
        Widget step(int n, double h) => Container(
              width: 10,
              height: h,
              decoration: BoxDecoration(color: kGold, borderRadius: BorderRadius.circular(2)),
              child: Center(child: Text('$n', style: const TextStyle(color: Colors.black, fontSize: 8, fontWeight: FontWeight.w900))),
            );
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [step(2, 13), const SizedBox(width: 2), step(1, 19), const SizedBox(width: 2), step(3, 10)],
        );
      case 'tools':
        // Mockup #13: crossed wrench + screwdriver.
        return const Icon(Icons.handyman, color: Color(0xFFFDC903), size: 26);
      case 'rules':
        return Stack(
          alignment: Alignment.center,
          children: [
            const Icon(Icons.menu_book, color: Color(0xFFFDC903), size: 26),
            Positioned(right: 2, bottom: 2, child: Icon(Icons.shield, color: kGold, size: 13)),
          ],
        );
      default:
        return Icon(Icons.help_outline, color: kGold, size: 26);
    }
  }

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _openFaq(String query) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => FaqPage(initialQuery: query)));
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final matches = q.isEmpty
        ? <Map<String, String>>[]
        : _supportFaqs.where((f) => '${f['q']} ${f['a']}'.toLowerCase().contains(q)).toList();
    return Scaffold(
      appBar: AppBar(
        // Mockup #13 title is ITALIC (unlike #2/#3/#4).
        title: _mockAppBarTitle('HELP & SUPPORT', italic: true),
        centerTitle: true,
        // Mockup #13: ARENA HUB lockup top-right.
        actions: const [Padding(padding: EdgeInsets.only(right: 12), child: Center(child: ArenaLogo(crownSize: 28, fontSize: 13)))],
        // Mockup #13: back chevron in a gold-bordered square.
        leading: Padding(
          padding: const EdgeInsets.all(10),
          child: InkWell(
            onTap: () => Navigator.maybePop(context),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              decoration: BoxDecoration(border: Border.all(color: kGold, width: 1.5), borderRadius: BorderRadius.circular(10)),
              child: Icon(Icons.chevron_left, color: kGold, size: 22),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          // Mockup #13 background: faint diagonal shard top-right
          // + sparse gold dots (shared ArenaEmberDots, behind
          // content, taps pass through).
          const Positioned.fill(child: IgnorePointer(child: ArenaEmberDots())),
          const Positioned.fill(child: IgnorePointer(child: _TopRightShards())),
          ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Mockup #13 search pill (fully rounded) with a gold
          // search icon. FIX 23 item 29: card look via
          // CardFieldShell (radius 24, the pill shape).
          CardFieldShell(
            radius: 24,
            child: TextField(
            controller: _search,
            style: TextStyle(color: kText),
            decoration: InputDecoration(
              hintText: 'How can we help?',
              hintStyle: TextStyle(color: kMuted),
              prefixIcon: Icon(Icons.search, color: kGold),
              contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
              border: const OutlineInputBorder(borderSide: BorderSide.none),
              enabledBorder: const OutlineInputBorder(borderSide: BorderSide.none),
              focusedBorder: const OutlineInputBorder(borderSide: BorderSide.none),
            ),
          ),
          ),
          const SizedBox(height: 8),
          if (q.isNotEmpty) ...[
            if (matches.isEmpty)
              const EmptyState(
                icon: Icons.search_off_outlined,
                title: 'No help found',
                body: 'Is topic par koi FAQ nahi mila — neeche Create Ticket se ticket banayen.',
              ),
            for (var i = 0; i < matches.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: MockupCard(
                  child: InkWell(
                    onTap: () => setState(() => _expanded = _expanded == i ? -1 : i),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(child: Text(matches[i]['q']!, style: TextStyle(color: kGold, fontWeight: FontWeight.bold))),
                          Icon(_expanded == i ? Icons.expand_less : Icons.expand_more, color: kGold),
                        ]),
                        if (_expanded == i) ...[
                          const SizedBox(height: 4),
                          Text(matches[i]['a']!, style: TextStyle(color: kText, fontSize: 13)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 1.9),
            itemCount: _categories.length,
            itemBuilder: (context, i) {
              final c = _categories[i];
              return InkWell(
                onTap: () => _openFaq(c['query'] as String),
                borderRadius: BorderRadius.circular(14),
                // Mockup #13 category card (MockupCard: the 2-line
                // shine, no full border — user correction 2026-11-20).
                child: MockupCard(
                  padding: const EdgeInsets.all(12),
                  radius: 14,
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(color: kGold.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
                        child: _categoryGlyph(c['glyph'] as String),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(c['label'] as String, style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 14))),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 20),
          _goldBarHeader(
            'POPULAR FAQs',
            goldFirstWord: true,
            trailing: TextButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FaqPage())),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('View All', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 2),
                  Icon(Icons.arrow_forward, color: kGold, size: 16),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Mockup #13: plain rows with gold chevrons and dividers
          // (first 3 real FAQs — the mockup's English questions are
          // sample text, never copied as content).
          for (var i = 0; i < 3; i++)
            InkWell(
              // Full question as the FaqPage query (precise filter) —
              // the old first-word-only query was coarse (e.g.
              // "Tournament" for the join question).
              onTap: () => _openFaq(_supportFaqs[i]['q']!),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Row(children: [
                      Expanded(child: Text(_supportFaqs[i]['q']!, style: TextStyle(color: kText, fontSize: 15))),
                      Icon(Icons.chevron_right, color: kGold),
                    ]),
                  ),
                  if (i < 2) Divider(color: kBorder, height: 1),
                ],
              ),
            ),
          const SizedBox(height: 16),
          // Mockup #13 Contact Support card. Live Support Chat stays
          // reachable as the secondary action (existing behaviour).
          MockupCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Contact Support', style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 4),
                Text("Can't find what you're looking for? Our support team is available 24/7.", style: TextStyle(color: kMuted, fontSize: 13)),
                const SizedBox(height: 12),
                // Mockup #13: CREATE SUPPORT TICKET is a gold PILL
                // with the ticket icon BEFORE the label.
                _goldPillBtn(label: 'CREATE SUPPORT TICKET', icon: Icons.confirmation_number, iconBefore: true, onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => NewSupportTicketPage(uid: widget.uid)))),
                const SizedBox(height: 8),
                _goldOutlineBtn(label: 'Open Live Support Chat', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LiveSupportPage(uid: widget.uid)))),
              ],
            ),
          ),
        ],
          ),
        ],
      ),
    );
  }
}

/// ---------------- NEW SUPPORT TICKET (Phase 3 #4, NEW) ----------------
///
/// The completed new-ticket flow. NOTE: the pre-existing `SupportPage`
/// used to live in more_screens.dart; the Phase 3 coordinator deleted
/// it and pointed its entry points (Profile tile, Settings row) at this
/// page, so this is now the single new-ticket flow. HelpSupportPage
/// routes to it as well.
/// Uses the existing `SupaDb.createTicket` flow; tickets appear in My
/// Tickets below with status 'open' via `streamMyTickets`.
/// NOTE (schema gap): live `support_tickets` (001) has NO `category`
/// and NO `tournament_id` column, so both are folded into the subject
/// / message text — nothing is dropped, and Phase 4 should add the
/// columns. SLA note is OD-14 display text only.
class NewSupportTicketPage extends StatefulWidget {
  final String uid;
  const NewSupportTicketPage({super.key, required this.uid});
  @override
  State<NewSupportTicketPage> createState() => _NewSupportTicketPageState();
}

class _NewSupportTicketPageState extends State<NewSupportTicketPage> {
  final _subject = TextEditingController();
  final _description = TextEditingController();
  final _tournamentId = TextEditingController();
  String? _category;
  File? _image;
  bool _busy = false;
  String? _error;

  static const _categories = [
    'General',
    'Tournament Issue',
    'Payment / Wallet',
    'Account',
    'Technical',
    'Report a Player',
  ];

  @override
  void dispose() {
    _subject.dispose();
    _description.dispose();
    _tournamentId.dispose();
    super.dispose();
  }

  Future<void> _pickScreenshot() async {
    final res = await _pickEvidenceImage();
    if (res.error != null) {
      if (mounted) toast(context, res.error!);
      return;
    }
    if (res.file != null) setState(() => _image = res.file);
  }

  Future<void> _submit() async {
    final subject = _subject.text.trim();
    final desc = _description.text.trim();
    if (subject.isEmpty || desc.isEmpty) {
      toast(context, 'Subject aur description zaroori hain.');
      return;
    }
    if (desc.length > 1000) {
      toast(context, 'Description 1000 characters se zyada nahi ho sakti.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      String imageUrl = '';
      if (_image != null) imageUrl = await ImgbbService.uploadImage(_image!);
      final profile = await SupaDb.getProfile(widget.uid);
      var message = desc;
      final tid = _tournamentId.text.trim();
      if (tid.isNotEmpty) message += '\nTournament ID: $tid';
      await SupaDb.createTicket(
        uid: widget.uid,
        // Mockup #4 shows a "Select Issue Category" placeholder; an
        // unpicked category files as General (previous default).
        subject: '[${_category ?? 'General'}] $subject',
        message: message,
        imageUrl: imageUrl,
        userEmail: SupaDb.strOf(profile['email']),
      );
      if (mounted) {
        toast(context, 'Ticket submit ho gaya — 12–24 ghante me review hoga.');
        _subject.clear();
        _description.clear();
        _tournamentId.clear();
        setState(() {
          _image = null;
          _category = null;
        });
      }
    } catch (e) {
      if (mounted) {
        if (_isOfflineError(e)) {
          setState(() => _error = 'offline');
        } else {
          setState(() => _error = 'Ticket failed: $e');
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Mockup #4: ARENA HUB lockup top-right.
      appBar: AppBar(
        title: _mockAppBarTitle('NEW SUPPORT TICKET'),
        centerTitle: true,
        actions: const [Padding(padding: EdgeInsets.only(right: 12), child: Center(child: ArenaLogo(crownSize: 28, fontSize: 13)))],
        // Mockup #4: back chevron is GOLD (plain, no box).
        leading: IconButton(icon: Icon(Icons.chevron_left, color: kGold, size: 26), onPressed: () => Navigator.maybePop(context)),
      ),
      body: Stack(
        children: [
          // Mockup #4: faint diagonal streaks top-right (same
          // shared motif as Home #37 / #13). No gold dots here.
          const Positioned.fill(child: IgnorePointer(child: _TopRightShards())),
          SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error == 'offline') ...[
              OfflineState(message: 'Check your internet connection and try again.', onRetry: _submit),
              const SizedBox(height: 12),
            ] else if (_error != null) ...[
              ErrorState(message: _error!, onRetry: _submit),
              const SizedBox(height: 12),
            ],
            _mockDropdown(
              label: 'ISSUE CATEGORY',
              value: _category,
              hint: 'Select Issue Category',
              options: _categories,
              onChanged: (v) => setState(() => _category = v),
            ),
            _mockField(controller: _subject, label: 'SUBJECT', hint: 'e.g., Match result not updating'),
            _mockField(controller: _tournamentId, label: 'TOURNAMENT ID (OPTIONAL)', hint: 'e.g., AH-94820 (Optional)'),
            _mockField(controller: _description, label: 'DETAILED DESCRIPTION', hint: 'Describe your issue in detail...', maxLines: 4),
            const SizedBox(height: 8),
            _mockSectionLabel('UPLOAD SCREENSHOT OR ATTACHMENT'),
            const SizedBox(height: 8),
            if (_image != null) ...[
              ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(_image!, height: 150, width: double.infinity, fit: BoxFit.cover)),
              Row(children: [
                Expanded(child: Text('Screenshot ready (${(_image!.lengthSync() / 1024).toStringAsFixed(0)} KB)', style: TextStyle(color: kMuted, fontSize: 12))),
                TextButton(onPressed: () => setState(() => _image = null), child: Text('Remove', style: TextStyle(color: kGold))),
              ]),
              const SizedBox(height: 8),
            ] else
              _dashedUploadBox(
                onTap: _pickScreenshot,
                child: Column(
                  children: [
                    Icon(Icons.cloud_upload_outlined, color: kGold, size: 40),
                    const SizedBox(height: 8),
                    Text('Upload Image or File', style: TextStyle(color: kText, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text('(JPG, PNG - max 5MB)', style: TextStyle(color: kMuted, fontSize: 13)),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            // Mockup #4 info card (MockupCard: the 2-line shine, no
            // full border — user correction 2026-11-20). SizedBox
            // keeps it full-width in this start-aligned Column.
            SizedBox(
              width: double.infinity,
              child: MockupCard(
                padding: const EdgeInsets.all(12),
                radius: 12,
                child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(color: kGold, shape: BoxShape.circle),
                    child: const Center(child: Text('i', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 13))),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text('Expected Response: Tickets are usually reviewed within 12-24 hours. You\'ll be notified via app and email.', style: TextStyle(color: kText, fontSize: 13))),
                ],
              ),
              ),
            ),
            const SizedBox(height: 16),
            // Mockup #4: SUBMIT TICKET is a full pill.
            _goldPillBtn(label: 'SUBMIT TICKET', onPressed: _submit, busy: _busy),
            const SizedBox(height: 20),
            _mockSectionLabel('My Tickets'),
            const SizedBox(height: 8),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: SupaDb.streamMyTickets(widget.uid),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return Column(children: const [LoadingSkeleton(height: 72), SizedBox(height: 8), LoadingSkeleton(height: 72)]);
                }
                if (snap.hasError) {
                  return ErrorState(message: 'Tickets load nahi ho sake: ${snap.error}');
                }
                final tickets = snap.data ?? [];
                if (tickets.isEmpty) {
                  return const EmptyState(
                    icon: Icons.confirmation_number_outlined,
                    title: 'No tickets yet',
                    body: 'Aap ne abhi koi support ticket nahi banaya.',
                  );
                }
                return Column(
                  children: [
                    for (final t in tickets)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TicketDetailsPage(ticket: t, uid: widget.uid))),
                          borderRadius: BorderRadius.circular(14),
                          child: MockupCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(child: Text(SupaDb.strOf(t['subject']), style: TextStyle(color: kText, fontWeight: FontWeight.bold))),
                                    Text(
                                      SupaDb.strOf(t['status'], 'open'),
                                      style: TextStyle(color: SupaDb.strOf(t['status']) == 'resolved' ? Colors.greenAccent : Colors.orangeAccent, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                                Text(SupaDb.strOf(t['message']), style: TextStyle(color: kMuted), maxLines: 2, overflow: TextOverflow.ellipsis),
                                Text(fmtDate(t['timestamp']), style: TextStyle(color: kMuted, fontSize: 11)),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
        ],
      ),
    );
  }
}

/// ---------------- TICKET DETAILS (Phase 3 #20, NEW) ----------------
class TicketDetailsPage extends StatefulWidget {
  final Map<String, dynamic> ticket;
  final String uid;
  const TicketDetailsPage({super.key, required this.ticket, required this.uid});
  @override
  State<TicketDetailsPage> createState() => _TicketDetailsPageState();
}

class _TicketDetailsPageState extends State<TicketDetailsPage> {
  final _reply = TextEditingController();
  late Map<String, dynamic> _ticket;
  List<Map<String, dynamic>> _thread = [];
  bool _busy = true;
  String? _error;
  bool _resolving = false;
  bool _sending = false;
  // Own display name for the mockup #20 "You • Player" label (real
  // profile name; plain "You" until it loads) + own photo for the
  // user avatar (ticket owner's real photo_url; empty = person icon).
  String _myName = '';
  String _myPhotoUrl = '';

  static const _steps = ['Created', 'Reviewing', 'Responded', 'Resolved'];

  @override
  void initState() {
    super.initState();
    _ticket = Map<String, dynamic>.from(widget.ticket);
    _loadThread();
    _loadMyName();
  }

  Future<void> _loadMyName() async {
    try {
      // Ticket owner first (support_tickets.firebase_uid), viewer as
      // fallback — My Tickets always opens your own ticket, so these
      // are the same UID in practice.
      final ownerUid = SupaDb.strOf(_ticket['firebase_uid'], widget.uid);
      final profile = await SupaDb.getProfile(ownerUid);
      final name = SupaDb.strOf(profile['displayName']);
      final photo = SupaDb.strOf(profile['photo_url']);
      if (!mounted) return;
      setState(() {
        if (name.isNotEmpty) _myName = name;
        _myPhotoUrl = photo;
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  /// Threaded conversation.
  /// NOTE: `SupaDb.getTicketThread` (supabase_db.dart) reads
  /// `support_messages` (migration 019, applied on staging).
  /// getList swallows read errors and returns [], so a failed
  /// read honestly shows the empty state. The live `reply`
  /// column is shown separately below.
  Future<void> _loadThread() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _thread = await SupaDb.getTicketThread(SupaDb.strOf(_ticket['id']));
    } catch (e) {
      // Defensive only: getList swallows read errors.
      if (_isOfflineError(e)) {
        _error = 'offline';
      } else {
        _error = 'Thread load nahi ho saki: $e';
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  /// 4-step tracker from the ticket's real status. Live statuses are
  /// only 'open' today (draft 019 adds reviewing / responded /
  /// resolved) — later steps light up only when those statuses land.
  /// A ticket with a real admin reply counts as Responded even while
  /// its stored status is still 'open' (single-reply era).
  int _stepFor(String status) {
    final s = status.toLowerCase();
    if (s == 'resolved' || s == 'closed') return 3;
    if (s == 'responded') return 2;
    if (SupaDb.strOf(_ticket['adminReply']).isNotEmpty ||
        _thread.any((m) => SupaDb.strOf(m['sender_role']) == 'admin')) {
      return 2;
    }
    if (s == 'reviewing') return 1;
    return 0;
  }

  /// Mark as Resolved (user) — via the data layer
  /// (`SupaDb.markTicketResolved`), not a direct client write.
  Future<void> _markResolved() async {
    setState(() => _resolving = true);
    try {
      final ok = await SupaDb.markTicketResolved(SupaDb.strOf(_ticket['id']));
      if (!ok) throw Exception('resolve failed');
      if (mounted) {
        setState(() => _ticket['status'] = 'resolved');
        toast(context, 'Ticket resolved mark ho gaya.');
      }
    } catch (e) {
      if (mounted) {
        if (_isOfflineError(e)) {
          setState(() => _error = 'offline');
        } else {
          toast(context, 'Failed: $e');
        }
      }
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  /// Send a user reply — via the data layer
  /// (`SupaDb.sendTicketReply`, inserts into `support_messages`,
  /// migration 019) — then reload the thread so the reply appears.
  /// A failed send shows an honest error toast, never a fake success.
  Future<void> _sendReply() async {
    final text = _reply.text.trim();
    if (text.isEmpty) {
      toast(context, 'Reply likhein pehle.');
      return;
    }
    setState(() => _sending = true);
    try {
      final ok = await SupaDb.sendTicketReply(SupaDb.strOf(_ticket['id']), text);
      if (!mounted) return;
      if (!ok) {
        toast(context, 'Reply send nahi ho saki — dobara try karein.');
        return;
      }
      _reply.clear();
      await _loadThread();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Mockup #20 paperclip: pick a photo (JPG/PNG ≤5MB, same picker
  /// as the ticket form), upload to ImgBB, and post it as a thread
  /// message with the real `attachment_url` — the thread already
  /// renders that column as a chip. The typed reply text (if any)
  /// goes in the same row; with no text the row carries the
  /// 'Attachment' label so the message column is never empty.
  /// A failed pick/upload/send toasts honestly and posts nothing.
  Future<void> _sendAttachment() async {
    final res = await _pickEvidenceImage();
    if (res.error != null) {
      if (mounted) toast(context, res.error!);
      return;
    }
    if (res.file == null) return;
    setState(() => _sending = true);
    try {
      final url = await ImgbbService.uploadImage(res.file!);
      final text = _reply.text.trim();
      await SupaDb.client.from('support_messages').insert({
        'ticket_id': SupaDb.strOf(_ticket['id']),
        'sender_id': _uid(),
        'sender_role': 'user',
        'message': text.isEmpty ? 'Attachment' : text,
        'attachment_url': url,
      });
      if (!mounted) return;
      _reply.clear();
      await _loadThread();
    } catch (e) {
      if (mounted) toast(context, 'Attachment send nahi ho saka: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Mockup #20 thread bubbles: agent on the left (gold headset
  /// avatar, gold name, gold-bordered bubble), user on the right
  /// (grey bubble). Times are the real message timestamps.
  Widget _agentAvatar() => Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: kGold.withValues(alpha: 0.15), shape: BoxShape.circle, border: Border.all(color: kGold)),
        child: Icon(Icons.support_agent, color: kGold, size: 20),
      );

  /// Mockup #20 user avatar: the ticket owner's real photo in the
  /// gold-ringed circle; the generic person icon only when no photo
  /// exists (empty URL or load failure — ArenaCachedAvatar falls
  /// back). Agent avatar stays the gold headset icon (no agent photo
  /// exists).
  Widget _userAvatar() => Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(color: kField, shape: BoxShape.circle, border: Border.all(color: kGold)),
        child: ArenaCachedAvatar(
          photoUrl: _myPhotoUrl,
          radius: 16,
          backgroundColor: kField,
          fallback: Icon(Icons.person, color: kGold, size: 20),
        ),
      );

  /// Attachment chip (mockup #20): real thumbnail + real file name
  /// from the URL. Size is NOT shown — it is not stored anywhere, and
  /// a fake "1.2 MB" would be invented data.
  Widget _attachmentChip(String url) {
    final segments = Uri.tryParse(url)?.pathSegments ?? [];
    final name = segments.isEmpty ? 'attachment' : segments.last;
    return InkWell(
      onTap: () async {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
      },
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(10), border: Border.all(color: kBorder)),
        child: Row(
          children: [
            // WAVE 4 FIX 5 (B): disk-cached attachment thumbnail
            // (was bare Image.network). Error state is now the shared
            // dark card + broken-image icon (was a 44px image icon);
            // the 44px box clips the shared error text, icon only.
            ArenaCachedImage(imageUrl: url, width: 44, height: 44, fit: BoxFit.cover, borderRadius: BorderRadius.circular(6), placeholderIcon: Icons.image),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: TextStyle(color: kText, fontSize: 13), overflow: TextOverflow.ellipsis),
                  Text('Tap to view', style: TextStyle(color: kMuted, fontSize: 11)),
                ],
              ),
            ),
            Icon(Icons.download, color: kGold, size: 20),
          ],
        ),
      ),
    );
  }

  /// The legacy single `adminReply` column carries no reply
  /// timestamp, so it renders WITHOUT a time — showing the ticket's
  /// creation time as the reply time would be wrong (mockup #20
  /// shows distinct 7:12 PM / 7:30 PM times). Thread rows carry
  /// their real timestamps and still show them.
  Widget _adminMessage({required String text, dynamic ts, String? attachmentUrl}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _agentAvatar(),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Support Agent • Team Arena Hub', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 13)),
                  if (ts != null) Text(_fmtClock(ts), style: TextStyle(color: kMuted, fontSize: 11)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kGold.withValues(alpha: 0.6))),
            child: Text(text, style: TextStyle(color: kText, fontSize: 14)),
          ),
          // Mockup #20: the file chip is a separate card BELOW the
          // bubble, not nested inside it.
          if (attachmentUrl != null && attachmentUrl.isNotEmpty) ...[
            const SizedBox(height: 8),
            _attachmentChip(attachmentUrl),
          ],
        ],
      ),
    );
  }

  Widget _userMessage({required String text, required dynamic ts, String? attachmentUrl}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Mockup #20: "You • Player".
                  Text(_myName.isEmpty ? 'You' : 'You • $_myName', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 13)),
                  Text(_fmtClock(ts), style: TextStyle(color: kMuted, fontSize: 11)),
                ],
              ),
              const SizedBox(width: 8),
              _userAvatar(),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(12)),
            child: Text(text, style: TextStyle(color: kText, fontSize: 14)),
          ),
          // Mockup #20: the file chip is a separate card BELOW the
          // bubble, not nested inside it.
          if (attachmentUrl != null && attachmentUrl.isNotEmpty) ...[
            const SizedBox(height: 8),
            _attachmentChip(attachmentUrl),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = SupaDb.strOf(_ticket['status'], 'open');
    final adminReply = SupaDb.strOf(_ticket['adminReply']);
    final imageUrl = SupaDb.strOf(_ticket['imageUrl']);
    // Category + subject are folded into one string by the create
    // flow ("[Category] Subject") — split them back for display
    // (mockup #20 shows "Category: Tournament Support").
    final rawSubject = SupaDb.strOf(_ticket['subject']);
    final catMatch = RegExp(r'^\[(.+?)\]\s*').firstMatch(rawSubject);
    final category = catMatch?.group(1) ?? 'General';
    final subject = catMatch == null ? rawSubject : rawSubject.substring(catMatch.end);
    final ticketId = SupaDb.strOf(_ticket['id']);
    final isResolved = status.toLowerCase() == 'resolved' || status.toLowerCase() == 'closed';
    // Date divider label (mockup #20 "TODAY").
    final createdMs = SupaDb.parseTs(_ticket['timestamp']);
    final now = DateTime.now();
    final createdDate = createdMs > 0 ? DateTime.fromMillisecondsSinceEpoch(createdMs) : null;
    final isToday = createdDate != null && createdDate.year == now.year && createdDate.month == now.month && createdDate.day == now.day;
    final dividerLabel = isToday ? 'TODAY' : fmtDate(_ticket['timestamp']);
    return Scaffold(
      appBar: AppBar(
        // Mockup #20 title is ITALIC; back chevron is plain GOLD.
        title: _mockAppBarTitle('TICKET DETAILS', italic: true),
        centerTitle: true,
        leading: IconButton(icon: Icon(Icons.chevron_left, color: kGold, size: 26), onPressed: () => Navigator.maybePop(context)),
        actions: [
          // Mockup #20: small crown emblem beside the title.
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: Center(child: ArenaLogo(showWordmark: false, crownSize: 28)),
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_horiz, color: kGold),
            color: kCard,
            onSelected: (v) {
              if (v == 'copy') {
                Clipboard.setData(ClipboardData(text: ticketId));
                toast(context, 'Ticket ID copy ho gaya!');
              }
            },
            itemBuilder: (_) => [PopupMenuItem(value: 'copy', child: Text('Copy ticket ID', style: TextStyle(color: kText)))],
          ),
        ],
      ),
      body: Stack(
        children: [
          // Mockup #20 background: faint gold dust specks near
          // the bottom corners (shared ArenaEmberDots, behind
          // content, taps pass through).
          const Positioned.fill(child: IgnorePointer(child: ArenaEmberDots())),
          Column(
        children: [
          Expanded(
            child: _busy
                ? ListView(
                    padding: const EdgeInsets.all(16),
                    children: const [
                      LoadingSkeleton(height: 96),
                      SizedBox(height: 12),
                      LoadingSkeleton(height: 64),
                      SizedBox(height: 12),
                      LoadingSkeleton(height: 64),
                    ],
                  )
                : _error == 'offline'
                    ? Center(child: OfflineState(message: 'Check your internet connection and try again.', onRetry: _loadThread))
                    : _error != null
                        ? Center(child: ErrorState(message: _error!, onRetry: _loadThread))
                        : ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              // Mockup #20 ticket summary card
                              // (MockupCard: the 2-line shine, no full
                              // border and no glow — user correction
                              // 2026-11-20).
                              MockupCard(
                                padding: const EdgeInsets.all(14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(children: [
                                      Expanded(child: Text('Ticket #$ticketId', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 18), overflow: TextOverflow.ellipsis)),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: isResolved ? Colors.green : kGold)),
                                        child: Text(status.toUpperCase(), style: TextStyle(color: isResolved ? Colors.greenAccent : kGold, fontSize: 11, fontWeight: FontWeight.bold)),
                                      ),
                                    ]),
                                    const SizedBox(height: 4),
                                    Text(subject, style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 16)),
                                    const SizedBox(height: 2),
                                    Text('Category: $category', style: TextStyle(color: kMuted, fontSize: 13)),
                                    if (imageUrl.isNotEmpty) ...[
                                      const SizedBox(height: 10),
                                      _attachmentChip(imageUrl),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                              // Mockup #20: done-step labels are GREY,
                              // only the current step ("Responded") is
                              // gold bold, and its circle has a halo.
                              _StepTracker(steps: _steps, current: _stepFor(status), doneLabelsGold: false, glowCurrent: true),
                              const SizedBox(height: 16),
                              if (!isResolved) ...[
                                _goldOutlineBtn(label: 'MARK AS RESOLVED', icon: Icons.check, goldText: true, onPressed: _resolving ? null : _markResolved),
                                const SizedBox(height: 16),
                              ],
                              Row(children: [
                                Expanded(child: Divider(color: kBorder)),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  child: Text(dividerLabel, style: TextStyle(color: kMuted, fontSize: 12, fontWeight: FontWeight.bold)),
                                ),
                                Expanded(child: Divider(color: kBorder)),
                              ]),
                              const SizedBox(height: 12),
                              // The ticket's own opening message, as the
                              // first user bubble in the thread.
                              if (SupaDb.strOf(_ticket['message']).isNotEmpty)
                                _userMessage(text: SupaDb.strOf(_ticket['message']), ts: _ticket['timestamp']),
                              if (adminReply.isNotEmpty) _adminMessage(text: adminReply),
                              if (_thread.isEmpty && adminReply.isEmpty)
                                const EmptyState(
                                  icon: Icons.forum_outlined,
                                  title: 'No replies yet',
                                  body: 'Is ticket par abhi koi threaded reply nahi hai.',
                                ),
                              for (final m in _thread)
                                SupaDb.strOf(m['sender_role']) == 'admin'
                                    ? _adminMessage(text: SupaDb.strOf(m['message']), ts: m['created_at'] ?? m['timestamp'], attachmentUrl: SupaDb.strOf(m['attachment_url']))
                                    : _userMessage(text: SupaDb.strOf(m['message']), ts: m['created_at'] ?? m['timestamp'], attachmentUrl: SupaDb.strOf(m['attachment_url'])),
                            ],
                          ),
          ),
          // Reply composer: SEND inserts into `support_messages`
          // (migration 019) via `SupaDb.sendTicketReply`, then the
          // thread reloads so the reply appears.
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: kCard, border: Border(top: BorderSide(color: kField))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  IconButton(
                    onPressed: _sending ? null : _sendAttachment,
                    icon: Icon(Icons.attach_file, color: kGold),
                    tooltip: 'Attach photo',
                  ),
                  Expanded(
                    // FIX 23 item 29: card look via CardFieldShell.
                    child: CardFieldShell(
                      radius: 24,
                      child: TextField(
                      controller: _reply,
                      style: TextStyle(color: kText),
                      decoration: InputDecoration(
                        hintText: 'Type your reply...',
                        hintStyle: TextStyle(color: kMuted),
                        contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                        border: const OutlineInputBorder(borderSide: BorderSide.none),
                      ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Mockup #20: compact gold SEND pill.
                  _goldPillBtn(label: 'SEND', icon: Icons.arrow_forward, fullWidth: false, onPressed: _sending ? null : _sendReply, busy: _sending),
                ]),
              ],
            ),
          ),
        ],
          ),
        ],
      ),
    );
  }
}
/// ---------------- SHARE: STATS CARD & POSTER ----------------

class ShareHubPage extends StatelessWidget {
  final String uid;
  final Map<String, dynamic>? targetProfile;
  const ShareHubPage({super.key, required this.uid, this.targetProfile});
  @override
  Widget build(BuildContext context) {
    final profileUid = targetProfile != null ? SupaDb.strOf(targetProfile!['uid']) : uid;
    return Scaffold(
      appBar: AppBar(title: Text('Stats Card & Poster', style: TextStyle(color: kGold))),
      body: FutureBuilder<Map<String, dynamic>>(
        future: SupaDb.getProfile(profileUid),
        builder: (context, snap) {
          final p = snap.data ?? {};
          if (snap.connectionState == ConnectionState.waiting) return Center(child: CircularProgressIndicator(color: kGold));
          return FutureBuilder<Map<String, int>>(
            future: playerProgress(profileUid),
            builder: (context, psnap) {
              final pr = psnap.data ?? {'xp': 0, 'level': 1, 'mmr': 1000, 'matches': 0, 'wins': 0, 'kills': 0};
              final card = '🏆 PRO TOURNAMENT — PLAYER CARD\n'
                  'Player: ${SupaDb.strOf(p['displayName'])}\n'
                  'Level ${pr['level']} • XP ${pr['xp']} • MMR ${pr['mmr']}\n'
                  'Matches: ${pr['matches']} • Wins: ${pr['wins']} • Kills: ${pr['kills']}\n'
                  'Join ARENA HUB and challenge me!';
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  MockupCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('🏆 PRO TOURNAMENT', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 18)),
                        const SizedBox(height: 8),
                        Text(SupaDb.strOf(p['displayName']), style: TextStyle(color: kText, fontSize: 22, fontWeight: FontWeight.bold)),
                        Text('Level ${pr['level']}  •  XP ${pr['xp']}  •  MMR ${pr['mmr']}', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
                        Text('Matches: ${pr['matches']}  •  Wins: ${pr['wins']}  •  Kills: ${pr['kills']}', style: TextStyle(color: kText)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  goldButton(
                    label: 'Share on WhatsApp',
                    onPressed: () async {
                      final uri = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(card)}');
                      if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
                    },
                  ),
                  const SizedBox(height: 10),
                  goldButton(
                    label: 'Share (Any App)',
                    onPressed: () => Share.share(card, subject: 'My ARENA HUB Card'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PosterPage(uid: uid))),
                    style: OutlinedButton.styleFrom(side: BorderSide(color: kGold)),
                    child: Text('Tournament Poster Generator', style: TextStyle(color: kGold)),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class PosterPage extends StatefulWidget {
  final String uid;
  const PosterPage({super.key, required this.uid});
  @override
  State<PosterPage> createState() => _PosterPageState();
}

class _PosterPageState extends State<PosterPage> {
  Map<String, dynamic>? _selected;

  String get _posterText {
    if (_selected == null) return 'PRO TOURNAMENT\nKoi tournament select karen';
    return '🏆 ${_selected!['name']}\n'
        'Game: ${SupaDb.strOf(_selected!['gameName'])}\n'
        'Prize Pool: ${fmtRs(SupaDb.numOf(_selected!['prizePool']))}\n'
        'Entry Fee: ${fmtRs(SupaDb.numOf(_selected!['entryFee']))}\n'
        'Mode: ${SupaDb.strOf(_selected!['mode'])}\n'
        'Join now on ARENA HUB!';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Poster Generator', style: TextStyle(color: kGold))),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: SupaDb.getTournaments(),
        builder: (context, snap) {
          final list = snap.data ?? [];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('Tournament chunen, phir poster share karen (WhatsApp / Instagram ke liye text poster).', style: TextStyle(color: kMuted, fontSize: 13)),
              const SizedBox(height: 12),
              for (final t in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InkWell(
                    onTap: () => setState(() => _selected = t),
                    child: MockupCard(
                      child: Row(children: [
                        Expanded(child: Text(SupaDb.strOf(t['name']), style: TextStyle(color: kText, fontWeight: FontWeight.bold))),
                        if (_selected != null && SupaDb.strOf(_selected!['id']) == SupaDb.strOf(t['id'])) Icon(Icons.check_circle, color: kGold),
                      ]),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: const Color(0xFF2A1C08), borderRadius: BorderRadius.circular(16), border: Border.all(color: kGold, width: 2)),
                child: Text(_posterText, style: const TextStyle(color: Color(0xFFFDC903), fontSize: 16, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
              ),
              const SizedBox(height: 16),
              goldButton(
                label: 'Share Poster on WhatsApp',
                onPressed: _selected == null
                    ? null
                    : () async {
                        final uri = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(_posterText)}');
                        if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
                      },
              ),
              const SizedBox(height: 10),
              goldButton(
                label: 'Share Poster (Any App)',
                onPressed: _selected == null ? null : () => Share.share(_posterText, subject: 'Tournament Poster'),
              ),
              const SizedBox(height: 8),
              Text('Note: yeh text poster hai (image poster ke liye screenshot le kar share karen). Koi paid design tool use nahi hua.', style: TextStyle(color: kMuted, fontSize: 12)),
            ],
          );
        },
      ),
    );
  }
}

/// ---------------- HIGHLIGHT CLIPS ----------------

class ClipsPage extends StatefulWidget {
  final String uid;
  const ClipsPage({super.key, required this.uid});
  @override
  State<ClipsPage> createState() => _ClipsPageState();
}

class _ClipsPageState extends State<ClipsPage> {
  List<Map<String, dynamic>> _clips = [];
  bool _pending = false;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _clips = await SupaDb.getList('room_clips', orderBy: 'created_at', ascending: false, limit: 50);
    } catch (e) {
      if (proTableMissing(e)) _pending = true;
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _addClip() async {
    final titleCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text('Add Highlight Clip', style: TextStyle(color: kGold)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              field(controller: titleCtrl, label: 'Clip title'),
              field(controller: urlCtrl, label: 'Video link (YouTube / Drive / direct)'),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel', style: TextStyle(color: kMuted))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text('Add', style: TextStyle(color: kGold))),
        ],
      ),
    );
    if (ok != true || titleCtrl.text.trim().isEmpty || urlCtrl.text.trim().isEmpty) return;
    try {
      final profile = await SupaDb.getProfile(widget.uid);
      await SupaDb.client.from('room_clips').insert({
        'title': titleCtrl.text.trim(),
        'video_url': urlCtrl.text.trim(),
        'uploaded_by': widget.uid,
        'uploader_name': SupaDb.strOf(profile['displayName'], 'User'),
      });
      if (mounted) toast(context, 'Clip add ho gaya!');
      _load();
    } catch (e) {
      if (mounted) toast(context, proTableMissing(e) ? 'Backend pending — migration 008 chalani hogi (room_clips table).' : 'Failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Highlight Clips', style: TextStyle(color: kGold))),
      body: _busy
          ? Center(child: CircularProgressIndicator(color: kGold))
          : _pending
              ? ListView(padding: const EdgeInsets.all(16), children: [proPendingCard('Highlight Clips')])
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    goldButton(label: 'Add Clip (Link)', onPressed: _addClip),
                    const SizedBox(height: 8),
                    Text('Note: clips link ke zariye share hote hain (koi paid video server nahi). Direct video upload ke liye Storage bucket "room-clips" banana hoga — tab tak link wale clips hi dikhenge.', style: TextStyle(color: kMuted, fontSize: 12)),
                    const SizedBox(height: 16),
                    if (_clips.isEmpty) proEmpty('Abhi koi clip nahi. Apna match highlight link se add karen!'),
                    for (final c in _clips)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: MockupCard(
                          child: Row(children: [
                            Icon(Icons.play_circle_fill, color: kGold, size: 36),
                            const SizedBox(width: 10),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(SupaDb.strOf(c['title']), style: TextStyle(color: kText, fontWeight: FontWeight.bold)), Text('By ${SupaDb.strOf(c['uploader_name'])}', style: TextStyle(color: kMuted, fontSize: 12))])),
                            TextButton(
                              onPressed: () async {
                                final uri = Uri.tryParse(SupaDb.strOf(c['video_url']));
                                if (uri != null && await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
                              },
                              child: Text('Watch', style: TextStyle(color: kGold)),
                            ),
                          ]),
                        ),
                      ),
                  ],
                ),
    );
  }
}

/// ---------------- SPECTATE & SHOUTCASTER ----------------

class SpectatePage extends StatelessWidget {
  final String uid;
  const SpectatePage({super.key, required this.uid});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Spectate a Room', style: TextStyle(color: kGold))),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: SupaDb.getTournaments(),
        builder: (context, snap) {
          final list = (snap.data ?? []).where((t) => SupaDb.strOf(t['status']) == 'ongoing' || SupaDb.strOf(t['status']) == 'upcoming').toList();
          if (snap.connectionState == ConnectionState.waiting) return Center(child: CircularProgressIndicator(color: kGold));
          if (list.isEmpty) return proEmpty('Abhi koi live/upcoming tournament nahi.');
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            itemBuilder: (context, i) {
              final t = list[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: MockupCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(SupaDb.strOf(t['name']), style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
                      Text('${SupaDb.strOf(t['status'])} • ${SupaDb.strOf(t['gameName'])}', style: TextStyle(color: kMuted, fontSize: 12)),
                      const SizedBox(height: 8),
                      Row(children: [
                        TextButton(
                          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => UnifiedRoomPage(tournamentId: SupaDb.strOf(t['id']), tournamentName: SupaDb.strOf(t['name']), scope: 'tournament', mode: SupaDb.strOf(t['mode'], 'Solo'), spectator: true))),
                          child: Text('Spectate (View Only)', style: TextStyle(color: kGold)),
                        ),
                        TextButton(
                          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => UnifiedRoomPage(tournamentId: SupaDb.strOf(t['id']), tournamentName: SupaDb.strOf(t['name']), scope: 'tournament', mode: SupaDb.strOf(t['mode'], 'Solo'), spectator: true, shoutcaster: true))),
                          child: Text('Shoutcaster', style: TextStyle(color: kGold)),
                        ),
                      ]),
                      Text('Spectator: sirf dekhen + chat parhen. Shoutcaster: highlighted SHOUT messages bhej sakte hain + voice sun sakte hain (seat free ho to voice roster me dikhenge).', style: TextStyle(color: kMuted, fontSize: 11)),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// ---------------- HOST TOOLS ----------------

class HostToolsHubPage extends StatelessWidget {
  final String uid;
  const HostToolsHubPage({super.key, required this.uid});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Host Tools', style: TextStyle(color: kGold))),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: SupaDb.getTournaments(),
        builder: (context, snap) {
          final list = snap.data ?? [];
          if (snap.connectionState == ConnectionState.waiting) return Center(child: CircularProgressIndicator(color: kGold));
          if (list.isEmpty) return proEmpty('Koi tournament nahi mila.');
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            itemBuilder: (context, i) {
              final t = list[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: MockupCard(
                  child: Row(children: [
                    Expanded(child: Text(SupaDb.strOf(t['name']), style: TextStyle(color: kText, fontWeight: FontWeight.bold))),
                    TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => HostToolsPage(tournament: t, uid: uid))), child: Text('Host Tools', style: TextStyle(color: kGold))),
                  ]),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class HostToolsPage extends StatefulWidget {
  final Map<String, dynamic> tournament;
  final String uid;
  const HostToolsPage({super.key, required this.tournament, required this.uid});
  @override
  State<HostToolsPage> createState() => _HostToolsPageState();
}

class _HostToolsPageState extends State<HostToolsPage> {
  bool _isHost = false;
  bool _pending = false;
  List<Map<String, dynamic>> _peers = [];
  Set<int> _lockedSeats = {};
  final _pinCtrl = TextEditingController();
  final _coHostCtrl = TextEditingController();

  String get _voiceRoomId => tournamentRoomId(SupaDb.strOf(widget.tournament['id']));

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final createdBy = SupaDb.strOf(widget.tournament['created_by']);
      var host = createdBy.isNotEmpty && createdBy == widget.uid;
      if (!host) {
        final hosts = await SupaDb.getList('room_hosts', eqCol: 'tournament_id', eqVal: SupaDb.strOf(widget.tournament['id']), eqCol2: 'firebase_uid', eqVal2: widget.uid);
        host = hosts.isNotEmpty;
      }
      _peers = await SupaDb.getVoicePeers(_voiceRoomId);
      final locks = await SupaDb.getList('room_seat_locks', eqCol: 'room_id', eqVal: _voiceRoomId);
      if (mounted) setState(() {
        _isHost = host;
        _lockedSeats = locks.map((l) => SupaDb.intOf(l['seat_no'])).toSet();
      });
    } catch (e) {
      if (proTableMissing(e) && mounted) setState(() => _pending = true);
    }
  }

  Future<void> _muteAll() async {
    try {
      await SupaDb.client.from('voice_signaling_peers').update({'muted': true}).eq('room_id', _voiceRoomId);
      if (mounted) toast(context, 'Sab members mute kar diye gaye (host mute-all).');
      _load();
    } catch (e) {
      if (mounted) toast(context, 'Mute-all failed: $e');
    }
  }

  Future<void> _removePeer(String peerUid, String name) async {
    try {
      await SupaDb.client.from('voice_signaling_peers').delete().eq('room_id', _voiceRoomId).eq('firebase_uid', peerUid);
      if (mounted) toast(context, '$name ko seat se hata diya gaya.');
      _load();
    } catch (e) {
      if (mounted) toast(context, 'Remove failed: $e');
    }
  }

  Future<void> _mutePlayer(String peerUid, String name) async {
    try {
      // No unique constraint on room_mutes, so replace any old row
      // instead of upsert (anon policy permits delete + insert).
      await SupaDb.client.from('room_mutes').delete().eq('tournament_id', SupaDb.strOf(widget.tournament['id'])).eq('firebase_uid', peerUid);
      await SupaDb.client.from('room_mutes').insert({'tournament_id': SupaDb.strOf(widget.tournament['id']), 'firebase_uid': peerUid, 'muted_by': widget.uid, 'active': true});
      if (mounted) toast(context, '$name mute ho gaya — ab chat/voice nahi kar sakega jab tak unmute na ho.');
    } catch (e) {
      if (mounted) toast(context, proTableMissing(e) ? 'Backend pending — migration 011 chalani hogi.' : 'Mute failed: $e');
    }
  }

  Future<void> _unmutePlayer(String peerUid, String name) async {
    try {
      await SupaDb.client.from('room_mutes').update({'active': false}).eq('tournament_id', SupaDb.strOf(widget.tournament['id'])).eq('firebase_uid', peerUid);
      if (mounted) toast(context, '$name unmute ho gaya.');
    } catch (e) {
      if (mounted) toast(context, 'Unmute failed: $e');
    }
  }

  Future<void> _toggleSeatLock(int seat) async {
    try {
      if (_lockedSeats.contains(seat)) {
        await SupaDb.client.from('room_seat_locks').delete().eq('room_id', _voiceRoomId).eq('seat_no', seat);
      } else {
        await SupaDb.client.from('room_seat_locks').insert({'room_id': _voiceRoomId, 'seat_no': seat, 'locked_by': widget.uid});
      }
      _load();
    } catch (e) {
      if (mounted) toast(context, proTableMissing(e) ? 'Backend pending — migration 008 chalani hogi.' : 'Failed: $e');
    }
  }

  Future<void> _pinMessage() async {
    if (_pinCtrl.text.trim().isEmpty) return;
    try {
      await SupaDb.client.from('pinned_messages').insert({'tournament_id': SupaDb.strOf(widget.tournament['id']), 'message': _pinCtrl.text.trim(), 'pinned_by': widget.uid});
      if (mounted) toast(context, 'Message pin ho gaya — sab members ko room me dikhega.');
      _pinCtrl.clear();
    } catch (e) {
      if (mounted) toast(context, proTableMissing(e) ? 'Backend pending — migration 008 chalani hogi.' : 'Failed: $e');
    }
  }

  Future<void> _grantCoHost() async {
    if (_coHostCtrl.text.trim().isEmpty) return;
    try {
      await SupaDb.client.from('room_hosts').insert({'tournament_id': SupaDb.strOf(widget.tournament['id']), 'firebase_uid': _coHostCtrl.text.trim(), 'role': 'co-host', 'granted_by': widget.uid});
      if (mounted) toast(context, 'Co-host grant ho gaya!');
      _coHostCtrl.clear();
    } catch (e) {
      if (mounted) toast(context, proTableMissing(e) ? 'Backend pending — migration 008 chalani hogi.' : 'Failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Host Tools — ${SupaDb.strOf(widget.tournament['name'])}', style: TextStyle(color: kGold))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_pending) proPendingCard('Host Tools (seat locks / co-host / pins)'),
          if (!_isHost)
            MockupCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Aap is room ke host/co-host nahi hain', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)), SizedBox(height: 4), Text('Host tools sirf tournament creator ya granted co-host use kar sakta hai. Room me entry animation (animated welcome) aur custom theme (Backgrounds button) sab ke liye khula hai.', style: TextStyle(color: kMuted, fontSize: 13))])),
          if (_isHost) ...[
            goldButton(label: 'Mute All Members', onPressed: _muteAll),
            const SizedBox(height: 16),
            _mockSectionLabel('Seat Lock (host-locked seats par koi Take mic nahi kar sakega)'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [for (var s = 1; s <= 8; s++) ChoiceChip(label: Text('Seat $s'), selected: _lockedSeats.contains(s), selectedColor: kGold, labelStyle: TextStyle(color: _lockedSeats.contains(s) ? Colors.black : kText), onSelected: (_) => _toggleSeatLock(s))],
            ),
            const SizedBox(height: 16),
            _mockSectionLabel('Remove from Seat'),
            const SizedBox(height: 8),
            if (_peers.isEmpty) proEmpty('Abhi koi member voice par nahi hai.'),
            for (final p in _peers)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: MockupCard(child: Row(children: [Expanded(child: Text(SupaDb.strOf(p['display_name'], SupaDb.strOf(p['name'], 'Member')), style: TextStyle(color: kText))), TextButton(onPressed: () => _mutePlayer(SupaDb.strOf(p['firebase_uid'], SupaDb.strOf(p['uid'])), SupaDb.strOf(p['display_name'], 'Member')), child: Text('Mute', style: TextStyle(color: Colors.orangeAccent))), TextButton(onPressed: () => _unmutePlayer(SupaDb.strOf(p['firebase_uid'], SupaDb.strOf(p['uid'])), SupaDb.strOf(p['display_name'], 'Member')), child: Text('Unmute', style: TextStyle(color: kGold))), TextButton(onPressed: () => _removePeer(SupaDb.strOf(p['firebase_uid'], SupaDb.strOf(p['uid'])), SupaDb.strOf(p['display_name'], 'Member')), child: Text('Remove', style: TextStyle(color: Colors.redAccent)))])),
              ),
            const SizedBox(height: 16),
            _mockSectionLabel('Pinned Message (live chat ke upar sab ko dikhega)'),
            const SizedBox(height: 8),
            field(controller: _pinCtrl, label: 'Pinned message'),
            goldButton(label: 'Pin Message', onPressed: _pinMessage),
            const SizedBox(height: 16),
            _mockSectionLabel('Grant Co-host'),
            const SizedBox(height: 8),
            field(controller: _coHostCtrl, label: 'Co-host player UID'),
            goldButton(label: 'Grant Co-host', onPressed: _grantCoHost),
          ],
        ],
      ),
    );
  }
}

/// ---------------- ONBOARDING / GUIDED TOUR ----------------

/// ---------------- APP SETTINGS EXTRAS ----------------

class SettingsExtrasPage extends StatefulWidget {
  const SettingsExtrasPage({super.key});
  @override
  State<SettingsExtrasPage> createState() => _SettingsExtrasPageState();
}

class _SettingsExtrasPageState extends State<SettingsExtrasPage> {
  bool _lowData = false;
  bool _soundOn = true;
  String _textSize = 'medium';
  String _language = 'en';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _lowData = prefs.getBool('low_data_mode') ?? false;
        _soundOn = prefs.getBool('sound_enabled') ?? true;
        _textSize = prefs.getString('text_size') ?? 'medium';
        _language = prefs.getString('app_language') ?? 'en';
      });
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('low_data_mode', _lowData);
    await SoundService.setEnabled(_soundOn);
    await prefs.setString('text_size', _textSize);
    await prefs.setString('app_language', _language);
    if (mounted) toast(context, 'Settings save ho gayi. Text size aur language ke liye app restart karen.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('App Settings', style: TextStyle(color: kGold))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            value: _soundOn,
            activeColor: kGold,
            title: Text('Sound pack', style: TextStyle(color: kText)),
            subtitle: Text('ON ho to tap, message, mic join, gift aur win par sound bajega. OFF = bilkul khamosh.', style: TextStyle(color: kMuted, fontSize: 12)),
            onChanged: (v) => setState(() => _soundOn = v),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            value: _lowData,
            activeColor: kGold,
            title: Text('Low-data mode', style: TextStyle(color: kText)),
            subtitle: Text('ON ho to room ki images tap karne par load hongi (data bachega).', style: TextStyle(color: kMuted, fontSize: 12)),
            onChanged: (v) => setState(() => _lowData = v),
          ),
          const SizedBox(height: 8),
          _mockSectionLabel('Text Size (restart ke baad lagega)'),
          Row(children: [
            for (final s in ['small', 'medium', 'large'])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(label: Text(s), selected: _textSize == s, selectedColor: kGold, labelStyle: TextStyle(color: _textSize == s ? Colors.black : kText), onSelected: (_) => setState(() => _textSize = s)),
              ),
          ]),
          const SizedBox(height: 16),
          _mockSectionLabel('Theme (Board Design: Dark / Light)'),
          SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: ChoiceChip(
                label: const Text('Dark (Board)'),
                selected: !themeLightNotifier.value,
                selectedColor: kGold,
                labelStyle: TextStyle(color: !themeLightNotifier.value ? Colors.black : kText),
                onSelected: (_) async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('theme_mode', 'dark');
                  themeLightNotifier.value = false;
                  if (mounted) setState(() {});
                },
              ),
            ),
            SizedBox(width: 8),
            Expanded(
              child: ChoiceChip(
                label: const Text('Light'),
                selected: themeLightNotifier.value,
                selectedColor: kGold,
                labelStyle: TextStyle(color: themeLightNotifier.value ? Colors.black : kText),
                onSelected: (_) async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('theme_mode', 'light');
                  themeLightNotifier.value = true;
                  if (mounted) setState(() {});
                },
              ),
            ),
          ]),
          SizedBox(height: 4),
          Text('Dark = board jaisa (navy + orange + gold). Light = wahi layout, halki palette, orange buttons wahi rahenge. Live room dono mode me dark stage rakhta hai (board ka room bhi dark hai).', style: TextStyle(color: kMuted, fontSize: 12)),
          SizedBox(height: 16),
          _mockSectionLabel('Language'),
          Row(children: [
            for (final l in [
              {'k': 'en', 'l': 'English'},
              {'k': 'ur', 'l': 'Roman Urdu'},
            ])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(label: Text(l['l']!), selected: _language == l['k'], selectedColor: kGold, labelStyle: TextStyle(color: _language == l['k'] ? Colors.black : kText), onSelected: (_) => setState(() => _language = l['k']!)),
              ),
          ]),
          const SizedBox(height: 8),
          Text('Note: Roman Urdu toggle shell, Home headings, App Settings aur Pro Hub par lagta hai (restart ke baad). Room chat, tournament detail forms, wallet forms, admin app aur system dialogs abhi English me hi rahenge.', style: TextStyle(color: kMuted, fontSize: 12)),
          const SizedBox(height: 16),
          goldButton(label: 'Save Settings', onPressed: _save),
        ],
      ),
    );
  }
}

/// ---------------- WALLET EXTRAS: history filter, withdrawals, proofs,
/// referral leaderboard ----------------

class TransactionsPage extends StatefulWidget {
  final String uid;
  const TransactionsPage({super.key, required this.uid});
  @override
  State<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends State<TransactionsPage> {
  String _filter = 'all'; // all | credit | debit | points | prize

  bool _matches(Map<String, dynamic> t) {
    final amount = SupaDb.numOf(t['amount']);
    final type = SupaDb.strOf(t['type']);
    switch (_filter) {
      case 'credit':
        return amount > 0;
      case 'debit':
        return amount < 0;
      case 'points':
        return {'spin_points', 'quiz_points', 'daily_reward', 'season_reward', 'cheer_points'}.contains(type);
      case 'prize':
        return type.contains('prize') || type.contains('winning');
      default:
        return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Full History & Withdrawals', style: TextStyle(color: kGold))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final f in [
                {'k': 'all', 'l': 'All'},
                {'k': 'credit', 'l': 'Credits'},
                {'k': 'debit', 'l': 'Debits'},
                {'k': 'points', 'l': 'Points'},
                {'k': 'prize', 'l': 'Prizes'},
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(label: Text(f['l']!), selected: _filter == f['k'], selectedColor: kGold, labelStyle: TextStyle(color: _filter == f['k'] ? Colors.black : kText), onSelected: (_) => setState(() => _filter = f['k']!)),
                ),
            ]),
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: SupaDb.getTransactions(widget.uid),
            builder: (context, snap) {
              final txs = (snap.data ?? []).where(_matches).toList();
              if (snap.connectionState == ConnectionState.waiting) return Center(child: CircularProgressIndicator(color: kGold));
              if (txs.isEmpty) return proEmpty('Is filter me koi transaction nahi.');
              return Column(children: [
                for (final t in txs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: MockupCard(
                      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(SupaDb.strOf(t['description'], SupaDb.strOf(t['type'])), style: TextStyle(color: kText, fontWeight: FontWeight.bold)), Text('${SupaDb.strOf(t['type'])} • ${fmtDate(t['timestamp'])}', style: TextStyle(color: kMuted, fontSize: 12))])),
                        Text('${SupaDb.numOf(t['amount']) < 0 ? '' : '+'}${fmtRs(SupaDb.numOf(t['amount']))}', style: TextStyle(color: SupaDb.numOf(t['amount']) < 0 ? Colors.redAccent : Colors.greenAccent, fontWeight: FontWeight.bold)),
                      ]),
                    ),
                  ),
              ]);
            },
          ),
          const SizedBox(height: 20),
          _mockSectionLabel('My Withdrawals (status tracking)'),
          const SizedBox(height: 8),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: SupaDb.getList('withdrawals', eqCol: 'firebase_uid', eqVal: widget.uid, orderBy: 'created_at', ascending: false),
            builder: (context, snap) {
              final rows = snap.data ?? [];
              if (snap.connectionState == ConnectionState.waiting) return Center(child: CircularProgressIndicator(color: kGold));
              if (rows.isEmpty) return proEmpty('Abhi koi withdrawal request nahi. Withdrawal sirf winning balance se hoti hai.');
              return Column(children: [
                for (final w in rows)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: MockupCard(
                      child: Row(children: [
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(fmtRs(SupaDb.numOf(w['amount'])), style: TextStyle(color: kText, fontWeight: FontWeight.bold)), Text(SupaDb.strOf(w['method_name'], SupaDb.strOf(w['method'], SupaDb.strOf(w['payment_method']))), style: TextStyle(color: kMuted, fontSize: 12))])),
                        Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kGold)), child: Text(SupaDb.strOf(w['status'], 'pending').toUpperCase(), style: TextStyle(color: kGold, fontSize: 11, fontWeight: FontWeight.bold))),
                      ]),
                    ),
                  ),
              ]);
            },
          ),
          const SizedBox(height: 20),
          _mockSectionLabel('Verified Payment Proofs (completed deposits)'),
          const SizedBox(height: 8),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: SupaDb.getList('deposits', eqCol: 'firebase_uid', eqVal: widget.uid, orderBy: 'created_at', ascending: false),
            builder: (context, snap) {
              final rows = (snap.data ?? []).where((d) => SupaDb.strOf(d['status']) == 'completed').toList();
              if (snap.connectionState == ConnectionState.waiting) return Center(child: CircularProgressIndicator(color: kGold));
              if (rows.isEmpty) return proEmpty('Abhi koi verified (completed) deposit nahi. API verified deposits yahan provider transaction ID ke saath dikhenge.');
              return Column(children: [
                for (final d in rows)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: MockupCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [Expanded(child: Text('${fmtRs(SupaDb.numOf(d['amount']))} • ${SupaDb.strOf(d['payment_method'])}', style: TextStyle(color: kText, fontWeight: FontWeight.bold))), Text('✓ VERIFIED', style: TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold))]),
                        Text('Provider TXN: ${SupaDb.strOf(d['provider_txn_id'], SupaDb.strOf(d['utr'], '—'))}  •  Order: ${SupaDb.strOf(d['order_id'], '—')}', style: TextStyle(color: kMuted, fontSize: 12)),
                      ]),
                    ),
                  ),
              ]);
            },
          ),
          const SizedBox(height: 20),
          _mockSectionLabel('Referral Leaderboard (by referral earnings)'),
          const SizedBox(height: 8),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: SupaDb.getList('profiles', orderBy: 'referral_earnings', ascending: false, limit: 20),
            builder: (context, snap) {
              final rows = snap.data ?? [];
              if (snap.connectionState == ConnectionState.waiting) return Center(child: CircularProgressIndicator(color: kGold));
              if (rows.isEmpty) return proEmpty('Abhi koi referral earnings nahi.');
              return Column(children: [
                for (var i = 0; i < rows.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: MockupCard(child: Row(children: [Text('#${i + 1}', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)), SizedBox(width: 10), Expanded(child: Text(SupaDb.strOf(rows[i]['display_name'], 'User'), style: TextStyle(color: kText, fontWeight: FontWeight.bold))), Text(fmtRs(SupaDb.numOf(rows[i]['referral_earnings'])), style: TextStyle(color: kGold, fontWeight: FontWeight.bold))])),
                  ),
              ]);
            },
          ),
        ],
      ),
    );
  }
}

/// ---------------- BOARD SCREENS (FINAL UI, 2026-10-27) ----------------
/// Board layout/colours/components replicated; NO PUBG branding, logo
/// or PUBG artwork — ARENA HUB name + generic placeholders only.

/// OTP Verification screen (board design: 6 code boxes, resend timer).
/// HONEST: SMS OTP needs a PAID SMS service, so no code is ever sent
/// or faked here. The screen shows the board design + a clear pending
/// banner and routes to the FREE auth paths (email / Google). The
/// Verify button never claims success without a real code.
class OtpVerificationPage extends StatefulWidget {
  const OtpVerificationPage({super.key});
  @override
  State<OtpVerificationPage> createState() => _OtpVerificationPageState();
}

class _OtpVerificationPageState extends State<OtpVerificationPage> {
  final _boxes = List.generate(6, (_) => TextEditingController());
  int _seconds = 30;

  @override
  void initState() {
    super.initState();
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return false;
      if (_seconds > 0) setState(() => _seconds--);
      return _seconds > 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('OTP Verification', style: TextStyle(color: kGold))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Enter Verification Code', style: TextStyle(color: kText, fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('6-digit code apne mobile par aayega.', style: TextStyle(color: kMuted)),
            const SizedBox(height: 16),
            MockupCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('SMS OTP PENDING', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
                  SizedBox(height: 4),
                  Text('SMS OTP ke liye paid SMS service chahiye, jo abhi configure nahi hai. Isliye koi code send nahi hoga aur Verify dabane se login nahi hoga. Free login ke liye Email ya Google use karen — wahi asal login hai.', style: TextStyle(color: kMuted, fontSize: 13)),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var i = 0; i < 6; i++)
                  SizedBox(
                    width: 44,
                    // FIX 23 item 29: card look via CardFieldShell.
                    child: CardFieldShell(
                      radius: 10,
                      child: TextField(
                      controller: _boxes[i],
                      keyboardType: TextInputType.number,
                      maxLength: 1,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: kText, fontSize: 20, fontWeight: FontWeight.bold),
                      decoration: InputDecoration(counterText: '', border: const OutlineInputBorder(borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(vertical: 10)),
                      onChanged: (v) {
                        if (v.isNotEmpty && i < 5) FocusScope.of(context).nextFocus();
                      },
                    ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            goldButton(
              label: 'Verify Code',
              onPressed: () => toast(context, 'SMS OTP abhi pending hai — koi code verify nahi hua. Email ya Google login use karen.'),
            ),
            const SizedBox(height: 12),
            Center(
              child: TextButton(
                onPressed: _seconds == 0
                    ? () {
                        setState(() => _seconds = 30);
                        toast(context, 'SMS service pending hai — resend se koi code nahi aayega. Email/Google login use karen.');
                      }
                    : null,
                child: Text(_seconds == 0 ? 'Resend Code' : 'Resend in $_seconds s', style: TextStyle(color: kGold)),
              ),
            ),
            SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(side: BorderSide(color: kGold)),
                child: Text('Back to Email / Google Login', style: TextStyle(color: kGold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Payment Success screen (board design). Shown ONLY after the API
/// verify flow returns 'completed' — never shown for pending/failed.
class PaymentSuccessPage extends StatelessWidget {
  final double amount;
  final String method;
  const PaymentSuccessPage({super.key, required this.amount, required this.method});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Payment Success', style: TextStyle(color: kGold))),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.green),
              child: const Icon(Icons.check, color: Colors.white, size: 56),
            ),
            const SizedBox(height: 24),
            Text('Payment Successful!', style: TextStyle(color: kText, fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('${fmtRs(amount)} via $method', style: TextStyle(color: kGold, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Amount aapke deposit balance me add ho gaya hai (API verified).', style: TextStyle(color: kMuted), textAlign: TextAlign.center),
            const SizedBox(height: 32),
            goldButton(label: 'Done — Back to Wallet', onPressed: () => Navigator.pop(context)),
          ],
        ),
      ),
    );
  }
}

/// Winner Celebration screen (board design): shows the user's latest
/// real 1st-place finish from match_history — never an invented win.
/// If there is no win yet, it says so plainly.
class WinnerCelebrationPage extends StatelessWidget {
  final String uid;
  const WinnerCelebrationPage({super.key, required this.uid});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Winner Celebration', style: TextStyle(color: kGold))),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: SupaDb.getMatchHistory(uid),
        builder: (context, snap) {
          final wins = (snap.data ?? []).where((h) => SupaDb.intOf(h['rank']) == 1).toList();
          if (snap.connectionState == ConnectionState.waiting) return Center(child: CircularProgressIndicator(color: kGold));
          if (wins.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('🏆', style: TextStyle(fontSize: 72)),
                  const SizedBox(height: 16),
                  Text('Abhi koi jeet nahi', style: TextStyle(color: kText, fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('Jab aap koi tournament jeetenge, yahan celebration dikhega — asli record se, fake nahi.', style: TextStyle(color: kMuted), textAlign: TextAlign.center),
                ],
              ),
            );
          }
          final w = wins.first;
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('🎉🏆🎉', style: TextStyle(fontSize: 56)),
                const SizedBox(height: 16),
                Text('CHAMPION!', style: TextStyle(color: kGold, fontSize: 32, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(SupaDb.strOf(w['tournamentName']), style: TextStyle(color: kText, fontSize: 20, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text('Kills: ${SupaDb.intOf(w['kills'])}  •  Winnings: ${fmtRs(SupaDb.numOf(w['winnings']))}', style: TextStyle(color: kMuted)),
                const SizedBox(height: 32),
                goldButton(
                  label: 'Share My Win',
                  onPressed: () => Share.share('🏆 I won ${SupaDb.strOf(w['tournamentName'])} on ARENA HUB! Kills: ${SupaDb.intOf(w['kills'])} — join and challenge me!', subject: 'My Tournament Win'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// FIX 11 (2026-11-21, Edit Profile photo — screenshot
/// 1000049134_49_1e31.jpg).
///
/// (b) Thrown when a profile-photo write does NOT land: the ImgBB
/// upload succeeded and updateProfile returned without error, but
/// the read-back shows a different (or empty) photo_url — a 0-row
/// update or a silently dropped write. The caller toasts the honest
/// "uploaded but not saved" message; the old photo stays. This is a
/// distinct type (not a bare Exception) so the UI can tell "saved
/// nowhere" apart from "upload failed" without string-matching.
class PhotoSaveMismatchException implements Exception {
  const PhotoSaveMismatchException([this.message = 'Photo uploaded but the profile did not save it.']);
  final String message;
  @override
  String toString() => 'PhotoSaveMismatchException: $message';
}

/// FIX 11 (b) — save an uploaded profile-photo URL to the server
/// IMMEDIATELY, the moment the upload finishes. Same verified-write
/// pattern as ProfilePage._changePhoto (more_screens.dart):
/// updateProfile -> read-back verify -> PhotoCache.invalidate +
/// refresh-notifier bump so the new photo shows everywhere at once.
///
/// ROOT CAUSE it closes: Edit Profile's _pickPhoto used to only
/// `setState(() => _photoUrl = url)` — the URL lived ONLY in
/// page-local state until SAVE CHANGES. Upload-and-leave (or an
/// uninstall before saving) lost the photo even though the preview
/// had shown it, so it LOOKED saved. The preview must never show a
/// photo the server does not have: callers set their local URL only
/// AFTER this returns.
///
/// [update]/[readBack] are injectable so tests can prove the save
/// path with doubles instead of the live server; production passes
/// the SupaDb tear-offs. Throws [PhotoSaveMismatchException] on a
/// read-back mismatch, [ArgumentError] on an empty URL, and lets
/// update/read-back failures propagate (the caller toasts honestly
/// and keeps the old photo).
Future<void> saveProfilePhotoNow({
  required String uid,
  required String url,
  required Future<void> Function(String uid, Map<String, dynamic> patch) update,
  required Future<Map<String, dynamic>> Function(String uid) readBack,
}) async {
  if (url.isEmpty) throw ArgumentError('saveProfilePhotoNow: refusing to save an empty photo URL.');
  await update(uid, {'photo_url': url});
  // VERIFY the write landed before claiming success: read the row
  // back and compare. A 0-row update (or any write the server
  // silently drops) must NOT look like a saved photo.
  final fresh = await readBack(uid);
  if (SupaDb.strOf(fresh['photo_url']) != url) {
    throw const PhotoSaveMismatchException();
  }
  // Drop the cached photo + bump the refresh notifier so seats,
  // strips, chat and the Home header pick up the new photo on
  // their next build instead of the old one.
  PhotoCache.invalidate(uid);
  SupaDb.bumpRefresh();
}

/// FIX 11 (c) — the initial letter for the Edit Profile avatar
/// fallback. Trimmed first: a leading space in the display name
/// used to make the "letter" a blank space, i.e. an invisible
/// fallback on a dark circle. Falls back to the username initial,
/// then '?', so the circle is never blank.
String editProfileInitial({required String displayName, required String username}) {
  final name = displayName.trim();
  if (name.isNotEmpty) return name[0].toUpperCase();
  final user = username.trim();
  if (user.isNotEmpty) return user[0].toUpperCase();
  return '?';
}

/// Create Profile screen (#15 — Phase 2): display name only, saved
/// to the real profile row via SupaDb.updateProfile; photo goes
/// through the ImgBB path (Frames Shop → Profile Photo).
///
/// FIX 10 (2026-11-21): the GAME UID field IS here and DOES save —
/// to profiles.game_uid, via editProfilePatch (full patch + minimal
/// retry both carry it). The old Phase-2 note below it ("field was
/// REMOVED ... must never be written to profiles") is stale: a
/// read-only REST probe on 2026-11-21 confirmed profiles.game_uid
/// EXISTS live (along with username / country / favorite_game /
/// bio / in_game_name), and the roster + squad-leader prefill both
/// read it back. The stale supabase_db.dart:939 comment ("profiles
/// has NO username/game_uid columns") is reported to the
/// coordinator for correction — this file does not own that file.
class CreateProfilePage extends StatefulWidget {
  final String uid;
  const CreateProfilePage({super.key, required this.uid});
  @override
  State<CreateProfilePage> createState() => _CreateProfilePageState();
}

class _CreateProfilePageState extends State<CreateProfilePage> {
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _ign = TextEditingController();
  final _playerId = TextEditingController();
  final _bio = TextEditingController();
  String? _country;
  String? _game;
  String? _photoUrl;
  String _originalUsername = '';
  // Username availability: '', 'checking', 'available', 'taken'.
  String _usernameState = '';
  Timer? _usernameTimer;
  // No in-game-name column exists in 001 or in draft 017 — the field
  // is shown (mockup #15) but cannot be saved until a column exists.
  bool _hasIgnColumn = false;
  bool _hadProfile = false;
  bool _loading = true;
  bool _busy = false;
  bool _uploadingPhoto = false;

  static const _countries = ['Pakistan', 'United States', 'United Kingdom', 'India', 'Bangladesh', 'Canada', 'Australia', 'UAE', 'Other'];
  static const _games = ['PUBG Mobile', 'BGMI', 'Free Fire', 'Call of Duty Mobile', 'Fortnite', 'Valorant', 'Other'];

  @override
  void initState() {
    super.initState();
    _username.addListener(_onUsernameChanged);
    _load();
  }

  @override
  void dispose() {
    _usernameTimer?.cancel();
    _name.dispose();
    _username.dispose();
    _ign.dispose();
    _playerId.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await SupaDb.getProfile(widget.uid);
    if (!mounted) return;
    setState(() {
      _name.text = SupaDb.strOf(p['displayName']);
      _username.text = SupaDb.strOf(p['username']);
      _originalUsername = _username.text;
      _ign.text = SupaDb.strOf(p['in_game_name']);
      _hasIgnColumn = p.containsKey('in_game_name');
      _playerId.text = SupaDb.strOf(p['game_uid']);
      final country = SupaDb.strOf(p['country']);
      _country = country.isEmpty ? null : country;
      final game = SupaDb.strOf(p['favorite_game']);
      _game = game.isEmpty ? null : game;
      _bio.text = SupaDb.strOf(p['bio']);
      final photo = SupaDb.strOf(p['photo_url']);
      _photoUrl = photo.isEmpty ? null : photo;
      _hadProfile = _name.text.isNotEmpty;
      _loading = false;
    });
  }

  /// Mockup #15 username availability check (green ✓ Available).
  /// Debounced live lookup; the user's own current username is never
  /// reported as taken. Case-insensitive (2026-11-20 fix — the old
  /// exact-match check let "Ali" and "ali" both register).
  void _onUsernameChanged() {
    final v = _username.text.trim();
    _usernameTimer?.cancel();
    if (v.isEmpty || v == _originalUsername) {
      if (_usernameState != '') setState(() => _usernameState = '');
      return;
    }
    setState(() => _usernameState = 'checking');
    _usernameTimer = Timer(const Duration(milliseconds: 500), () async {
      try {
        final available = await CommunityService.isUsernameAvailable(v, excludeUid: widget.uid);
        if (mounted && _username.text.trim() == v) {
          setState(() => _usernameState = available ? 'available' : 'taken');
        }
      } catch (_) {
        if (mounted) setState(() => _usernameState = '');
      }
    });
  }

  /// Mockup #15 photo change: ImgBB upload, saved to the server
  /// IMMEDIATELY (FIX 11 (b)) — the URL used to live only in
  /// page-local state until SAVE CHANGES, so upload-and-leave lost
  /// the photo even though the preview had shown it. The local
  /// preview is set only AFTER the verified server save, so the
  /// preview can never show a photo the server does not have.
  /// Compresses at pick time (85% / 1024 px, like the ProfilePage
  /// avatar flow) — a full-res photo can never finish on a slow
  /// connection before the upload timeout. While uploading the
  /// button shows a spinner and re-taps are disabled; on failure
  /// the old photo stays and the toast says what really happened.
  Future<void> _pickPhoto() async {
    if (_uploadingPhoto) return;
    final res = await _pickEvidenceImage(imageQuality: 85, maxWidth: 1024);
    if (res.error != null) {
      if (mounted) toast(context, res.error!);
      return;
    }
    if (res.file == null) return;
    setState(() => _uploadingPhoto = true);
    try {
      final url = await ImgbbService.uploadImage(res.file!);
      // FIX 11 (b): verified server save NOW — no longer depends
      // on SAVE CHANGES (which still re-saves photo_url via
      // editProfilePatch, harmlessly, for the other fields).
      await saveProfilePhotoNow(
        uid: widget.uid,
        url: url,
        update: SupaDb.updateProfile,
        readBack: SupaDb.getProfile,
      );
      if (!mounted) return;
      setState(() => _photoUrl = url);
      toast(context, tr('Profile photo updated.', 'Profile photo update ho gayi.'));
    } on PhotoSaveMismatchException {
      // Upload worked, server save did not land: say exactly that
      // — never "updated", never the raw exception.
      if (mounted) {
        toast(context, tr('Photo uploaded but could not be saved to your profile — please try again.', 'Photo upload ho gaya lekin profile par save nahi hua — dobara try karein.'));
      }
    } on TimeoutException {
      if (mounted) toast(context, 'Net slow hai — photo upload time out ho gaya. Dobara try karen.');
    } catch (_) {
      if (mounted) toast(context, 'Photo upload nahi ho saki — dobara koshish karein.');
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      toast(context, 'Name zaroori hai.');
      return;
    }
    if (_usernameState == 'taken') {
      toast(context, 'Yeh username taken hai — koi aur chunen.');
      return;
    }
    // Game UID validation (audit fix 2026-11-21): a PUBG game UID is
    // digits only — the field already uses a numeric keyboard, so
    // anything else is a typo that must not be saved.
    final gameUid = _playerId.text.trim();
    if (gameUid.isNotEmpty &&
        (gameUid.length < 5 || gameUid.length > 20 || !RegExp(r'^[0-9]+$').hasMatch(gameUid))) {
      toast(context, 'Game UID sirf number hoti hai (5-20 digits) — dobara check karke likhein.');
      return;
    }
    setState(() => _busy = true);
    // READ-BACK VERIFY (audit fix 2026-11-21, same pattern as the
    // photo save): updateProfile does not confirm a row matched, so
    // re-read the profile and compare — a 0-row update must never
    // toast success. The 'game_uid' wording in the throw routes the
    // failure to the friendly game-UID toast in the catch below.
    Future<void> verifySaved() async {
      final fresh = await SupaDb.getProfile(widget.uid);
      if (SupaDb.strOf(fresh['displayName']) != _name.text.trim()) {
        throw Exception('profile verify failed');
      }
      if (_playerId.text.trim().isNotEmpty &&
          SupaDb.strOf(fresh['gameUid']) != _playerId.text.trim()) {
        throw Exception('game_uid verify failed');
      }
    }

    try {
      // FIX 10: the patch builder (editProfilePatch) carries
      // game_uid in BOTH the full patch and the minimal retry —
      // a failed full update must never silently drop it.
      final full = editProfilePatch(
        displayName: _name.text,
        username: _username.text,
        playerId: _playerId.text,
        photoUrl: _photoUrl,
        country: _country,
        game: _game,
        bio: _bio.text,
        ign: _ign.text,
        hasIgnColumn: _hasIgnColumn,
      );
      // The country / favorite_game / bio columns were once draft
      // 017 (not applied), so a failed full update retries with
      // only the live columns and says exactly what was skipped.
      // REST probe 2026-11-21 confirmed all of them live, so the
      // retry is now just a safety net — kept, not removed.
      try {
        await SupaDb.updateProfile(widget.uid, full);
        await verifySaved();
      } catch (_) {
        final minimal = editProfilePatch(
          displayName: _name.text,
          username: _username.text,
          playerId: _playerId.text,
          photoUrl: _photoUrl,
          ign: _ign.text,
          hasIgnColumn: _hasIgnColumn,
          minimal: true,
        );
        await SupaDb.updateProfile(widget.uid, minimal);
        await verifySaved();
        if (mounted) {
          toast(context, 'Profile save ho gaya — country / favourite game / bio abhi save nahi ho sake (backend update pending).');
          Navigator.pop(context);
        }
        return;
      }
      if (mounted) {
        if (_ign.text.trim().isNotEmpty && !_hasIgnColumn) {
          toast(context, 'Profile save ho gaya — in-game name ke liye backend column abhi nahi hai.');
        } else {
          toast(context, 'Profile save ho gaya!');
        }
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        // Never show the raw exception. A username unique-violation
        // (035 lower(username) index) gets the friendly taken
        // message; anything else gets a plain retry message.
        final msg = e.toString().toLowerCase();
        if (msg.contains('username') &&
            (msg.contains('unique') ||
                msg.contains('duplicate') ||
                msg.contains('23505'))) {
          toast(context, 'Yeh username taken hai — koi aur chunen.');
        } else if (msg.contains('game_uid')) {
          // FIX 10: a game_uid failure must say so — the user typed
          // a Game UID that did not save, and must not walk away
          // thinking it did. (updateProfile rethrows, so a failure
          // can never be silently swallowed here.)
          toast(context, 'Game UID save nahi ho saka — backend issue hai, dobara koshish karein.');
        } else {
          toast(context, 'Save nahi ho saka — dobara koshish karein.');
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _usernameSuffix() {
    switch (_usernameState) {
      case 'checking':
        // NOT const: kGold is a runtime getter, not a const value.
        return Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: kGold)),
        );
      case 'available':
        // S12 redesign: success green token (was a hardcoded green).
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check, color: kGreen, size: 18),
            SizedBox(width: 4),
            Text('Available', style: TextStyle(color: kGreen, fontSize: 12, fontWeight: FontWeight.bold)),
          ],
        );
      case 'taken':
        // S12 redesign: error token (was a hardcoded red accent).
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.close, color: kError, size: 18),
            SizedBox(width: 4),
            Text('Taken', style: TextStyle(color: kError, fontSize: 12, fontWeight: FontWeight.bold)),
          ],
        );
      default:
        return const SizedBox();
    }
  }

  /// Mockup #15 local helpers (J-gap-fix1). The shared _mockLabel /
  /// _mockField / _mockDropdown / _goldOutlineBtn are used by other
  /// screens with different styling, so #15 gets local copies here:
  /// field labels MUTED GREY 12 px (not white bold 13), dropdowns
  /// with the SAME grey border as the text fields (not gold 1.5 px),
  /// CANCEL as a dark pill with a grey border + grey text (not gold
  /// outline radius 12), title white italic w900 22 px.

  Widget _epLabel(String label) => Text(
        label,
        style: kStyleLabel.copyWith(letterSpacing: 0.5),
      );

  Widget _epTitle(String title) => Text(
        title,
        style: TextStyle(color: kText, fontStyle: FontStyle.italic, fontWeight: FontWeight.w900, fontSize: 22, letterSpacing: 0.5),
      );

  /// S12 redesign: the field itself is the shared [ArenaTextField]
  /// (dark fill, subtle border, yellow focus border, red error
  /// border, radius kRadiusInput); the label stays above the field
  /// exactly as before, so the layout is unchanged.
  Widget _epField({
    required TextEditingController controller,
    required String label,
    String? hint,
    int maxLines = 1,
    TextInputType? keyboardType,
    Widget? suffix,
    ValueChanged<String>? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _epLabel(label),
        const SizedBox(height: 6),
        ArenaTextField(
          controller: controller,
          hintText: hint,
          maxLines: maxLines,
          keyboardType: keyboardType,
          suffixIcon: suffix,
          onChanged: onChanged,
        ),
        const SizedBox(height: kSpace12),
      ],
    );
  }

  /// S12 redesign: dropdowns share the text fields' metrics — the
  /// same padding as the real [ArenaTextField]'s contentPadding
  /// (16 horizontal / 14 vertical, F2) and the same radius
  /// (kRadiusInput), so the rendered heights match instead of the
  /// old fixed 37 px box. Menu opens on the elevated surface token.
  Widget _epDropdown({
    required String label,
    required String? value,
    required List<String> options,
    required ValueChanged<String?> onChanged,
    String? hint,
  }) {
    final safeValue = value != null && options.contains(value) ? value : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _epLabel(label),
        const SizedBox(height: 6),
        Container(
          // Vertical 13 (not the field's 14): the dense button is
          // 24 px, so 13+13+24 = 50 px — within 1 px of the 51 px
          // text fields. (With 14 the dropdown lands 3 px taller:
          // the button's 1 px borders add 2 px to the measured box.)
          padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 16),
          decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(kRadiusInput), border: Border.all(color: kBorder)),
          child: DropdownButton<String>(
            value: safeValue,
            isExpanded: true,
            // isDense: the button's default itemHeight (48 px) made
            // the dropdown 78 px tall vs the 51 px text fields. The
            // dense button is 24 px (text/icon height), so the field
            // matches the text fields; the MENU items stay 48 px
            // touch targets (menu uses itemHeight, not the button).
            isDense: true,
            hint: Text(hint ?? 'Select', style: TextStyle(color: kTextMuted, fontSize: 15)),
            dropdownColor: kSurfaceElevated,
            underline: const SizedBox(),
            icon: Icon(Icons.keyboard_arrow_down, color: kTextMuted, size: 20),
            style: kStyleBody,
            items: options.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
            onChanged: onChanged,
          ),
        ),
        const SizedBox(height: kSpace12),
      ],
    );
  }

  /// Mockup #15 avatar: 124 px, THICK gold ring (~4–5 px) with the
  /// soft gold halo the mockup shows (glow directive: avatar ring
  /// glow IS in the mockup) + gold camera badge bottom-right.
  Widget _avatar() {
    final url = _photoUrl;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 124,
          height: 124,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: kGold, width: 4),
            boxShadow: [
              BoxShadow(color: kGold.withValues(alpha: 0.45), blurRadius: 18, spreadRadius: 2),
              BoxShadow(color: kGold.withValues(alpha: 0.18), blurRadius: 36, spreadRadius: 6),
            ],
          ),
          // WAVE 4 FIX 5 (B): disk-cached avatar (was bare
          // NetworkImage). Empty URL -> initial letter, dead URL ->
          // initial letter (was a blank circle).
          // FIX 11 (c): the initial comes from editProfileInitial
          // (trimmed name, username fallback, never a blank space),
          // and the letter colour is readable in BOTH modes — gold
          // on the dark circle, black on the light-mode circle
          // (gold on light grey was near-invisible).
          child: ArenaCachedAvatar(
            photoUrl: url ?? '',
            radius: 60,
            backgroundColor: kField,
            fallback: Text(
              editProfileInitial(displayName: _name.text, username: _username.text),
              style: TextStyle(color: appLightMode ? Colors.black : kGold, fontSize: 44, fontWeight: FontWeight.bold),
            ),
          ),
        ),
        // FIX 11 (a): the old 40x40 badge at right:0/bottom:0 sat
        // with its centre just inside the ring, so half of it hung
        // off the circle edge overlapping the gold ring — and on
        // the phone it rendered half-cut. 36x36 at right:0/bottom:0
        // puts the badge centre ON the ring (62 px from the avatar
        // centre, the ring's own radius), fully inside the 124px
        // avatar box, with the 20px camera icon centred inside it
        // (8px breathing room each side) and clear of the initial
        // letter. The dark border + soft shadow keep the gold badge
        // readable against both the photo and the ring.
        Positioned(
          right: 0,
          bottom: 0,
          child: InkWell(
            onTap: _uploadingPhoto ? null : _pickPhoto,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: kGold,
                shape: BoxShape.circle,
                border: Border.all(color: kBg, width: 2),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 6, offset: const Offset(0, 2))],
              ),
              child: _uploadingPhoto
                  ? const Padding(padding: EdgeInsets.all(9), child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                  : const Icon(Icons.camera_alt, color: Colors.black, size: 20),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Mockup #15 header: back chevron GOLD, plain (no box), title
      // EDIT PROFILE white italic w900 22 px, centred.
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.chevron_left, color: kGold, size: 28),
          onPressed: () => Navigator.pop(context),
        ),
        title: _epTitle(_hadProfile ? 'EDIT PROFILE' : 'CREATE PROFILE'),
        centerTitle: true,
      ),
      body: _loading
          ? ListView(
              // Mockup #15 form inset: fields sit ~9% in from each
              // screen edge (measured 70/768 px) — 32 dp on 360 dp.
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              children: const [
                Center(child: LoadingSkeleton(height: 124)),
                SizedBox(height: 16),
                LoadingSkeleton(height: 56),
                SizedBox(height: 10),
                LoadingSkeleton(height: 56),
                SizedBox(height: 10),
                LoadingSkeleton(height: 96),
              ],
            )
          : Stack(
              children: [
                // Mockup #15 background: near-black with sparse gold
                // sparkle dots, denser around the avatar (shared
                // ArenaEmberDots, behind content, taps pass through).
                const Positioned.fill(child: IgnorePointer(child: ArenaEmberDots())),
                SingleChildScrollView(
                  // Mockup #15 form inset (see loading branch above).
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(child: _avatar()),
                      const SizedBox(height: kSpace8),
                      Center(
                        child: TextButton(
                          onPressed: _uploadingPhoto ? null : _pickPhoto,
                          child: Text('CHANGE PHOTO', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 0.6)),
                        ),
                      ),
                      const SizedBox(height: kSpace12),
                      _epField(controller: _name, label: 'DISPLAY NAME'),
                      _epField(controller: _username, label: 'USERNAME', hint: 'Choose a username', suffix: _usernameSuffix()),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _epField(controller: _ign, label: 'IN-GAME NAME', hint: 'Your in-game name')),
                          const SizedBox(width: 10),
                          // FIX 10: clearly labelled GAME UID — the
                          // player must know this is the ID the team
                          // roster shows (was the vague 'IN-GAME
                          // PLAYER ID' / 'Your player ID').
                          Expanded(child: _epField(controller: _playerId, label: 'GAME UID', hint: 'Your in-game UID', keyboardType: TextInputType.number)),
                        ],
                      ),
                      // FIX 10: one line so the player understands
                      // where this ID appears (team roster + squad
                      // leader prefill read profiles.game_uid).
                      Padding(
                        padding: const EdgeInsets.only(bottom: kSpace12),
                        child: Text(
                          tr('Your Game UID shows on the team roster — enter your in-game ID here.', 'Game UID team roster par dikhta hai — apni game ki ID yahan likhen.'),
                          style: TextStyle(color: kMuted, fontSize: 11),
                        ),
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _epDropdown(
                              label: 'COUNTRY/REGION',
                              value: _country,
                              hint: 'Select country',
                              options: _countries,
                              onChanged: (v) => setState(() => _country = v),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _epDropdown(
                              label: 'FAVORITE GAME',
                              value: _game,
                              hint: 'Select game',
                              options: _games,
                              onChanged: (v) => setState(() => _game = v),
                            ),
                          ),
                        ],
                      ),
                      _epField(controller: _bio, label: 'BIO', hint: 'Tell us about yourself...', maxLines: 4),
                      // S12 redesign: SAVE CHANGES is the shared
                      // primary button (gold gradient, dark text).
                      // Behaviour is unchanged: disabled + spinner
                      // while busy, _save on tap.
                      SizedBox(
                        width: double.infinity,
                        child: ArenaPrimaryButton(
                          onPressed: _busy ? null : _save,
                          child: _busy
                              ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0A0A0F)))
                              : const Text('SAVE CHANGES', style: TextStyle(color: Color(0xFF0A0A0F), fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: 0.5)),
                        ),
                      ),
                      const SizedBox(height: 10),
                      // S12 redesign: CANCEL is the shared secondary
                      // button (dark surface, thin grey border,
                      // white text). Behaviour unchanged: pops.
                      SizedBox(
                        width: double.infinity,
                        child: ArenaSecondaryButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text('CANCEL', style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 0.5)),
                        ),
                      ),
                      // NOTE (J-gap-fix1): the two honesty lines that
                      // sat under the buttons are removed to match
                      // the mockup. Honesty is kept in the save path
                      // itself — _save() toasts exactly what could
                      // not be saved (in-game name column /
                      // country-game-bio draft columns).
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

/// ---------------- REMAINING-ITEMS: fans, match summary, live support, certificate ----------------

class FanListPage extends StatelessWidget {
  final String uid;
  // FIX 22 item 15: the sidebar Followers entry opens this page
  // titled 'Followers'; the default keeps the old title.
  final String title;
  const FanListPage(
      {super.key, required this.uid, this.title = 'My Fans (Followers)'});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title, style: TextStyle(color: kGold))),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: SupaDb.getList('follows', eqCol: 'following_uid', eqVal: uid, orderBy: 'created_at', ascending: false),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) return Center(child: CircularProgressIndicator(color: kGold));
          final rows = snap.data ?? [];
          if (rows.isEmpty) return proEmpty('Abhi koi follower nahi. Jab koi player aapko Follow karega, yahan dikhega (asli follows table se).');
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: rows.length,
            itemBuilder: (context, i) {
              final f = rows[i];
              final fid = SupaDb.strOf(f['follower_uid']);
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: MockupCard(
                  child: FutureBuilder<Map<String, dynamic>>(
                    future: SupaDb.getProfile(fid),
                    builder: (context, pSnap) {
                      // FIX 10 (2026-11-21): a fan with no display
                      // name shows 'Player' — NEVER the Firebase UID
                      // (the old fallback printed the raw UID).
                      final name = SupaDb.strOf((pSnap.data ?? {})['displayName'], 'Player');
                      return Row(children: [Icon(Icons.person, color: kGold), const SizedBox(width: 10), Expanded(child: Text(name, style: TextStyle(color: kText, fontWeight: FontWeight.bold))) ]);
                    },
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class MatchSummaryHubPage extends StatelessWidget {
  final String uid;
  const MatchSummaryHubPage({super.key, required this.uid});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Match Summary', style: TextStyle(color: kGold))),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: SupaDb.getList('tournaments', orderBy: 'start_time', ascending: false, limit: 30),
        builder: (context, snap) {
          final ts = snap.data ?? [];
          if (snap.connectionState == ConnectionState.waiting) return Center(child: CircularProgressIndicator(color: kGold));
          if (ts.isEmpty) return proEmpty('Abhi koi tournament nahi.');
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: ts.length,
            itemBuilder: (context, i) {
              final t = ts[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: MockupCard(
                  child: Row(children: [
                    Expanded(child: Text(SupaDb.strOf(t['name']), style: TextStyle(color: kText, fontWeight: FontWeight.bold))),
                    TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MatchSummaryPage(tournament: t))), child: Text('Summary', style: TextStyle(color: kGold))),
                  ]),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// CANONICAL PAGE (2026-11-21, #16 dedup): MatchSummaryPage was a
// second mockup-#16 screen that drifted from MatchResultDetailsPage
// (its own victory card, perf tiles, timeline, buttons — including
// a hard-coded 'TOTAL POINTS: 0'). There is ONE canonical page now:
// MatchResultDetailsPage (more_screens.dart). This class is kept
// ONLY as a redirect shell so its two call sites keep compiling
// unchanged (MatchSummaryHubPage 'Summary' button + home_screens
// 'VIEW MATCH SUMMARY'): it loads the viewer's own match_history
// row for the tournament and replaces itself with the canonical
// page. When the viewer has no result in this tournament (never
// played it), it says so honestly instead of inventing a summary —
// the tournament-wide standings live on the Leaderboard.
class MatchSummaryPage extends StatefulWidget {
  final Map<String, dynamic> tournament;
  final String? uid;
  const MatchSummaryPage({super.key, required this.tournament, this.uid});
  @override
  State<MatchSummaryPage> createState() => _MatchSummaryPageState();
}

class _MatchSummaryPageState extends State<MatchSummaryPage> {
  bool _loading = true;
  bool _noResult = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final uid = widget.uid ?? _uid();
    final tid = SupaDb.strOf(widget.tournament['id']);
    if (uid.isEmpty || tid.isEmpty) {
      if (mounted) setState(() {_loading = false; _noResult = true;});
      return;
    }
    try {
      final rows = await SupaDb.getMatchHistory(uid);
      final mine = rows.where((r) => SupaDb.strOf(r['tournament_id']) == tid).toList();
      if (!mounted) return;
      if (mine.isEmpty) {
        setState(() {_loading = false; _noResult = true;});
        return;
      }
      // Redirect (replace): the canonical page owns the back stack.
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => MatchResultDetailsPage(history: mine.first, uid: uid)),
      );
    } catch (e) {
      if (mounted) setState(() {_loading = false; _error = '$e';});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MATCH RESULT DETAILS')),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFFDC903)))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, color: Color(0xFFFDC903), size: 40),
                        const SizedBox(height: 12),
                        Text('Summary load nahi ho saki: $_error', style: TextStyle(color: kText), textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        OutlinedButton(onPressed: () => Navigator.maybePop(context), child: const Text('Back')),
                      ],
                    ),
                  ),
                )
              : _noResult
                  ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.summarize_outlined, color: Color(0xFFFDC903), size: 40),
                        const SizedBox(height: 12),
                        Text('No match result yet', style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 17)),
                        const SizedBox(height: 6),
                        Text(
                          'Is tournament me aapka koi result nahi — summary tab banega jab aap khelein ge aur admin result verify karega.',
                          style: TextStyle(color: kMuted, fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton(onPressed: () => Navigator.maybePop(context), child: const Text('Back')),
                      ],
                    ),
                  ),
                )
                  : const SizedBox.shrink(),
    );
  }
}

class LiveSupportPage extends StatefulWidget {
  final String uid;
  const LiveSupportPage({super.key, required this.uid});
  @override
  State<LiveSupportPage> createState() => _LiveSupportPageState();
}

class _LiveSupportPageState extends State<LiveSupportPage> {
  final _msg = TextEditingController();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Live Support Chat', style: TextStyle(color: kGold))),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: SupaDb.client.from('live_support_messages').stream(primaryKey: ['id']).order('created_at').map((rows) => (rows as List).map((r) => Map<String, dynamic>.from(r as Map)).where((m) => SupaDb.strOf(m['firebase_uid']) == widget.uid).toList()),
              builder: (context, snap) {
                final msgs = snap.data ?? [];
                if (msgs.isEmpty) return Center(child: Text('Live support se baat karen — message bhejen, admin jawab dega (realtime).', style: TextStyle(color: kMuted), textAlign: TextAlign.center));
                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) {
                    final m = msgs[i];
                    final mine = SupaDb.strOf(m['firebase_uid']) == widget.uid && m['is_admin'] != true;
                    return Align(
                      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(color: mine ? kGold : kCard, borderRadius: BorderRadius.circular(12)),
                        child: Text(SupaDb.strOf(m['message']), style: TextStyle(color: mine ? Colors.black : kText)),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(child: CardFieldShell(radius: 24, child: TextField(controller: _msg, style: TextStyle(color: kText), decoration: InputDecoration(hintText: 'Support ko message...', hintStyle: TextStyle(color: kMuted), border: const OutlineInputBorder(borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12))))),
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(Icons.send, color: kGold),
                onPressed: () async {
                  final text = _msg.text.trim();
                  if (text.isEmpty) return;
                  // Batch 3B S18: a denied insert used to fail
                  // silently AND leave the text in the field. The
                  // field is cleared only after the insert lands;
                  // any failure gets an honest toast instead.
                  try {
                    final profile = await SupaDb.getProfile(widget.uid);
                    await SupaDb.client.from('live_support_messages').insert({'firebase_uid': widget.uid, 'display_name': SupaDb.strOf(profile['displayName'], 'User'), 'message': text, 'is_admin': false});
                    _msg.clear();
                  } catch (e) {
                    if (!mounted) return;
                    toast(context, 'Message nahi bheja ja saka — dobara koshish karein.');
                  }
                },
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class CertificatePage extends StatelessWidget {
  final String uid;
  const CertificatePage({super.key, required this.uid});

  Future<void> _generate(BuildContext context, Map<String, dynamic> win, String playerName) async {
    final doc = pw.Document();
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (pw.Context ctx) => pw.Center(
        child: pw.Column(
          mainAxisAlignment: pw.MainAxisAlignment.center,
          children: [
            pw.Text('CERTIFICATE OF CHAMPION', style: pw.TextStyle(fontSize: 28, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 24),
            pw.Text('ARENA HUB', style: pw.TextStyle(fontSize: 18)),
            pw.SizedBox(height: 24),
            pw.Text('This certifies that', style: pw.TextStyle(fontSize: 14)),
            pw.SizedBox(height: 8),
            pw.Text(playerName, style: pw.TextStyle(fontSize: 26, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 8),
            pw.Text('won the tournament', style: pw.TextStyle(fontSize: 14)),
            pw.SizedBox(height: 8),
            pw.Text(SupaDb.strOf(win['tournamentName']), style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 16),
            pw.Text('Kills: ${SupaDb.intOf(win['kills'])}  •  Damage: ${SupaDb.intOf(win['damage'])}  •  Headshots: ${SupaDb.intOf(win['headshot'])}  •  Winnings: Rs ${SupaDb.numOf(win['winnings']).toStringAsFixed(0)}', style: pw.TextStyle(fontSize: 13)),
            pw.SizedBox(height: 32),
            pw.Text('Verified from real match records — ARENA HUB', style: pw.TextStyle(fontSize: 11)),
          ],
        ),
      ),
    ));
    final bytes = await doc.save();
    await Share.shareXFiles([XFile.fromData(bytes, name: 'arena-hub-certificate.pdf', mimeType: 'application/pdf')], text: 'My ARENA HUB Champion Certificate');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Win Certificate (PDF)', style: TextStyle(color: kGold))),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: SupaDb.getMatchHistory(uid),
        builder: (context, snap) {
          final wins = (snap.data ?? []).where((h) => SupaDb.intOf(h['rank']) == 1).toList();
          if (snap.connectionState == ConnectionState.waiting) return Center(child: CircularProgressIndicator(color: kGold));
          if (wins.isEmpty) return proEmpty('Abhi koi jeet nahi — certificate sirf asli rank-1 win par banega, fake nahi.');
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: wins.length,
            itemBuilder: (context, i) {
              final w = wins[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: MockupCard(
                  child: Row(children: [
                    Expanded(child: Text(SupaDb.strOf(w['tournamentName']), style: TextStyle(color: kText, fontWeight: FontWeight.bold))),
                    TextButton(
                      onPressed: () async {
                        final profile = await SupaDb.getProfile(uid);
                        await _generate(context, w, SupaDb.strOf(profile['displayName'], 'Player'));
                      },
                      child: Text('PDF Banayen', style: TextStyle(color: kGold)),
                    ),
                  ]),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
