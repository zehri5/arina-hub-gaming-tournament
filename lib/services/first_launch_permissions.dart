import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// FIX 34 (2026-11-24) — first-launch permission flow.
///
/// ROOT CAUSE (Sameer, v2022 phone report: "app install pe mic
/// bluetooth, storage etc ki permission nhi mang rhi"): a fresh
/// install never asked for ANY permission, for two stacked reasons:
///   1. NO first-run permission flow existed anywhere in the app.
///      The ONLY runtime requests lived in room_screen.dart
///      (~7013-7062, inside the mic-take / join-voice flow) — and
///      they run only AFTER the mic-request gate, so a non-admin
///      without a live admin approval sends a mic request and
///      RETURNS before any permission dialog can appear.
///   2. The manifest never declared CAMERA, READ_MEDIA_IMAGES or
///      READ_EXTERNAL_STORAGE — and permission_handler returns
///      DENIED without ever showing a system dialog for a
///      permission with no manifest entry (empty manifest names,
///      permission_handler_android PermissionManager). So even a
///      request for photos/camera could never produce a dialog.
///      (Both manifests now declare all three — see
///      android/app/src/main/AndroidManifest.xml and the pipeline
///      manifest build/manual-apk/AndroidManifest.xml, which is
///      the one the manual build actually packages.)
///
/// This file owns the flow's LOGIC (pure + testable): which rows
/// apply on this device's API level, the once-flag, and the
/// status -> action mapping. The UI lives in
/// widgets/first_launch_permissions_sheet.dart; the trigger is one
/// post-frame call in HomeShell.initState (main.dart) — after
/// login, over the first Home screen.
///
/// DESIGN (user order, item 34):
///   * ONE sheet, ONCE per install. The SharedPreferences flag is
///     set when the sheet is PRESENTED (not when it closes), so no
///     exit path — Skip, swipe-away, Allow-all, app killed
///     mid-sheet — can ever re-show it. Denied permissions are
///     re-asked later at feature use (the room join-flow requests
///     stay as the safety net); this flow never loops.
///   * A denial NEVER blocks anything: no login gate, no Home
///     gate, no retry loop. Skip closes the sheet; the app works.
///   * API-LEVEL CORRECTNESS (targetSdk 36, minSdk 24): each row
///     is requested only where its permission exists —
///     BLUETOOTH_CONNECT only on SDK 31+, POST_NOTIFICATIONS and
///     READ_MEDIA_IMAGES only on SDK 33+, READ_EXTERNAL_STORAGE
///     only on SDK 32 and below (maxSdkVersion 32 in the
///     manifest). permission_handler gates the same way
///     internally; the row list gates the UI so a permission that
///     does not exist on the device is never even shown.
///   * SDK detection WITHOUT device_info_plus (transitive-only in
///     this app — must not be imported, see auth_screen.dart):
///     [Platform.operatingSystemVersion] on Android is
///     Build.VERSION.RELEASE ("12", "13", ...), mapped to an SDK
///     int by [sdkIntFromRelease]. The only gates are 31 and 33,
///     and release-major maps onto them exactly (12 -> 31/32,
///     13+ -> 33+), so the mapping cannot mis-gate.
///   * REQUEST ONLY WHAT IS NEEDED: the pick paths (image_picker
///     gallery + file_picker fallback) use the system photo picker
///     / SAF on Android 13+, which need NO permission — the Photos
///     row still asks READ_MEDIA_IMAGES there because the
///     file_picker fallback resolves real file paths on some
///     devices/OEMs, and READ_EXTERNAL_STORAGE on 12 and below
///     covers the legacy gallery path where the photo picker is
///     unavailable. CAMERA is declared + asked (profile photo
///     take-photo affordance) even though today every pickImage
///     call uses ImageSource.gallery — no camera capture path
///     exists yet in code; if the row is ever unwanted it is a
///     one-line removal in [permissionsForSdk].
///   * PERMANENTLY DENIED: the honest pattern from the Bluetooth
///     join-flow dialog, adapted to the sheet — the row shows a
///     short explanation ("Blocked — open Settings to allow it.")
///     + a Settings shortcut (openAppSettings). Never silently
///     swallowed, never re-requested in a loop.
///
/// GOLD: this file contains NO hardcoded hex colour literal at
/// all (no colours are needed here; the sheet uses [kGold]).

/// What a permission row offers for its current status.
enum FirstLaunchAction {
  /// Show the Allow button (denied / restricted / unknown).
  allow,

  /// Show the Settings shortcut (permanently denied — only
  /// Settings can grant it now).
  openSettings,

  /// Already granted — show the "Allowed" state, no button.
  granted,
}

/// One permission row in the first-launch sheet.
class FirstLaunchPermissionItem {
  /// The permission_handler permission to check / request.
  final Permission permission;

  /// Short title, e.g. 'Microphone'.
  final String title;

  /// One-line reason in plain words, e.g. 'Talk in voice rooms
  /// and live chats.' Never contains a newline.
  final String reason;

  /// Row icon (gold in the sheet).
  final IconData icon;

  /// The Android manifest permission name behind this row
  /// (documentation + tests).
  final String manifestName;

  const FirstLaunchPermissionItem({
    required this.permission,
    required this.title,
    required this.reason,
    required this.icon,
    required this.manifestName,
  });
}

/// First-launch permission flow: row list, once-flag, status
/// mapping. All static; no instance state.
class FirstLaunchPermissions {
  /// SharedPreferences flag: true once the first-launch sheet has
  /// been presented (any exit path). Never reset by the app.
  static const String flagKey = 'fix34_first_launch_permissions_done';

  /// TEST SEAMS (null in production — do not set outside tests):
  /// override the platform / SDK detection so widget tests can
  /// run the flow on a non-Android host. Each test file runs in
  /// its own isolate, so these never leak into another file.
  static bool? debugIsAndroid;
  static int? debugSdkInt;

  /// This device is Android (or the test override says so).
  static bool get isAndroid => debugIsAndroid ?? Platform.isAndroid;

  // --- The five rows (task order: mic, bluetooth, notifications,
  // photos, camera). Photos has two variants — one per API band.

  static const FirstLaunchPermissionItem _mic =
      FirstLaunchPermissionItem(
    permission: Permission.microphone,
    title: 'Microphone',
    reason: 'Talk in voice rooms and live chats.',
    icon: Icons.mic,
    manifestName: 'android.permission.RECORD_AUDIO',
  );

  static const FirstLaunchPermissionItem _bluetooth =
      FirstLaunchPermissionItem(
    permission: Permission.bluetoothConnect,
    title: 'Bluetooth',
    reason: 'Use a Bluetooth headset in voice rooms.',
    icon: Icons.bluetooth,
    manifestName: 'android.permission.BLUETOOTH_CONNECT',
  );

  static const FirstLaunchPermissionItem _notifications =
      FirstLaunchPermissionItem(
    permission: Permission.notification,
    title: 'Notifications',
    reason: 'Get alerts for invites, matches and messages.',
    icon: Icons.notifications,
    manifestName: 'android.permission.POST_NOTIFICATIONS',
  );

  static const FirstLaunchPermissionItem _photosNew =
      FirstLaunchPermissionItem(
    permission: Permission.photos,
    title: 'Photos',
    reason: 'Choose profile and community pictures.',
    icon: Icons.photo_library,
    manifestName: 'android.permission.READ_MEDIA_IMAGES',
  );

  static const FirstLaunchPermissionItem _photosLegacy =
      FirstLaunchPermissionItem(
    permission: Permission.storage,
    title: 'Photos',
    reason: 'Choose profile and community pictures.',
    icon: Icons.photo_library,
    manifestName: 'android.permission.READ_EXTERNAL_STORAGE',
  );

  static const FirstLaunchPermissionItem _camera =
      FirstLaunchPermissionItem(
    permission: Permission.camera,
    title: 'Camera',
    reason: 'Take photos for your profile and posts.',
    icon: Icons.camera_alt,
    manifestName: 'android.permission.CAMERA',
  );

  /// Maps an Android release string ("12", "13", "8.1", ...) to
  /// its SDK int. Returns null when the string has no leading
  /// version number. Android 12L (SDK 32) reports release "12"
  /// like Android 12 (SDK 31) — both sit between the 31 and 33
  /// gates, so mapping 12 -> 31 can never mis-gate a row.
  /// Future majors map one SDK per major (17 -> 37, ...).
  static int? sdkIntFromRelease(String release) {
    final match =
        RegExp(r'^\s*(\d+)(?:\.(\d+))?').firstMatch(release);
    if (match == null) return null;
    final major = int.tryParse(match.group(1)!);
    if (major == null) return null;
    final minor = int.tryParse(match.group(2) ?? '0') ?? 0;
    switch (major) {
      case 7:
        return minor >= 1 ? 25 : 24;
      case 8:
        return minor >= 1 ? 27 : 26;
      case 9:
        return 28;
      case 10:
        return 29;
      case 11:
        return 30;
      case 12:
        return 31;
      case 13:
        return 33;
      case 14:
        return 34;
      case 15:
        return 35;
      case 16:
        return 36;
      default:
        if (major < 7) return 23;
        return 36 + (major - 16);
    }
  }

  /// Android SDK int for this device, or null on non-Android /
  /// unparseable release. The test seam ([debugSdkInt]) wins when
  /// set.
  static int? androidSdkInt() {
    if (debugSdkInt != null) return debugSdkInt;
    if (!Platform.isAndroid) return null;
    try {
      return sdkIntFromRelease(Platform.operatingSystemVersion);
    } catch (_) {
      return null;
    }
  }

  /// The permission rows that apply on [sdkInt] — pure, so tests
  /// can pin every API band exactly:
  ///   * always: Microphone, Camera (runtime permissions on every
  ///     API level >= 23; minSdk is 24).
  ///   * SDK >= 31: + Bluetooth (BLUETOOTH_CONNECT, Android 12+).
  ///   * SDK >= 33: + Notifications (POST_NOTIFICATIONS) and
  ///     Photos via READ_MEDIA_IMAGES (Android 13+).
  ///   * SDK <= 32: Photos via READ_EXTERNAL_STORAGE instead.
  /// Nothing is ever requested where it does not exist.
  static List<FirstLaunchPermissionItem> permissionsForSdk(int sdkInt) {
    final items = <FirstLaunchPermissionItem>[_mic];
    if (sdkInt >= 31) items.add(_bluetooth);
    if (sdkInt >= 33) {
      items.add(_notifications);
      items.add(_photosNew);
    } else {
      items.add(_photosLegacy);
    }
    items.add(_camera);
    return items;
  }

  /// The rows for THIS device. When the SDK cannot be determined
  /// (unparseable release — near-impossible on a real device),
  /// falls back to the two permissions that exist on every API
  /// level, so the flow never shows a row it cannot honour.
  static List<FirstLaunchPermissionItem> permissionsForThisDevice() {
    final sdk = androidSdkInt();
    if (sdk == null) return const [_mic, _camera];
    return permissionsForSdk(sdk);
  }

  /// Whether the first-launch flow has already run (flag set).
  /// A preferences failure reads as "not done" (fail-open: the
  /// flow shows once rather than never).
  static Future<bool> isFlowDone() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(flagKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Marks the flow done. Never throws — a failed write must not
  /// break Home (worst case the sheet shows once more next
  /// launch, which the join-flow safety net makes harmless).
  static Future<void> markFlowDone() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(flagKey, true);
    } catch (_) {}
  }

  /// The show decision, extracted pure for tests: Android only,
  /// and only while the flag is unset.
  static bool shouldShowFlow(
          {required bool isAndroid, required bool flagSet}) =>
      isAndroid && !flagSet;

  /// What action a row offers for a [PermissionStatus]: granted
  /// -> no button; permanently denied -> Settings shortcut;
  /// anything else (denied / restricted / limited) -> Allow.
  /// A restricted permission's Allow tap simply returns
  /// restricted again — no loop, no crash (user-initiated taps
  /// only; nothing auto-retries).
  static FirstLaunchAction actionForStatus(PermissionStatus status) {
    if (status.isGranted) return FirstLaunchAction.granted;
    if (status.isPermanentlyDenied) return FirstLaunchAction.openSettings;
    return FirstLaunchAction.allow;
  }
}
