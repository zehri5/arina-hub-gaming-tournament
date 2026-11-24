import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/first_launch_permissions.dart';
import '../theme.dart';

/// FIX 34 (2026-11-24) — the first-launch permission sheet.
///
/// Shown ONCE per install, after login, over the first Home screen
/// (triggered by one post-frame call in HomeShell.initState).
/// One row per permission that applies on this device's API level,
/// each with a one-line plain-words reason, an Allow action, and a
/// Skip option for the whole sheet.
///
///   * The once-flag is set when the sheet is PRESENTED (inside
///     [maybeShowFirstLaunchPermissions], before the sheet opens),
///     so no exit path — Skip, swipe-away, Allow-all, app killed
///     mid-sheet — can ever re-show it. Denied permissions are
///     re-asked later at feature use (the room join-flow requests
///     stay as the safety net); this flow never loops.
///   * A denial NEVER blocks anything: Skip closes the sheet and
///     the app works. No login gate, no Home gate, no retry loop.
///   * PERMANENTLY DENIED: the honest Bluetooth pattern from the
///     join-flow dialog, adapted to the sheet — the row shows a
///     short explanation ("Blocked — open Settings to allow it.")
///     + a Settings shortcut (openAppSettings). Never silently
///     swallowed, never re-requested in a loop (Allow-all skips
///     permanently-denied rows).
///   * Every permission_handler call is try/catch: a missing
///     plugin (MissingPluginException — the same quirk the image
///     pickers guard against) reads as denied, never a crash.
///   * "Allow all" requests SEQUENTIALLY — Android shows one
///     system dialog at a time; parallel requests would collide.
///
/// DESIGN (strict, user order): gold #FDC903 ONLY — every gold
/// here comes from the shared [kGold] token, and the file contains
/// NO hardcoded hex colour literal at all. Same dark-purple sheet
/// shell as the listeners detail sheet (kCardPurpleMid, rounded
/// top, purple border, gold drag handle).

/// Shows the first-launch permission sheet if (and only if) this
/// is an Android device and the flow has never run. Fire-and-
/// forget: never throws, never blocks Home — every failure path
/// just returns without showing anything.
Future<void> maybeShowFirstLaunchPermissions(BuildContext context) async {
  try {
    if (!FirstLaunchPermissions.isAndroid) return;
    if (await FirstLaunchPermissions.isFlowDone()) return;
    final items = FirstLaunchPermissions.permissionsForThisDevice();
    // Mark done BEFORE presenting: the flow runs exactly once
    // whatever the user does with the sheet (see the file header).
    await FirstLaunchPermissions.markFlowDone();
    if (items.isEmpty) return;
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCardPurpleMid,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
          side: BorderSide(color: kCardPurpleBorder, width: 1.5)),
      builder: (sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.85),
        child: SingleChildScrollView(
          child: FirstLaunchPermissionsSheet(items: items),
        ),
      ),
    );
  } catch (_) {
    // Never block Home on a permission-flow failure.
  }
}

/// The sheet content: header, one row per [items], then Allow-all
/// + Skip. Takes the row list as a constructor argument so tests
/// can pump it for any API band without a device.
class FirstLaunchPermissionsSheet extends StatefulWidget {
  /// The permission rows to show (see
  /// [FirstLaunchPermissions.permissionsForSdk]).
  final List<FirstLaunchPermissionItem> items;

  const FirstLaunchPermissionsSheet({super.key, required this.items});

  @override
  State<FirstLaunchPermissionsSheet> createState() =>
      _FirstLaunchPermissionsSheetState();
}

class _FirstLaunchPermissionsSheetState
    extends State<FirstLaunchPermissionsSheet> {
  /// Current known status per permission (absent = not checked
  /// yet — the row shows a spinner until the check lands).
  final Map<Permission, PermissionStatus> _status = {};

  /// Permissions with a system dialog currently open.
  final Set<Permission> _requesting = {};

  /// An Allow-all run is in progress.
  bool _requestingAll = false;

  @override
  void initState() {
    super.initState();
    _refreshStatuses();
  }

  /// Reads each row's current status so already-granted rows show
  /// "Allowed" instead of a pointless Allow button (e.g. the user
  /// granted notifications at the OneSignal boot prompt). A
  /// failed check reads as denied — never a crash.
  Future<void> _refreshStatuses() async {
    for (final item in widget.items) {
      PermissionStatus status;
      try {
        status = await item.permission.status;
      } catch (_) {
        status = PermissionStatus.denied;
      }
      if (!mounted) return;
      setState(() => _status[item.permission] = status);
    }
  }

  /// Requests one permission and records the outcome. A failed
  /// request (missing plugin) reads as denied; the row keeps its
  /// Allow button so the user can retry.
  Future<void> _requestOne(FirstLaunchPermissionItem item) async {
    if (_requesting.contains(item.permission)) return;
    setState(() => _requesting.add(item.permission));
    PermissionStatus status;
    try {
      status = await item.permission.request();
    } catch (_) {
      status = PermissionStatus.denied;
    }
    if (!mounted) return;
    setState(() {
      _requesting.remove(item.permission);
      _status[item.permission] = status;
    });
  }

  /// Requests every not-yet-granted row, one at a time (Android
  /// shows one system dialog at a time). Permanently-denied rows
  /// are SKIPPED — re-requesting them shows no dialog and would
  /// only loop; their rows offer the Settings shortcut instead.
  Future<void> _requestAll() async {
    if (_requestingAll) return;
    setState(() => _requestingAll = true);
    for (final item in widget.items) {
      final status = _status[item.permission];
      if (status != null && status.isGranted) continue;
      if (status != null && status.isPermanentlyDenied) continue;
      await _requestOne(item);
      if (!mounted) return;
    }
    if (mounted) setState(() => _requestingAll = false);
  }

  /// Opens the app's system Settings page (permanently-denied
  /// rows only). Best-effort — never throws.
  Future<void> _openSettings() async {
    try {
      await openAppSettings();
    } catch (_) {}
  }

  bool get _allGranted => widget.items.isNotEmpty &&
      widget.items
          .every((i) => _status[i.permission]?.isGranted == true);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Gold drag handle (same as the listeners sheet).
          Center(
            child: Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                  color: kGold, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 16),
          Text('Permissions',
              style: TextStyle(
                  color: kGold,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1)),
          const SizedBox(height: 6),
          Text(
              'Allow what you need — anything you skip can be allowed later, when you use that feature.',
              style: TextStyle(color: kMuted, fontSize: 14, height: 1.4)),
          const SizedBox(height: 12),
          ..._rows(),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _requestingAll
                  ? null
                  : () {
                      if (_allGranted) {
                        Navigator.of(context).pop();
                      } else {
                        _requestAll();
                      }
                    },
              style: ElevatedButton.styleFrom(
                  backgroundColor: kGold,
                  disabledBackgroundColor: kGold,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14))),
              child: _requestingAll
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.black, strokeWidth: 2.5))
                  : Text(_allGranted ? 'Done' : 'Allow all',
                      style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: 16)),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Skip for now',
                  style: TextStyle(color: kMuted, fontSize: 14)),
            ),
          ),
        ],
      ),
    );
  }

  /// The permission rows with thin dividers between them.
  List<Widget> _rows() {
    final rows = <Widget>[];
    for (var i = 0; i < widget.items.length; i++) {
      if (i > 0) {
        rows.add(Divider(
            height: 1,
            color: kCardPurpleBorder.withValues(alpha: 0.35)));
      }
      rows.add(_row(widget.items[i]));
    }
    return rows;
  }

  /// One permission row: gold icon, title + one-line reason, and
  /// the trailing action for the row's current status.
  Widget _row(FirstLaunchPermissionItem item) {
    final status = _status[item.permission];
    final requesting = _requesting.contains(item.permission);
    final action = status == null
        ? null
        : FirstLaunchPermissions.actionForStatus(status);
    // Permanently denied: the reason line becomes the short
    // explanation, and the button becomes the Settings shortcut.
    final reason = action == FirstLaunchAction.openSettings
        ? 'Blocked — open Settings to allow it.'
        : item.reason;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: kGold.withValues(alpha: 0.14),
            ),
            child: Icon(item.icon, color: kGold, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title,
                    style: TextStyle(
                        color: kText,
                        fontSize: 15,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(reason,
                    style:
                        TextStyle(color: kMuted, fontSize: 13)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (requesting)
            SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    color: kGold, strokeWidth: 2.5))
          else if (status == null)
            SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    color: kGold, strokeWidth: 2.5))
          else if (action == FirstLaunchAction.granted)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle, color: kGold, size: 20),
                const SizedBox(width: 4),
                Text('Allowed',
                    style: TextStyle(
                        color: kGold,
                        fontSize: 13,
                        fontWeight: FontWeight.bold)),
              ],
            )
          else if (action == FirstLaunchAction.openSettings)
            TextButton(
              onPressed: _openSettings,
              style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  side: BorderSide(color: kGold, width: 1),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20))),
              child: Text('Settings',
                  style: TextStyle(
                      color: kGold,
                      fontSize: 13,
                      fontWeight: FontWeight.bold)),
            )
          else
            TextButton(
              onPressed: () => _requestOne(item),
              style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  side: BorderSide(color: kGold, width: 1),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20))),
              child: Text('Allow',
                  style: TextStyle(
                      color: kGold,
                      fontSize: 13,
                      fontWeight: FontWeight.bold)),
            ),
        ],
      ),
    );
  }
}
