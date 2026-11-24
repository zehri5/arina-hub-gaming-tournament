import 'package:protournament_user/utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Countries, regions, language + currency (ChatGPT blueprint §2;
/// backend guide §2 `countries` / `regions` tables).
///
/// Server columns (guide §2): `code`, `name`, `enabled`,
/// `default_currency`, `default_timezone`, `default_language`,
/// `created_at`. [Country.toMap] writes those keys; [Country.fromMap]
/// also accepts the app-side camelCase keys.

/// Currency symbols for the supported currencies. Used by
/// [Country.fromMap] (the server table stores the currency CODE only)
/// and by [RegionService.formatCurrency].
const Map<String, String> _currencySymbols = {
  'PKR': 'Rs',
  'SAR': 'SR',
  'AED': 'AED',
  'INR': '₹',
  'BDT': '৳',
  'GBP': '£',
  'USD': '\$',
  'EUR': '€',
  'TRY': '₺',
  'IDR': 'Rp',
  'MYR': 'RM',
};

class Country {
  /// ISO code, e.g. 'PK' — the value sent as `country_code`.
  final String code;
  final String name;

  /// ISO currency code, e.g. 'PKR' (guide §2 `default_currency`).
  final String currencyCode;

  /// Display symbol, e.g. 'Rs'. App-side only — the server table
  /// stores the currency code, not the symbol.
  final String currencySymbol;

  /// IANA timezone name, e.g. 'Asia/Karachi' (guide §2
  /// `default_timezone`). Every entry in [kSupportedCountries] uses
  /// a real IANA name.
  final String timezone;

  /// BCP-47 language codes, first = default (guide §2
  /// `default_language` is [languageCodes].first).
  final List<String> languageCodes;

  /// Super Admin can switch a country on/off (guide §2 `enabled`).
  final bool enabled;

  const Country({
    required this.code,
    required this.name,
    required this.currencyCode,
    required this.currencySymbol,
    required this.timezone,
    required this.languageCodes,
    this.enabled = true,
  });

  factory Country.fromMap(Map<String, dynamic> map) {
    final currency =
        (map['default_currency'] ?? map['currencyCode'] ?? '').toString();
    final langs = map['language_codes'];
    final List<String> languages;
    if (langs is List) {
      languages = langs.map((e) => e.toString()).toList();
    } else {
      final def =
          (map['default_language'] ?? map['languageCode'] ?? 'en').toString();
      languages = def == 'en' ? const ['en'] : [def, 'en'];
    }
    final symbol = map['currency_symbol']?.toString();
    return Country(
      code: (map['code'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      currencyCode: currency,
      currencySymbol: (symbol != null && symbol.isNotEmpty)
          ? symbol
          : (_currencySymbols[currency] ?? currency),
      timezone: (map['default_timezone'] ?? map['timezone'] ?? '').toString(),
      languageCodes: languages,
      enabled: map['enabled'] is bool ? map['enabled'] as bool : true,
    );
  }

  /// Keys are the guide's `countries` column names. `currencySymbol`
  /// is app-side and is not sent (the server derives display from
  /// the currency code).
  Map<String, dynamic> toMap() => {
        'code': code,
        'name': name,
        'enabled': enabled,
        'default_currency': currencyCode,
        'default_timezone': timezone,
        'default_language':
            languageCodes.isEmpty ? 'en' : languageCodes.first,
      };
}

/// Supported countries, Pakistan first (blueprint §2: launch region).
/// Timezones are real IANA names; currencies are the standard ISO
/// codes for each country.
const List<Country> kSupportedCountries = [
  Country(
      code: 'PK',
      name: 'Pakistan',
      currencyCode: 'PKR',
      currencySymbol: 'Rs',
      timezone: 'Asia/Karachi',
      languageCodes: ['en', 'ur']),
  Country(
      code: 'SA',
      name: 'Saudi Arabia',
      currencyCode: 'SAR',
      currencySymbol: 'SR',
      timezone: 'Asia/Riyadh',
      languageCodes: ['ar', 'en']),
  Country(
      code: 'AE',
      name: 'United Arab Emirates',
      currencyCode: 'AED',
      currencySymbol: 'AED',
      timezone: 'Asia/Dubai',
      languageCodes: ['ar', 'en']),
  Country(
      code: 'IN',
      name: 'India',
      currencyCode: 'INR',
      currencySymbol: '₹',
      timezone: 'Asia/Kolkata',
      languageCodes: ['en', 'hi']),
  Country(
      code: 'BD',
      name: 'Bangladesh',
      currencyCode: 'BDT',
      currencySymbol: '৳',
      timezone: 'Asia/Dhaka',
      languageCodes: ['bn', 'en']),
  Country(
      code: 'GB',
      name: 'United Kingdom',
      currencyCode: 'GBP',
      currencySymbol: '£',
      timezone: 'Europe/London',
      languageCodes: ['en']),
  Country(
      code: 'US',
      name: 'United States',
      currencyCode: 'USD',
      currencySymbol: '\$',
      timezone: 'America/New_York',
      languageCodes: ['en']),
  Country(
      code: 'DE',
      name: 'Germany',
      currencyCode: 'EUR',
      currencySymbol: '€',
      timezone: 'Europe/Berlin',
      languageCodes: ['de', 'en']),
  Country(
      code: 'FR',
      name: 'France',
      currencyCode: 'EUR',
      currencySymbol: '€',
      timezone: 'Europe/Paris',
      languageCodes: ['fr', 'en']),
  Country(
      code: 'TR',
      name: 'Turkey',
      currencyCode: 'TRY',
      currencySymbol: '₺',
      timezone: 'Europe/Istanbul',
      languageCodes: ['tr', 'en']),
  Country(
      code: 'ID',
      name: 'Indonesia',
      currencyCode: 'IDR',
      currencySymbol: 'Rp',
      timezone: 'Asia/Jakarta',
      languageCodes: ['id', 'en']),
  Country(
      code: 'MY',
      name: 'Malaysia',
      currencyCode: 'MYR',
      currencySymbol: 'RM',
      timezone: 'Asia/Kuala_Lumpur',
      languageCodes: ['ms', 'en']),
];

/// Selected country + app language, persisted in SharedPreferences.
///
/// LANGUAGE — REUSES THE EXISTING MECHANISM (no second store):
/// the app already persists the language in SharedPreferences key
/// `app_language` ('ur' = Roman Urdu, else English) — loaded once at
/// startup in main.dart (`langUrduNotifier.value = ...`) and written
/// by App Settings (pro_features.dart). [getLanguageCode] /
/// [setLanguageCode] read and write THAT SAME key, and
/// [setLanguageCode] also flips [langUrduNotifier] so `tr()` switches
/// immediately for screens built afterwards. Screens already on the
/// stack still need a restart to re-render (same caveat the existing
/// Settings screen states).
class RegionService {
  /// Selected-country key (platform namespace — new, no legacy key).
  static const String countryKey = 'platform.selected_country';

  /// Language key — THE EXISTING key from main.dart / App Settings.
  /// Do not rename it; a second key would split the language state.
  static const String languageKey = 'app_language';

  static const String defaultCountryCode = 'PK';
  static const String defaultLanguageCode = 'en';

  static Country countryFor(String code) {
    for (final c in kSupportedCountries) {
      if (c.code == code) return c;
    }
    return kSupportedCountries.first; // PK
  }

  static bool isKnownCountry(String code) =>
      kSupportedCountries.any((c) => c.code == code);

  static Future<String> getSelectedCountryCode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final code = prefs.getString(countryKey) ?? defaultCountryCode;
      return isKnownCountry(code) ? code : defaultCountryCode;
    } catch (_) {
      return defaultCountryCode;
    }
  }

  static Future<Country> getSelectedCountry() async =>
      countryFor(await getSelectedCountryCode());

  /// Persists the selection. Unknown codes are ignored (never stored).
  static Future<bool> setSelectedCountryCode(String code) async {
    if (!isKnownCountry(code)) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.setString(countryKey, code);
    } catch (_) {
      return false;
    }
  }

  static Future<String> getLanguageCode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final code = prefs.getString(languageKey) ?? defaultLanguageCode;
      return code == 'ur' ? 'ur' : 'en';
    } catch (_) {
      return defaultLanguageCode;
    }
  }

  /// Writes the EXISTING `app_language` key and flips
  /// `langUrduNotifier` so `tr()` switches at once for newly built
  /// screens. Only 'en' / 'ur' are accepted.
  static Future<bool> setLanguageCode(String code) async {
    final normalized = code == 'ur' ? 'ur' : 'en';
    try {
      final prefs = await SharedPreferences.getInstance();
      final ok = await prefs.setString(languageKey, normalized);
      if (ok) langUrduNotifier.value = normalized == 'ur';
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// `symbol + amount` — 0 decimals for PKR (and IDR, whose amounts
  /// are whole units in practice), 2 decimals for the rest.
  /// No thousands separators (no intl dependency in scope).
  static String formatCurrency(double amount, Country c) {
    final zeroDecimals = c.currencyCode == 'PKR' || c.currencyCode == 'IDR';
    final text =
        zeroDecimals ? amount.toStringAsFixed(0) : amount.toStringAsFixed(2);
    return '${c.currencySymbol} $text';
  }

  /// Display-only timezone label. LIMITATION (honest): without a
  /// timezone package the app cannot convert UTC into an arbitrary
  /// IANA zone, so this shows the UTC clock time plus the zone name,
  /// e.g. `14:30 UTC (Asia/Karachi)` — it does NOT claim to be the
  /// local time in that zone. True conversion needs the `timezone`
  /// package (a later workstream decision, not added here).
  static String formatInTimezone(DateTime utc, String tzName) {
    final t = utc.toUtc();
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$hh:$mm UTC ($tzName)';
  }
}
