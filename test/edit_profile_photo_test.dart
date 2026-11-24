// FIX 11 — EDIT PROFILE PHOTO (2026-11-21, screenshot
// 1000049134_49_1e31.jpg, Admin account). Three problems, one page
// (CreateProfilePage in lib/screens/pro_features.dart):
//
// (a) CAMERA BUTTON HALF-CUT: the old 40x40 badge sat at
// right:0/bottom:0 with its centre just inside the ring, so half
// of it hung off the circle edge overlapping the gold ring — and
// on the phone it rendered half-cut (zoomed crop: the button is
// clipped along the ring's arc, the camera glyph half shown).
// Fix: 36x36 badge whose centre sits ON the ring (62 px from the
// avatar centre), fully inside the 124px avatar box, icon centred
// inside it. These tests pump the REAL page at 360x800 and assert
// the rendered geometry — no replica.
//
// (b) PHOTO LOST ON REINSTALL: _pickPhoto only did
// setState(() => _photoUrl = url) — the URL lived ONLY in
// page-local state until SAVE CHANGES, so upload-and-leave lost
// the photo even though the preview had shown it. Fix: the upload
// path now calls saveProfilePhotoNow (same verified-write pattern
// as ProfilePage._changePhoto) — updateProfile -> read-back verify
// -> PhotoCache.invalidate + refresh bump — and the preview is set
// only AFTER the verified save. The save path is proven here with
// test doubles; no test touches the live server (updateProfile has
// no fixtures branch, so the seam is the injectable update/readBack
// of saveProfilePhotoNow, which _pickPhoto calls with the SupaDb
// tear-offs).
//
// (c) BLANK AVATAR: the screenshot shows a blank black circle with
// no initial letter. Diagnosis (read-only REST probe + live ImgBB
// check, 2026-11-21): the Admin row DOES have a photo_url and the
// image is live (HTTP 200, a real bright photo) — so the phone's
// blank circle comes from the older build on the phone (the
// screenshot itself proves it: pre-FIX-10 "IN-GAME PLAYER ID"
// label, no CHANGE PHOTO button, no DISPLAY NAME field) whose
// avatar had no fallback path at all ("was a blank circle" —
// Wave 4 Fix 5 (B) comment). The current tree renders the letter
// for empty, dead and 'null' URLs (probe-verified); what REMAINS
// to fix in the tree is the initial derivation itself —
// _name.text[0] untrimmed made a leading space render as an
// invisible "letter", and the gold letter on the light-mode circle
// was near-invisible. editProfileInitial trims + falls back to
// the username initial + '?', and the letter colour is gold on
// dark, black on light. These tests pin all of it.
//
// No pumpAndSettle anywhere — ArenaEmberDots repeats forever.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/cached_image.dart';
import 'package:protournament_user/screens/frames_widgets.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';

const _uid = 'admin-uid';
const _screen = Rect.fromLTWH(0, 0, 360, 800);

Map<String, dynamic> _adminRow({String displayName = 'Admin', String photoUrl = ''}) => {
      'firebase_uid': _uid,
      'display_name': displayName,
      'username': 'admin',
      'photo_url': photoUrl,
      'country': 'Pakistan',
      'favorite_game': '',
      'bio': 'I am the developer',
      'game_uid': '',
      'in_game_name': '',
    };

/// Pumps the REAL CreateProfilePage at a real device size (360x800)
/// with a fixture profile row via the SupaDb.testFixtures seam.
/// Bounded pumps only (EmberDots animates forever); the fixture
/// _load completes within the first frames.
Future<void> _pumpPage(WidgetTester tester, {Map<String, dynamic>? profile}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  SupaDb.testFixtures = {
    'profiles': [profile ?? _adminRow()],
  };
  addTearDown(() => SupaDb.testFixtures = null);
  await tester.pumpWidget(
    const MaterialApp(home: CreateProfilePage(uid: _uid)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

/// Inclusive rect containment (Rect.contains is edge-exclusive on
/// right/bottom, and the badge sits exactly on the box edges).
bool _containsRect(Rect outer, Rect inner) =>
    inner.left >= outer.left && inner.top >= outer.top && inner.right <= outer.right && inner.bottom <= outer.bottom;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FIX 11 (a) — camera button geometry (real page, 360x800)', () {
    testWidgets('badge is 36x36, fully inside the avatar box and on screen', (tester) async {
      final errors = <FlutterErrorDetails>[];
      final oldOnError = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = oldOnError);
      await _pumpPage(tester);
      expect(errors, isEmpty);

      final avatarCenter = tester.getCenter(find.byType(CircleAvatar));
      // The visible avatar area: the 124x124 avatar box.
      final avatarBox = Rect.fromCenter(center: avatarCenter, width: 124, height: 124);
      final button = find.ancestor(of: find.byIcon(Icons.camera_alt), matching: find.byType(InkWell));
      expect(button, findsOneWidget);
      final buttonRect = tester.getRect(button);

      expect(buttonRect.size, const Size(36, 36));
      expect(_containsRect(avatarBox, buttonRect), isTrue, reason: 'badge must sit fully inside the 124px avatar box');
      expect(_containsRect(_screen, buttonRect), isTrue, reason: 'badge must be fully on screen (viewport clip cannot cut it)');
    });

    testWidgets('badge centre sits ON the ring, icon fully shown and centred', (tester) async {
      await _pumpPage(tester);
      final avatarCenter = tester.getCenter(find.byType(CircleAvatar));
      final button = find.ancestor(of: find.byIcon(Icons.camera_alt), matching: find.byType(InkWell));
      final buttonRect = tester.getRect(button);
      final iconRect = tester.getRect(find.byIcon(Icons.camera_alt));

      // Ring radius is 62 (124/2): the badge centre on the ring
      // reads as "seated on the ring edge", not hanging off it.
      expect((tester.getCenter(button) - avatarCenter).distance, closeTo(62, 4));
      // The camera glyph is fully inside the badge — never half-cut.
      expect(_containsRect(buttonRect, iconRect), isTrue, reason: 'camera icon must be fully inside the badge');
      expect((find.byIcon(Icons.camera_alt).evaluate().single.widget as Icon).size, 20);
      expect((tester.getCenter(find.byIcon(Icons.camera_alt)) - tester.getCenter(button)).distance, lessThan(1));
    });

    testWidgets('badge does not cover the initial letter', (tester) async {
      await _pumpPage(tester);
      final button = find.ancestor(of: find.byIcon(Icons.camera_alt), matching: find.byType(InkWell));
      expect(tester.getRect(button).overlaps(tester.getRect(find.text('A'))), isFalse);
    });

    testWidgets('tapping the camera button does not crash the page', (tester) async {
      await _pumpPage(tester);
      await tester.tap(find.byIcon(Icons.camera_alt));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('EDIT PROFILE'), findsOneWidget);
    });
  });

  group('FIX 11 (b) — saveProfilePhotoNow (test doubles, no live server)', () {
    test('saves immediately: update called once with photo_url, then verified', () async {
      final calls = <Map<String, dynamic>>[];
      var reads = 0;
      String stored = '';
      await saveProfilePhotoNow(
        uid: 'u1',
        url: 'https://i.ibb.co/x/photo.jpg',
        update: (uid, patch) async {
          calls.add({'uid': uid, ...patch});
          stored = patch['photo_url'] as String;
        },
        readBack: (uid) async {
          reads++;
          return {'photo_url': stored};
        },
      );
      expect(calls, hasLength(1));
      expect(calls.single['uid'], 'u1');
      expect(calls.single['photo_url'], 'https://i.ibb.co/x/photo.jpg');
      expect(reads, 1);
    });

    test('read-back mismatch throws PhotoSaveMismatchException — never fake success', () async {
      var updated = false;
      await expectLater(
        saveProfilePhotoNow(
          uid: 'u1',
          url: 'https://i.ibb.co/x/photo.jpg',
          update: (_, __) async => updated = true,
          // 0-row update: the write never landed.
          readBack: (_) async => {'photo_url': ''},
        ),
        throwsA(isA<PhotoSaveMismatchException>()),
      );
      // The save WAS attempted — the failure is honest, not skipped.
      expect(updated, isTrue);
    });

    test('update failure propagates and read-back never runs', () async {
      var reads = 0;
      await expectLater(
        saveProfilePhotoNow(
          uid: 'u1',
          url: 'https://i.ibb.co/x/photo.jpg',
          update: (_, __) async => throw Exception('network down'),
          readBack: (_) async {
            reads++;
            return {};
          },
        ),
        throwsA(isA<Exception>()),
      );
      expect(reads, 0);
    });

    test('empty URL throws before any update call', () async {
      var updates = 0;
      await expectLater(
        saveProfilePhotoNow(
          uid: 'u1',
          url: '',
          update: (_, __) async => updates++,
          readBack: (_) async => {},
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(updates, 0);
    });

    test('success invalidates the photo cache and bumps the refresh notifier', () async {
      PhotoCache.invalidate(_uid);
      SupaDb.testFixtures = {
        'profiles': [_adminRow(photoUrl: 'https://i.ibb.co/old.jpg')],
      };
      addTearDown(() => SupaDb.testFixtures = null);
      addTearDown(() => PhotoCache.invalidate(_uid));
      // Seed the cache with the OLD photo.
      expect(await PhotoCache.photo(_uid), 'https://i.ibb.co/old.jpg');
      // Server row now has the NEW photo (fixture swap = the write
      // landing) — but the cache still serves the old one.
      SupaDb.testFixtures = {
        'profiles': [_adminRow(photoUrl: 'https://i.ibb.co/new.jpg')],
      };
      expect(await PhotoCache.photo(_uid), 'https://i.ibb.co/old.jpg');

      final before = SupaDb.refreshNotifier.value;
      await saveProfilePhotoNow(
        uid: _uid,
        url: 'https://i.ibb.co/new.jpg',
        update: (_, __) async {},
        readBack: (_) async => {'photo_url': 'https://i.ibb.co/new.jpg'},
      );
      expect(SupaDb.refreshNotifier.value, before + 1);
      // Cache dropped: the next read re-fetches the new photo.
      expect(await PhotoCache.photo(_uid), 'https://i.ibb.co/new.jpg');
    });
  });

  group('FIX 11 (c) — editProfileInitial', () {
    test('normal name gives its first letter, uppercased', () {
      expect(editProfileInitial(displayName: 'Admin', username: 'admin'), 'A');
      expect(editProfileInitial(displayName: 'sameer', username: ''), 'S');
    });

    test('leading/trailing spaces are trimmed — never a blank letter', () {
      expect(editProfileInitial(displayName: '  Admin  ', username: 'admin'), 'A');
    });

    test('whitespace-only name falls back to the username initial', () {
      expect(editProfileInitial(displayName: '   ', username: 'admin'), 'A');
    });

    test('empty name and username give ?', () {
      expect(editProfileInitial(displayName: '', username: ''), '?');
    });
  });

  group('FIX 11 (c) — initial letter on the real page (360x800)', () {
    testWidgets('no photo URL -> gold initial letter, centred on the dark circle', (tester) async {
      await _pumpPage(tester);
      final letter = find.text('A');
      expect(letter, findsOneWidget);
      final text = tester.widget<Text>(letter);
      expect(text.style?.color, kGold);
      expect(text.style?.fontSize, 44);
      final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
      expect(avatar.backgroundColor, kField);
      // Real size, centred in the avatar — not a zero-size or
      // off-centre render.
      final letterRect = tester.getRect(letter);
      expect(letterRect.width, greaterThan(0));
      expect(letterRect.height, greaterThan(0));
      final avatarCenter = tester.getCenter(find.byType(CircleAvatar));
      expect((tester.getCenter(letter) - avatarCenter).distance, lessThan(6));
      // And the avatar widget itself got the empty URL.
      expect(tester.widget<ArenaCachedAvatar>(find.byType(ArenaCachedAvatar)).photoUrl, '');
    });

    testWidgets('dead photo URL still shows the initial letter', (tester) async {
      await _pumpPage(tester, profile: _adminRow(photoUrl: 'https://i.ibb.co/dead123/photo.jpg'));
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('display name with a leading space still shows A, never blank', (tester) async {
      await _pumpPage(tester, profile: _adminRow(displayName: ' Admin'));
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('light mode: letter stays readable (black on the light circle)', (tester) async {
      themeLightNotifier.value = true;
      addTearDown(() => themeLightNotifier.value = false);
      await _pumpPage(tester);
      final text = tester.widget<Text>(find.text('A'));
      expect(text.style?.color, Colors.black);
      expect(tester.widget<CircleAvatar>(find.byType(CircleAvatar)).backgroundColor, kField);
    });
  });
}
