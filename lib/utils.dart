import 'package:flutter/material.dart';

import 'components/arena_components.dart';
import 'theme.dart';

export 'theme.dart';

/// ARENA HUB GOLD DESIGN SYSTEM (Phase 1 — 2026-11-19). Tokens live
/// in theme.dart (single source of truth); this file keeps the shared
/// helpers. The neon system (2026-11-01) is retired: no purple/pink
/// tokens remain in the user app outside the live voice room, which
/// keeps its own local neon constants in room_screen.dart.
/// LEGAL: only colours/layout are used — NO PUBG branding, logo, or
/// PUBG game photos/artwork anywhere; the app is ARENA HUB with its
/// own name and generic placeholders.

/// FIX ROUND 2026-10-28: the ONE wallet-total formula, shared by the
/// HomeShell header pill (main.dart) and WalletPage, so the two can
/// never disagree for the same profile: deposit + winning + bonus.
/// (A profile that has not loaded yet is EMPTY, not Rs 0 — callers
/// must show a loading/retry state for an empty profile, never 0.00.)
double walletTotal(Map<String, dynamic> p) =>
    numVal(p['depositBalance']) + numVal(p['winningCash']) + numVal(p['bonusCash']);

/// FIX ROUND 2026-10-28: AppBar titles that never clip mid-word with
/// a stray dot ("Pro Tourname..."): FittedBox scaleDown shrinks the
/// whole title to fit instead of truncating it.
Widget boardAppBarTitle(String title) => FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(title, style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
    );

double numVal(dynamic v, [double fallback = 0]) {
  if (v == null) return fallback;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString()) ?? fallback;
}

int intVal(dynamic v, [int fallback = 0]) => numVal(v, fallback.toDouble()).round();

String strVal(dynamic v, [String fallback = '']) {
  if (v == null) return fallback;
  final s = v.toString();
  return s.isEmpty ? fallback : s;
}

Map<String, dynamic> asMap(dynamic v) {
  if (v is Map) return Map<String, dynamic>.from(v);
  return {};
}

String fmtRs(double v) => 'Rs ${v.toStringAsFixed(2)}';

int parseTsMs(dynamic ts) {
  if (ts == null) return 0;
  if (ts is num) {
    final d = ts.toDouble();
    if (d == 0) return 0;
    return d.abs() < 100000000000 ? (d * 1000).round() : d.round();
  }
  final s = ts.toString().trim();
  if (s.isEmpty) return 0;
  final asNum = double.tryParse(s);
  if (asNum != null) return parseTsMs(asNum);
  try {
    return DateTime.parse(s).millisecondsSinceEpoch;
  } catch (_) {
    return 0;
  }
}

/// Countdown label for a tournament start time (ms): TBA when unset,
/// "Starting Soon" within 1 hour, "LIVE" when ongoing/started, "ENDED"
/// when past, else "Xd Xh Xm".
String countdownText(dynamic startTs, String status) {
  final ms = parseTsMs(startTs);
  final st = status.toLowerCase();
  if (st == 'completed' || st == 'result' || st == 'cancelled') return 'ENDED';
  if (ms <= 0) return 'TBA';
  final now = DateTime.now().millisecondsSinceEpoch;
  final diff = ms - now;
  if (st == 'ongoing') return 'LIVE';
  // A past start reads LIVE only for a tournament that can actually
  // run (audit fix 2026-11-21) — a pending/draft tournament whose
  // start time passed never went live.
  if (diff <= 0) return (st == 'upcoming' || st == 'full') ? 'LIVE' : 'ENDED';
  if (diff < 60 * 60 * 1000) return 'Starting Soon';
  final d = diff ~/ (24 * 60 * 60 * 1000);
  final h = (diff % (24 * 60 * 60 * 1000)) ~/ (60 * 60 * 1000);
  final m = (diff % (60 * 60 * 1000)) ~/ (60 * 1000);
  if (d > 0) return '${d}d ${h}h ${m}m';
  return '${h}h ${m}m';
}

String hhmm(dynamic ts) {
  final ms = parseTsMs(ts);
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

String fmtDate(dynamic ts) {
  if (ts == null) return 'N/A';
  final ms = parseTsMs(ts);
  if (ms <= 0) return 'N/A';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${months[d.month - 1]} ${d.year}, ${d.hour % 12 == 0 ? 12 : d.hour % 12}:${d.minute.toString().padLeft(2, '0')} ${d.hour >= 12 ? 'PM' : 'AM'}';
}

String timeAgo(dynamic ts) {
  if (ts == null) return '';
  final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(parseTsMs(ts)));
  if (diff.inSeconds < 60) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return fmtDate(ts);
}

void toast(BuildContext context, String msg) {
  // One toast at a time: clear the queue first, so a repeated tap
  // (or a repeated validation) never parades the same message over
  // and over (Fix 10 toast loop — one Save tap showed the
  // "game select karein" toast again and again).
  final messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  messenger.showSnackBar(SnackBar(content: Text(msg)));
}

/// Clean user-facing text for a database error (Fix 9/11/14/15):
/// never show a raw PostgrestException / RLS / migration jargon to
/// the user. Maps the known failure classes; anything unknown gets
/// a generic retry line. The raw detail is NOT shown — callers that
/// need it for diagnosis should debugPrint it before calling this.
/// [action] is the verb for the failed action ("Save", "Delete",
/// "Status change", ...).
String friendlyDbError(Object? e, [String action = 'Save']) {
  final s = e?.toString() ?? '';
  if (s.contains('42501') || s.contains('row-level security')) {
    return '$action nahi hua — ijazat ka masla hai. Dobara try karein.';
  }
  if (s.contains('PGRST204') ||
      (s.contains('Could not find') && s.contains('column'))) {
    return '$action nahi hua — database mein kuch naye fields abhi maujood nahi hain. Database update ke baad dobara try karein.';
  }
  if (s.contains('PGRST202') ||
      s.contains('42883') ||
      (s.contains('Could not find') && s.contains('function'))) {
    return '$action nahi hua — database ka zaroori function abhi lagaya nahi gaya. Database update ke baad dobara try karein.';
  }
  if (s.contains('TimeoutException') || s.contains('timed out')) {
    return 'Net slow hai — $action time out ho gaya. Dobara try karein.';
  }
  if (s.contains('SocketException') ||
      s.contains('Failed host lookup') ||
      s.contains('Network is unreachable')) {
    return 'Internet nahi mil raha — connection check karke dobara try karein.';
  }
  return '$action nahi hua, dobara try karein.';
}

/// FIX 21 (2026-11-21) — exit confirmation dialog, shared by the
/// player shell (HomeShell in main.dart). (FIX 32: the admin shell
/// used to share it too; the panel is gone now.) Replaces the old
/// "Exit karne ke liye dobara dabao" toast (user order: no toast,
/// a beautiful card-view dialog instead). ENGLISH text, exactly as
/// the user worded it.
/// Returns true when the user tapped YES (exit the app), false when
/// NO was tapped or the dialog was dismissed (stay in the app).
/// The card is the canonical MockupCard (animated corner lines),
/// so the dialog matches the app's card language everywhere.
Future<bool> showExitConfirmDialog(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (dctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32),
      child: MockupCard(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        radius: 16,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: kGold.withValues(alpha: 0.15),
                border: Border.all(color: kGold, width: 1.5),
              ),
              child: Icon(Icons.exit_to_app, color: kGold, size: 28),
            ),
            const SizedBox(height: 16),
            Text(
              'Do you want to exit the application?',
              textAlign: TextAlign.center,
              style: TextStyle(color: kText, fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(dctx, false),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kText,
                      side: BorderSide(color: kBorder),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('NO', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(dctx, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kGold,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('YES', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  return result == true;
}

/// FIX 4 (2026-11-22) — log-out confirmation dialog, same style as
/// the exit dialog above (MockupCard, gold, YES/NO). Shown when the
/// user taps LOG OUT in Settings (user order: "jaise exit ka
/// mangta hai na waise log out ka bhi mange"). Returns true when
/// the user tapped YES (log out), false when NO was tapped or the
/// dialog was dismissed (stay signed in).
Future<bool> showLogoutConfirmDialog(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (dctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32),
      child: MockupCard(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        radius: 16,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: kGold.withValues(alpha: 0.15),
                border: Border.all(color: kGold, width: 1.5),
              ),
              child: Icon(Icons.logout, color: kGold, size: 28),
            ),
            const SizedBox(height: 16),
            Text(
              'Do you want to log out?',
              textAlign: TextAlign.center,
              style: TextStyle(color: kText, fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(dctx, false),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kText,
                      side: BorderSide(color: kBorder),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('NO', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(dctx, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kGold,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('YES', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  return result == true;
}

Future<void> showInfoDialog(BuildContext context, String title, String body) {
  return showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: kCardPurpleMid,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
      title: Text(title, style: TextStyle(color: kText)),
      content: SingleChildScrollView(child: Text(body, style: TextStyle(color: kText))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('OK', style: TextStyle(color: kGold))),
      ],
    ),
  );
}

/// Gold card component. Historic name kept so all call sites keep
/// working; the implementation is the canonical [MockupCard] (global
/// card rule 2026-11-20: gradient fill + two short yellow shines,
/// no full border). [animate] defaults to true (user order
/// 2026-11-20, app-wide sweep): the shines rotate on every card,
/// list rows included — the user reported static corner lines on
/// the Community screen and ordered all of them animated. Padding
/// and shape contract unchanged.
Widget appCard({required Widget child, EdgeInsetsGeometry padding = const EdgeInsets.all(14), bool animate = true}) {
  return MockupCard(padding: padding, radius: 16, animate: animate, child: child);
}

/// GOLD PRIMARY button (§7.1): gold fill, dark bold text. Historic
/// name kept so all call sites keep working; the implementation is
/// the canonical GoldButton in components/arena_components.dart.
Widget goldButton({required String label, required VoidCallback? onPressed, bool busy = false}) {
  return GoldButton(label: label, onPressed: onPressed, busy: busy);
}

Widget field({required TextEditingController controller, required String label, String? hint, bool obscure = false, TextInputType? keyboardType, int maxLines = 1}) {
  return ArenaFormField(controller: controller, label: label, hint: hint, obscure: obscure, keyboardType: keyboardType, maxLines: maxLines);
}

/// REMAINING-ITEMS: Roman Urdu translation, extended beyond Pro Hub.
/// `isUrdu` is loaded once at startup from SharedPreferences
/// `app_language` ('ur' = Roman Urdu, else English); changing it in
/// App Settings applies after an app restart (stated in Settings).
/// Translated in this round: shell titles + bottom nav, Home headings,
/// App Settings, Pro Hub labels, common buttons. Still English:
/// room chat UI, tournament detail forms, wallet forms, admin app,
/// and system dialogs — listed exactly in Settings so the toggle
/// never claims a full translation it does not deliver.
bool get isUrdu => langUrduNotifier.value;
final ValueNotifier<bool> langUrduNotifier = ValueNotifier<bool>(false);

String tr(String en, String ur) => isUrdu ? ur : en;
