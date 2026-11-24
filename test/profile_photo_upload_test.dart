// PROFILE PHOTO UPLOAD FIX (P-ALL-FIXES-A, 2026-11-20) — tests for the
// shared ImgBB helper used by ProfilePage._changePhoto.
//
// ROOT CAUSE (see P-A-REPORT.md): the visible photo comes only from a
// once-created profile stream that re-emits solely on a Supabase
// Realtime event — so a saved photo never appeared until an app
// restart, while the toast already claimed success. The stream
// resubscribe + read-back verification in _changePhoto need a live
// backend and can only be proven on the phone (final APK); what IS
// unit-testable here is the upload-response mapping that used to
// throw a raw FormatException on any non-JSON error body and gave no
// usable message. These tests pin that mapping: success returns the
// direct i.ibb.co URL, every failure throws a plain-language
// Exception the UI can toast honestly.
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/imgbb_service.dart';

void main() {
  group('ImgbbService.parseUploadResponse', () {
    test('success returns the direct image URL', () {
      const body =
          '{"success":true,"status":200,"data":{"id":"abc123","url":"https://i.ibb.co/abc123/photo.jpg","display_url":"https://i.ibb.co/abc123/photo.jpg"}}';
      expect(ImgbbService.parseUploadResponse(body), 'https://i.ibb.co/abc123/photo.jpg');
    });

    test('API error throws with the server message, not a raw body', () {
      const body = '{"success":false,"status":400,"error":{"message":"Invalid API key.","code":101}}';
      expect(
        () => ImgbbService.parseUploadResponse(body),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('Invalid API key'))),
      );
    });

    test('non-JSON error body throws a readable message, never FormatException', () {
      const body = '<html><body>413 Payload Too Large</body></html>';
      expect(
        () => ImgbbService.parseUploadResponse(body),
        throwsA(
          isA<Exception>().having((e) => e.toString(), 'message', contains('unreadable response')),
        ),
      );
    });

    test('success without a URL throws instead of returning an empty string', () {
      const body = '{"success":true,"status":200,"data":{}}';
      expect(
        () => ImgbbService.parseUploadResponse(body),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('no image URL'))),
      );
    });

    test('success with a non-object data field throws instead of crashing', () {
      const body = '{"success":true,"status":200,"data":"not-an-object"}';
      expect(() => ImgbbService.parseUploadResponse(body), throwsA(isA<Exception>()));
    });
  });
}
