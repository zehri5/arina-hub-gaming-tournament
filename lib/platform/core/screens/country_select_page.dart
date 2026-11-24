import 'package:flutter/material.dart';
import 'package:protournament_user/platform/core/regions.dart';
import 'package:protournament_user/utils.dart';

/// Country picker (blueprint §2; backend guide §2 `countries` table).
/// Lists [kSupportedCountries] as MockupCard rows; tap to select and
/// persist via [RegionService]. Shows the current selection.
///
/// NOT wired into main.dart navigation — the coordinator wires entry
/// points. Push it with:
/// `Navigator.push(context, MaterialPageRoute(builder: (_) =>
/// const CountrySelectPage()))`.
class CountrySelectPage extends StatefulWidget {
  const CountrySelectPage({super.key});

  @override
  State<CountrySelectPage> createState() => _CountrySelectPageState();
}

class _CountrySelectPageState extends State<CountrySelectPage> {
  String _selectedCode = RegionService.defaultCountryCode;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final code = await RegionService.getSelectedCountryCode();
    if (!mounted) return;
    setState(() {
      _selectedCode = code;
      _loading = false;
    });
  }

  Future<void> _select(String code) async {
    if (code == _selectedCode) return;
    final ok = await RegionService.setSelectedCountryCode(code);
    if (!mounted) return;
    if (ok) {
      setState(() => _selectedCode = code);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                tr('Could not save the country. Try again.',
                    'Mulk save nahi ho saka. Dobara koshish karen.'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = RegionService.countryFor(_selectedCode);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        iconTheme: IconThemeData(color: kGold),
        title: Text(tr('Select Country', 'Mulk muntakhib karen'),
            style: TextStyle(color: kText)),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: kGold))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: kSupportedCountries.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      tr('Current: ${selected.name}',
                          'Maujooda: ${selected.name}'),
                      style: TextStyle(
                          color: kMuted,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                    ),
                  );
                }
                final country = kSupportedCountries[index - 1];
                final isSelected = country.code == _selectedCode;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: MockupCard(
                    // List rows: shines park at their rest position
                    // (documented MockupCard list-row pattern).
                    animate: false,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    child: InkWell(
                      onTap: () => _select(country.code),
                      borderRadius: BorderRadius.circular(12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(country.name,
                                    style: TextStyle(
                                        color: kText,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(height: 2),
                                Text(
                                  '${country.currencyCode} '
                                  '(${country.currencySymbol})  ·  '
                                  '${country.timezone}',
                                  style: TextStyle(
                                      color: kMuted, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                          if (isSelected)
                            Icon(Icons.check_circle,
                                color: kGold, size: 22)
                          else
                            Icon(Icons.circle_outlined,
                                color: kMuted, size: 22),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
