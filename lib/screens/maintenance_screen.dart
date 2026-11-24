import 'package:flutter/material.dart';
import '../utils.dart';
import '../widgets/arena_ui.dart';

/// v2003 FIX 6 — Maintenance mode, user side.
///
/// Beautiful blocking screen: crest logo + gold style, the admin's
/// own message, Retry. The app is BLOCKED while this is shown — the
/// system back button does nothing (PopScope canPop: false); the only
/// ways out are Retry (when maintenance clears) and, for a signed-in
/// admin, "Continue as Admin" (audit W-2: maintenance used to lock
/// the admin out too).
///
/// CURRENTLY UNUSED (audit 2026-11-21): no caller constructs this
/// screen — main.dart renders its own maintenance gate UI inline.
/// Kept for reuse (the tree has no git history, so deletion is
/// unrecoverable); wire it back in or delete it only once the tree
/// is under version control.
class MaintenanceScreen extends StatefulWidget {
  const MaintenanceScreen({
    super.key,
    required this.message,
    this.appName = 'ARENA HUB',
    this.onRetry,
    this.showAdminBypass = false,
    this.onContinueAsAdmin,
  });

  /// Admin's maintenance message (app_settings.maintenance_message).
  final String message;

  /// Branded app name (app_settings.app_name, fallback ARENA HUB).
  final String appName;

  /// Re-check maintenance; the caller pops / re-boots when it clears.
  final Future<void> Function()? onRetry;

  /// Show the "Continue as Admin" escape (signed-in admin only).
  final bool showAdminBypass;
  final VoidCallback? onContinueAsAdmin;

  @override
  State<MaintenanceScreen> createState() => _MaintenanceScreenState();
}

class _MaintenanceScreenState extends State<MaintenanceScreen> {
  bool _retrying = false;

  Future<void> _doRetry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await widget.onRetry?.call();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Brand wordmark: two words split over two lines like the splash
    // (first white, second gold); one word stays on one line.
    final words = widget.appName.trim().split(RegExp(r'\s+'));
    final firstLine = words.length > 1 ? words.sublist(0, words.length - 1).join(' ') : widget.appName.trim();
    final secondLine = words.length > 1 ? words.last : '';
    final titleSize = widget.appName.length > 12 ? 30.0 : 40.0;

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: Stack(
          children: [
            // PHASE E (E23): app poster, not the old ember texture
            // (same new-design language as the offline screen).
            const AppBackgroundLayer(respectLightMode: false),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // New logo badge with a soft gold halo.
                      Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 220,
                            height: 220,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [kGold.withValues(alpha: 0.28), kGold.withValues(alpha: 0.0)],
                              ),
                            ),
                          ),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(18),
                            child: Image.asset(
                              'assets/images/arena_hub_logo.png',
                              width: 120,
                              height: 120,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Icon(Icons.emoji_events, color: kGold, size: 110),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        firstLine,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: kText, fontSize: titleSize, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, height: 1.0, letterSpacing: 1.0),
                      ),
                      if (secondLine.isNotEmpty)
                        Text(
                          secondLine,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: kGold, fontSize: titleSize, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, height: 1.0, letterSpacing: 1.0),
                        ),
                      const SizedBox(height: 28),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(color: kCardFillColor, borderRadius: BorderRadius.circular(20), border: Border.all(color: kGold.withValues(alpha: 0.5))),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.construction, color: kGold, size: 16),
                            const SizedBox(width: 8),
                            Text('UNDER MAINTENANCE', style: TextStyle(color: kText, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        widget.message,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: kMuted, fontSize: 15, height: 1.4),
                      ),
                      const SizedBox(height: 28),
                      SizedBox(
                        width: double.infinity,
                        child: goldButton(label: 'Retry', onPressed: _doRetry, busy: _retrying),
                      ),
                      if (widget.showAdminBypass) ...[
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: widget.onContinueAsAdmin,
                          child: Text('Continue as Admin', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
