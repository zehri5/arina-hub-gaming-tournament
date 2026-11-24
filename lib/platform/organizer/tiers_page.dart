import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:protournament_user/platform/core/organization.dart';
import 'package:protournament_user/platform/organizer/organizer_service.dart';
import 'package:protournament_user/utils.dart';

/// SaaS tiers for organizers (ChatGPT blueprint §7; backend guide §4
/// `organizations.tier` + §7 `subscriptions`).
///
/// Starter / Professional / Enterprise with a feature list per tier.
/// NO prices anywhere — pricing is decided at launch (guide §7 gap #6
/// + §10 open decision). NO payment collection, NO billing actions:
/// billing stays OFF until legal approval (guide §1.6). The signed-in
/// user's current tier (if they own an organization) is highlighted.
///
/// Feature lists are indicative platform capabilities, not a contract
/// — the backend `subscriptions` table + the launch pricing decision
/// settle the final entitlements.
class OrganizerTiersPage extends StatefulWidget {
  const OrganizerTiersPage({super.key});

  @override
  State<OrganizerTiersPage> createState() => _OrganizerTiersPageState();
}

/// Indicative features per tier (no prices, no payment promises).
const Map<OrganizationTier, List<String>> _tierFeatures = {
  OrganizationTier.starter: [
    'Run tournaments on the platform',
    'Public organizer page',
    'Staff & referee invites',
    'Result verification for your tournaments',
  ],
  OrganizationTier.professional: [
    'Everything in Starter',
    'More tournaments per season',
    'Custom branding (logo + page)',
    'Tournament reports & stats',
    'Priority support',
  ],
  OrganizationTier.enterprise: [
    'Everything in Professional',
    'Unlimited tournaments',
    'Multi-country tournaments',
    'Dedicated support',
    'Sponsor campaign slots',
  ],
};

/// Roman Urdu feature text, same order as [_tierFeatures].
const Map<OrganizationTier, List<String>> _tierFeaturesUr = {
  OrganizationTier.starter: [
    'Platform par tournaments chalayen',
    'Public organizer page',
    'Staff aur referee invites',
    'Apne tournaments ke results verify karen',
  ],
  OrganizationTier.professional: [
    'Starter ki sab cheezein',
    'Har season mein zyada tournaments',
    'Custom branding (logo + page)',
    'Tournament reports aur stats',
    'Priority support',
  ],
  OrganizationTier.enterprise: [
    'Professional ki sab cheezein',
    'Unlimited tournaments',
    'Multi-country tournaments',
    'Dedicated support',
    'Sponsor campaign slots',
  ],
};

class _OrganizerTiersPageState extends State<OrganizerTiersPage> {
  final _service = const OrganizerService();
  OrganizationTier? _currentTier;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    OrganizationTier? tier;
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isNotEmpty) {
      final org = await _service.getMyOrganization(uid);
      tier = org?.tier;
    }
    if (!mounted) return;
    setState(() {
      _currentTier = tier;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        iconTheme: IconThemeData(color: kGold),
        title: Text(tr('Organizer Tiers', 'Organizer Tiers'),
            style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: kGold))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                MockupCard(
                  animate: false,
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: kGold, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          tr('Pricing will be decided at launch. Billing stays off until legal approval — no payment is collected on this screen.',
                              'Pricing launch par decide hogi. Billing legal approval tak band hai — is screen par koi payment nahi li jati.'),
                          style: TextStyle(color: kMuted, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                for (final tier in OrganizationTier.values)
                  _tierCard(tier, tier == _currentTier),
              ],
            ),
    );
  }

  Widget _tierCard(OrganizationTier tier, bool isCurrent) {
    final features = isUrdu
        ? _tierFeaturesUr[tier]!
        : _tierFeatures[tier]!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: MockupCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(tier.label,
                      style: TextStyle(
                          color: kText,
                          fontSize: 20,
                          fontWeight: FontWeight.bold)),
                ),
                if (isCurrent)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: kGold,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(tr('Current tier', 'Maujooda tier'),
                        style: const TextStyle(
                            color: Colors.black,
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(tier.description,
                style: TextStyle(color: kMuted, fontSize: 13)),
            const SizedBox(height: 12),
            for (final f in features)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.check, color: kGold, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(f,
                            style: TextStyle(color: kText, fontSize: 14))),
                  ],
                ),
              ),
            if (tier != OrganizationTier.starter) ...[
              const SizedBox(height: 8),
              Text(
                tr('Available at launch — your tier can be upgraded by Super Admin later.',
                    'Launch par available — aap ka tier baad mein Super Admin upgrade kar sakta hai.'),
                style: TextStyle(color: kMuted, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
