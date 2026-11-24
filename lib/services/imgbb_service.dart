import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../config.dart';
import 'supabase_db.dart';

/// ImgBB upload — same endpoint/flow as the HTML app.
/// The key is read at runtime from app_settings `imgbb_api_key` first,
/// else [AppConfig.imgbbApiKey] (empty placeholder). NEVER hardcoded.
/// While empty, uploads show a clear message instead of failing silently.
class ImgbbService {
  static Future<String> _apiKey() async {
    try {
      final settings = await SupaDb.getAppSettings();
      final fromSettings = SupaDb.strOf(settings['imgbbApiKey'], SupaDb.strOf(settings['imgbb_api_key']));
      if (fromSettings.isNotEmpty) return fromSettings;
    } catch (_) {}
    return AppConfig.imgbbApiKey;
  }

  /// Pure response parser, split out of [uploadImage] so the success /
  /// failure mapping is unit-testable without a live backend or key.
  /// Success returns the direct image URL (`data.url`, an i.ibb.co
  /// link). Anything else throws a plain-language Exception — never a
  /// raw FormatException from a non-JSON error body (proxy / 413 page).
  static String parseUploadResponse(String body) {
    Map<String, dynamic> data;
    try {
      data = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('Image upload failed: server returned an unreadable response.');
    }
    if (data['success'] == true) {
      final dataMap = data['data'];
      final url = SupaDb.strOf(dataMap is Map ? dataMap['url'] : null);
      if (url.isEmpty) {
        throw Exception('Image upload failed: server returned no image URL.');
      }
      return url;
    }
    final err = data['error'] is Map ? (data['error'] as Map)['message'] : 'Unknown error';
    throw Exception('Image upload failed: $err');
  }

  static Future<String> uploadImage(File file) async {
    final key = await _apiKey();
    if (key.isEmpty) {
      throw Exception('ImgBB API key is not configured. Ask the admin to set app_settings imgbb_api_key.');
    }
    final bytes = await file.readAsBytes();
    final uri = Uri.parse('https://api.imgbb.com/1/upload?key=$key');
    final req = http.MultipartRequest('POST', uri)
      ..files.add(http.MultipartFile.fromBytes('image', bytes, filename: file.path.split('/').last));
    // P-ALL-FIXES-A (2026-11-20, profile photo): no timeout before —
    // on a slow connection the upload could hang forever, leaving the
    // caller stuck in its busy state with no feedback at all.
    // 2026-11-20: 60 s -> 120 s. The user's connection runs ~7 KB/s,
    // so even a compressed ~150 KB photo needs ~25 s (and a dip to
    // 3 KB/s needs ~50 s); 60 s left no margin. Callers compress at
    // pick time (85% / 1024 px), so uploads stay small — the longer
    // timeout only covers slow-network variance, and a failure still
    // surfaces as a normal error the caller toasts.
    final streamed = await req.send().timeout(const Duration(seconds: 120));
    final body = await streamed.stream.bytesToString().timeout(const Duration(seconds: 30));
    // P-ALL-FIXES-A: a non-200 (e.g. 400 bad key, 413 too large) still
    // carries a JSON error body — parse it for the message instead of
    // treating the body as a success payload.
    if (streamed.statusCode != 200) {
      throw parseUploadResponse(body);
    }
    return parseUploadResponse(body);
  }
}
