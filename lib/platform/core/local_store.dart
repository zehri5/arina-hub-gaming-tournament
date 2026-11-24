import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Local persistence for platform features whose backend tables do
/// not exist yet (drafts, waitlist/check-in state, offline queues).
/// SharedPreferences-backed, keys namespaced `platform.<area>.<id>`.
///
/// NOTHING HERE EVER THROWS: every method catches its own errors
/// and returns a safe default (false / null / empty list), so a
/// corrupt or missing local value can never crash a screen. Callers
/// must treat a `false` return as "not saved" and a `null`/empty
/// load as "nothing stored".
class PlatformLocalStore {
  static String _key(String area, String id) => 'platform.$area.$id';

  /// Saves a JSON draft (e.g. an unfinished tournament builder
  /// form) under `platform.<area>.<id>`.
  static Future<bool> saveDraft(
      String area, String id, Map<String, dynamic> json) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.setString(_key(area, id), jsonEncode(json));
    } catch (_) {
      return false;
    }
  }

  /// Loads a draft, or null when nothing is stored / stored value
  /// is not a JSON object / storage failed.
  static Future<Map<String, dynamic>?> loadDraft(
      String area, String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(area, id));
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> deleteDraft(String area, String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.remove(_key(area, id));
    } catch (_) {
      return false;
    }
  }

  /// Saves a list of JSON objects (e.g. waitlist entries or
  /// check-in state) under `platform.<area>.<id>`.
  static Future<bool> saveList(
      String area, String id, List<Map<String, dynamic>> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.setString(_key(area, id), jsonEncode(items));
    } catch (_) {
      return false;
    }
  }

  /// Loads a list, or [] when nothing is stored / stored value is
  /// not a JSON list / storage failed. Non-object entries are
  /// skipped.
  static Future<List<Map<String, dynamic>>> loadList(
      String area, String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(area, id));
      if (raw == null) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final out = <Map<String, dynamic>>[];
      for (final item in decoded) {
        if (item is Map) out.add(Map<String, dynamic>.from(item));
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  static Future<bool> deleteList(String area, String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.remove(_key(area, id));
    } catch (_) {
      return false;
    }
  }
}
