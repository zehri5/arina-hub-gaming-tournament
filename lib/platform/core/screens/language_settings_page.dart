import 'package:flutter/material.dart';
import 'package:protournament_user/platform/core/regions.dart';
import 'package:protournament_user/utils.dart';

/// Language settings — English / Roman Urdu (blueprint §2).
///
/// Persists via [RegionService.setLanguageCode], which writes the
/// EXISTING `app_language` SharedPreferences key (same key main.dart
/// loads at startup and App Settings writes) and flips
/// `langUrduNotifier`, so `tr()` switches at once for screens built
/// afterwards. Screens already on the stack need an app restart to
/// re-render — the note below says so honestly.
///
/// NOT wired into main.dart navigation — the coordinator wires entry
/// points. Push it with:
/// `Navigator.push(context, MaterialPageRoute(builder: (_) =>
/// const LanguageSettingsPage()))`.
class LanguageSettingsPage extends StatefulWidget {
  const LanguageSettingsPage({super.key});

  @override
  State<LanguageSettingsPage> createState() => _LanguageSettingsPageState();
}

class _LanguageSettingsPageState extends State<LanguageSettingsPage> {
  String _language = RegionService.defaultLanguageCode;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final code = await RegionService.getLanguageCode();
    if (!mounted) return;
    setState(() {
      _language = code;
      _loading = false;
    });
  }

  Future<void> _select(String code) async {
    if (code == _language) return;
    final ok = await RegionService.setLanguageCode(code);
    if (!mounted) return;
    if (ok) {
      setState(() => _language = code);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                tr('Could not save the language. Try again.',
                    'Language save nahi ho saki. Dobara koshish karen.'))),
      );
    }
  }

  Widget _option({
    required String code,
    required String title,
    required String subtitle,
  }) {
    final selected = _language == code;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: MockupCard(
        // List rows: shines park at their rest position (documented
        // MockupCard list-row pattern).
        animate: false,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: InkWell(
          onTap: () => _select(code),
          borderRadius: BorderRadius.circular(12),
          child: Row(
            children: [
              // Group value + onChanged live on the RadioGroup ancestor
              // (Radio's own groupValue/onChanged are deprecated).
              Radio<String>(
                value: code,
                activeColor: kGold,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: kText,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(color: kMuted, fontSize: 12)),
                  ],
                ),
              ),
              if (selected) Icon(Icons.check_circle, color: kGold, size: 22),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        iconTheme: IconThemeData(color: kGold),
        title: Text(tr('Language', 'Language'),
            style: TextStyle(color: kText)),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: kGold))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                RadioGroup<String>(
                  groupValue: _language,
                  onChanged: (v) {
                    if (v != null) _select(v);
                  },
                  child: Column(
                    children: [
                      _option(
                        code: 'en',
                        title: 'English',
                        subtitle: tr('App in English', 'App English mein'),
                      ),
                      _option(
                        code: 'ur',
                        title: 'Urdu (Roman)',
                        subtitle:
                            tr('App in Roman Urdu', 'App Roman Urdu mein'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                MockupCard(
                  animate: false,
                  child: Text(
                    tr(
                        'Applies app-wide. Some screens already open may need an app restart to switch.',
                        'Poori app par lagoo hota hai. Pehle se khuli kuch screens par tabdeeli ke liye app restart karna par sakta hai.'),
                    style: TextStyle(color: kMuted, fontSize: 13),
                  ),
                ),
              ],
            ),
    );
  }
}
