// FIX 34 (2026-11-24) — first-launch permission flow tests.
//
// Proves, with NO device and NO real platform (MethodChannel mock
// for permission_handler + SharedPreferences mock):
//   1. the row list is API-level correct on every band (SDK 24 /
//      30 / 31 / 32 / 33 / 36) — Bluetooth only 31+, Notifications
//      + Photos(READ_MEDIA_IMAGES) only 33+, Photos via storage
//      only 32 and below, Mic + Camera always;
//   2. the release-string -> SDK mapping (incl. Android 12L);
//   3. the once-flag: unset on a fresh install, set after the
//      sheet is presented, and the flow never shows again once set;
//   4. the sheet appears on a fresh install and Skip closes it
//      with Home untouched (a denial never blocks login/Home);
//   5. Allow taps never crash when the plugin call fails
//      (MissingPluginException -> denied, sheet stays usable);
//   6. a permanently-denied permission shows the short explanation
//      + Settings shortcut (mocked request result), and tapping
//      Settings opens app settings without a crash;
//   7. the join-flow permission requests are STILL in
//      room_screen.dart (the safety net was not removed);
//   8. the PACKAGED manifest (build/manual-apk/AndroidManifest.xml
//      — the one link_base.sh feeds to aapt2) declares CAMERA +
//      READ_MEDIA_IMAGES + READ_EXTERNAL_STORAGE (maxSdk 32), and
//      the app manifest declares the same three (in sync).
//
// GOLD: this file contains NO hex colour literal at all (banned
// golds are never asserted by literal here).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:protournament_user/services/first_launch_permissions.dart';
import 'package:protournament_user/widgets/first_launch_permissions_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const permissionChannel =
      MethodChannel('flutter.baseflow.com/permissions/methods');

  /// Default permission_handler mock: every status check reads
  /// denied, every request is denied. Installed in setUp because
  /// an UNMOCKED channel call in flutter_test never completes
  /// (its Future hangs forever — there is no engine to reply),
  /// which would hang pumpAndSettle, not throw. Individual tests
  /// override it with their own mock (installed later wins).
  Future<dynamic> defaultPermissionMock(MethodCall call) async {
    switch (call.method) {
      case 'checkPermissionStatus':
        return PermissionStatus.denied.index;
      case 'requestPermissions':
        final requested = (call.arguments as List).cast<int>();
        return {
          for (final v in requested) v: PermissionStatus.denied.index,
        };
      case 'openAppSettings':
        return true;
      default:
        return null;
    }
  }

  void installPermissionMock(
      Future<dynamic> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, handler);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FirstLaunchPermissions.debugIsAndroid = null;
    FirstLaunchPermissions.debugSdkInt = null;
    installPermissionMock(defaultPermissionMock);
  });

  tearDown(() {
    FirstLaunchPermissions.debugIsAndroid = null;
    FirstLaunchPermissions.debugSdkInt = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, null);
  });

  /// Host page standing in for Home: a button that triggers the
  /// flow exactly the way HomeShell.initState does. The viewport
  /// is a phone (1080x1920): the default 800x600 test window is
  /// shorter than the sheet's 85%-height content, so the bottom
  /// buttons would sit below the fold and taps would miss them.
  Future<void> pumpHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => maybeShowFirstLaunchPermissions(context),
                child: const Text('home-trigger'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.text('home-trigger'));
    await tester.pumpAndSettle();
  }

  group('sdkIntFromRelease', () {
    test('maps Android releases to SDK ints', () {
      expect(FirstLaunchPermissions.sdkIntFromRelease('7.0'), 24);
      expect(FirstLaunchPermissions.sdkIntFromRelease('7.1'), 25);
      expect(FirstLaunchPermissions.sdkIntFromRelease('8.0'), 26);
      expect(FirstLaunchPermissions.sdkIntFromRelease('8.1'), 27);
      expect(FirstLaunchPermissions.sdkIntFromRelease('9'), 28);
      expect(FirstLaunchPermissions.sdkIntFromRelease('10'), 29);
      expect(FirstLaunchPermissions.sdkIntFromRelease('11'), 30);
      // Sameer's TECNO (Android 12) and 12L both map to 31 — both
      // sit between the 31 and 33 gates, so no row mis-gates.
      expect(FirstLaunchPermissions.sdkIntFromRelease('12'), 31);
      expect(FirstLaunchPermissions.sdkIntFromRelease('13'), 33);
      expect(FirstLaunchPermissions.sdkIntFromRelease('14'), 34);
      expect(FirstLaunchPermissions.sdkIntFromRelease('15'), 35);
      expect(FirstLaunchPermissions.sdkIntFromRelease('16'), 36);
    });

    test('returns null for unparseable releases', () {
      expect(FirstLaunchPermissions.sdkIntFromRelease(''), isNull);
      expect(FirstLaunchPermissions.sdkIntFromRelease('abc'), isNull);
    });
  });

  group('permissionsForSdk', () {
    List<Permission> perms(int sdk) => FirstLaunchPermissions
        .permissionsForSdk(sdk)
        .map((i) => i.permission)
        .toList();

    test('Android 7 (SDK 24): mic + storage + camera only', () {
      expect(perms(24), [
        Permission.microphone,
        Permission.storage,
        Permission.camera,
      ]);
    });

    test('Android 11 (SDK 30): still no Bluetooth', () {
      expect(perms(30), [
        Permission.microphone,
        Permission.storage,
        Permission.camera,
      ]);
    });

    test('Android 12 (SDK 31, Sameer TECNO): + Bluetooth, still storage', () {
      expect(perms(31), [
        Permission.microphone,
        Permission.bluetoothConnect,
        Permission.storage,
        Permission.camera,
      ]);
    });

    test('Android 12L (SDK 32): same rows as 31', () {
      expect(perms(32), perms(31));
    });

    test('Android 13 (SDK 33): + Notifications, Photos via photos', () {
      expect(perms(33), [
        Permission.microphone,
        Permission.bluetoothConnect,
        Permission.notification,
        Permission.photos,
        Permission.camera,
      ]);
    });

    test('Android 16 (SDK 36): same five rows as 33', () {
      expect(perms(36), perms(33));
    });

    test('Photos row names the right manifest permission per band', () {
      final legacy = FirstLaunchPermissions.permissionsForSdk(31)
          .firstWhere((i) => i.title == 'Photos');
      expect(legacy.manifestName,
          'android.permission.READ_EXTERNAL_STORAGE');
      final modern = FirstLaunchPermissions.permissionsForSdk(33)
          .firstWhere((i) => i.title == 'Photos');
      expect(
          modern.manifestName, 'android.permission.READ_MEDIA_IMAGES');
    });

    test('every row has a title and a one-line plain-words reason', () {
      for (final sdk in [24, 30, 31, 32, 33, 36]) {
        for (final item in FirstLaunchPermissions.permissionsForSdk(sdk)) {
          expect(item.title.isNotEmpty, isTrue);
          expect(item.reason.isNotEmpty, isTrue);
          expect(item.reason.contains('\n'), isFalse,
              reason: '${item.title} reason must be one line');
        }
      }
    });
  });

  group('once flag', () {
    test('unset on a fresh install, set after markFlowDone', () async {
      expect(await FirstLaunchPermissions.isFlowDone(), isFalse);
      await FirstLaunchPermissions.markFlowDone();
      expect(await FirstLaunchPermissions.isFlowDone(), isTrue);
    });

    test('shouldShowFlow gates on Android + unset flag', () {
      expect(
          FirstLaunchPermissions.shouldShowFlow(
              isAndroid: true, flagSet: false),
          isTrue);
      expect(
          FirstLaunchPermissions.shouldShowFlow(
              isAndroid: true, flagSet: true),
          isFalse);
      expect(
          FirstLaunchPermissions.shouldShowFlow(
              isAndroid: false, flagSet: false),
          isFalse);
    });
  });

  group('actionForStatus', () {
    test('granted -> granted, permanentlyDenied -> settings, else allow',
        () {
      expect(
          FirstLaunchPermissions.actionForStatus(
              PermissionStatus.granted),
          FirstLaunchAction.granted);
      expect(
          FirstLaunchPermissions.actionForStatus(
              PermissionStatus.permanentlyDenied),
          FirstLaunchAction.openSettings);
      expect(
          FirstLaunchPermissions.actionForStatus(PermissionStatus.denied),
          FirstLaunchAction.allow);
      expect(
          FirstLaunchPermissions.actionForStatus(
              PermissionStatus.restricted),
          FirstLaunchAction.allow);
    });
  });

  group('first-launch sheet (widget)', () {
    testWidgets('shows once on a fresh install, never again once set',
        (tester) async {
      FirstLaunchPermissions.debugIsAndroid = true;
      FirstLaunchPermissions.debugSdkInt = 33;
      await pumpHost(tester);
      expect(await FirstLaunchPermissions.isFlowDone(), isFalse);

      // Fresh install: the sheet appears with all five rows.
      await openSheet(tester);
      expect(find.text('Permissions'), findsOneWidget);
      expect(find.text('Microphone'), findsOneWidget);
      expect(find.text('Bluetooth'), findsOneWidget);
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('Photos'), findsOneWidget);
      expect(find.text('Camera'), findsOneWidget);
      expect(find.text('Allow all'), findsOneWidget);
      expect(find.text('Skip for now'), findsOneWidget);

      // The flag is set at PRESENTATION — the flow has run once.
      expect(await FirstLaunchPermissions.isFlowDone(), isTrue);

      // Skip closes the sheet; Home underneath is untouched — a
      // denial (here: skipping everything) never blocks the app.
      await tester.tap(find.text('Skip for now'));
      await tester.pumpAndSettle();
      expect(find.text('Permissions'), findsNothing);
      expect(find.text('home-trigger'), findsOneWidget);

      // Second trigger: the flag is set, no sheet ever again.
      await tester.tap(find.text('home-trigger'));
      await tester.pumpAndSettle();
      expect(find.text('Permissions'), findsNothing);
    });

    testWidgets('Android 12 rows: no Notifications row, Photos via storage',
        (tester) async {
      FirstLaunchPermissions.debugIsAndroid = true;
      FirstLaunchPermissions.debugSdkInt = 31;
      await pumpHost(tester);
      await openSheet(tester);
      expect(find.text('Permissions'), findsOneWidget);
      expect(find.text('Microphone'), findsOneWidget);
      expect(find.text('Bluetooth'), findsOneWidget);
      expect(find.text('Notifications'), findsNothing);
      expect(find.text('Photos'), findsOneWidget);
      expect(find.text('Camera'), findsOneWidget);
    });

    testWidgets(
        'Allow taps never crash when the plugin call fails',
        (tester) async {
      // The missing-plugin path, simulated honestly: the mock
      // THROWS MissingPluginException (the real error a missing
      // plugin produces on a device). An absent mock would NOT
      // throw in flutter_test — its Future never completes and
      // the test would hang — so the throw is the simulation.
      installPermissionMock((MethodCall call) async {
        throw MissingPluginException(
            'No implementation found for method ${call.method} '
            'on channel flutter.baseflow.com/permissions/methods');
      });
      FirstLaunchPermissions.debugIsAndroid = true;
      FirstLaunchPermissions.debugSdkInt = 31;
      await pumpHost(tester);
      await openSheet(tester);
      expect(find.text('Permissions'), findsOneWidget);

      await tester.tap(find.text('Allow').first);
      await tester.pumpAndSettle();
      expect(find.text('Permissions'), findsOneWidget);

      await tester.tap(find.text('Allow all'));
      await tester.pumpAndSettle();
      expect(find.text('Permissions'), findsOneWidget);
      // Still dismissible after failed requests.
      await tester.tap(find.text('Skip for now'));
      await tester.pumpAndSettle();
      expect(find.text('Permissions'), findsNothing);
    });

    testWidgets(
        'permanently denied shows explanation + Settings shortcut',
        (tester) async {
      var settingsOpened = false;
      // The mock speaks the raw channel protocol: status ints are
      // the PermissionStatus enum order (denied 0, granted 1,
      // restricted 2, limited 3, permanentlyDenied 4) — the
      // platform interface decodes them by that same order
      // (statusByValue), so `.index` is the wire value here.
      // (`PermissionStatus.value` exists only inside the platform
      // interface package; it is not exported.)
      // Overrides the setUp default mock (installed later wins).
      installPermissionMock((MethodCall call) async {
        switch (call.method) {
          case 'checkPermissionStatus':
            // Notifications already granted (OneSignal boot prompt);
            // everything else denied.
            return call.arguments == Permission.notification.value
                ? PermissionStatus.granted.index
                : PermissionStatus.denied.index;
          case 'requestPermissions':
            // Mic was denied twice before -> permanently denied;
            // everything else grants.
            final requested = (call.arguments as List).cast<int>();
            return {
              for (final v in requested)
                v: v == Permission.microphone.value
                    ? PermissionStatus.permanentlyDenied.index
                    : PermissionStatus.granted.index,
            };
          case 'openAppSettings':
            settingsOpened = true;
            return true;
          default:
            return null;
        }
      });
      FirstLaunchPermissions.debugIsAndroid = true;
      FirstLaunchPermissions.debugSdkInt = 33;
      await pumpHost(tester);
      await openSheet(tester);

      // Already-granted row shows "Allowed" without any tap.
      expect(find.text('Allowed'), findsOneWidget);

      await tester.tap(find.text('Allow all'));
      await tester.pumpAndSettle();

      // Mic: permanently denied -> short explanation + Settings.
      expect(
          find.text('Blocked — open Settings to allow it.'),
          findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      // The rest granted.
      expect(find.text('Allowed'), findsNWidgets(4));

      // Settings shortcut works and never crashes.
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(settingsOpened, isTrue);
      expect(find.text('Permissions'), findsOneWidget);
    });

    testWidgets('direct pump renders the SDK 24 row set', (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FirstLaunchPermissionsSheet(
                items: FirstLaunchPermissions.permissionsForSdk(24),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Microphone'), findsOneWidget);
      expect(find.text('Photos'), findsOneWidget);
      expect(find.text('Camera'), findsOneWidget);
      expect(find.text('Bluetooth'), findsNothing);
      expect(find.text('Notifications'), findsNothing);
    });
  });

  group('join-flow safety net (source check)', () {
    test('room_screen.dart still requests mic + bluetooth + notification',
        () {
      final src =
          File('lib/screens/room_screen.dart').readAsStringSync();
      expect(src.contains('Permission.microphone.request()'), isTrue,
          reason: 'mic request must stay at mic-take');
      expect(src.contains('Permission.bluetoothConnect.request()'), isTrue,
          reason: 'bluetooth request must stay at mic-take');
      expect(src.contains('Permission.notification.request()'), isTrue,
          reason: 'notification request must stay at mic-take');
      expect(src.contains('openAppSettings()'), isTrue,
          reason: 'permanently-denied Settings shortcut must stay');
    });
  });

  group('packaged manifest (file check)', () {
    test('pipeline manifest declares CAMERA + photos permissions', () {
      // THIS is the manifest the manual build packages:
      // link_base.sh runs `aapt2 link --manifest AndroidManifest.xml`
      // from build/manual-apk, and assemble_arena.py copies the
      // resulting AndroidManifest.xml into the APK.
      final src = File('build/manual-apk/AndroidManifest.xml')
          .readAsStringSync();
      expect(src.contains('android.permission.CAMERA'), isTrue);
      expect(src.contains('android.permission.READ_MEDIA_IMAGES'), isTrue);
      expect(
          src.contains('android.permission.READ_EXTERNAL_STORAGE'), isTrue);
      expect(src.contains('android:maxSdkVersion="32"'), isTrue,
          reason: 'READ_EXTERNAL_STORAGE must be capped at SDK 32');
    });

    test('app manifest declares the same three permissions (in sync)',
        () {
      final src = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(src.contains('android.permission.CAMERA'), isTrue);
      expect(src.contains('android.permission.READ_MEDIA_IMAGES'), isTrue);
      expect(
          src.contains('android.permission.READ_EXTERNAL_STORAGE'), isTrue);
      expect(src.contains('android:maxSdkVersion="32"'), isTrue);
    });
  });
}
