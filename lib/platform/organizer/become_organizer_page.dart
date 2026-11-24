import 'package:flutter/material.dart';
import 'package:protournament_user/platform/core/local_store.dart';
import 'package:protournament_user/platform/core/organization.dart';
import 'package:protournament_user/platform/core/regions.dart';
import 'package:protournament_user/platform/organizer/organizer_dashboard_page.dart';
import 'package:protournament_user/platform/organizer/organizer_service.dart';
import 'package:protournament_user/utils.dart';

/// "Become an Organizer" — the 12-step application wizard (ChatGPT
/// blueprint §7; backend guide §7 `organizer_applications`).
///
/// Steps (12): 1 intro · 2 organization name · 3 logo · 4 description ·
/// 5 country · 6 contact person · 7 contact email/phone · 8 verification
/// info · 9 platform rules · 10 tier (Starter — every organizer starts
/// here) · 11 review · 12 submit (success state, shown after submit).
///
/// The application itself is saved via [OrganizerService] (local store
/// until the `organizer_applications` table lands). Contact +
/// verification info have NO columns in the guide's table, so they are
/// kept as a local draft (`platform.organizer.application_extra.<uid>`)
/// next to the application and are noted as such in the report — the
/// backend adds the columns, or the fields stay draft-only.
///
/// When an application already exists, the wizard is replaced by a
/// status view (applied / under review / approved / rejected + reason);
/// a rejected applicant may apply again (the new application replaces
/// the old row), and an approved organizer gets a link to the dashboard.
///
/// NOT wired into main.dart navigation — the coordinator wires the
/// entry point. Push it with:
/// `Navigator.push(context, MaterialPageRoute(builder: (_) =>
/// BecomeOrganizerPage(uid: uid)))`.
class BecomeOrganizerPage extends StatefulWidget {
  const BecomeOrganizerPage({super.key, required this.uid});
  final String uid;

  @override
  State<BecomeOrganizerPage> createState() => _BecomeOrganizerPageState();
}

class _BecomeOrganizerPageState extends State<BecomeOrganizerPage> {
  static const int _totalSteps = 12;
  static const String _extraArea = OrganizerService.area;

  static String _extraKey(String uid) => 'application_extra.$uid';

  final _service = const OrganizerService();

  bool _loading = true;
  bool _submitting = false;
  bool _submitted = false;
  OrganizerApplication? _existing;
  Organization? _myOrg;

  // Wizard state (steps are 0-based; step 11 = review, submit from there).
  int _step = 0;
  final _nameCtrl = TextEditingController();
  final _logoCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  String _countryCode = RegionService.defaultCountryCode;
  final _contactNameCtrl = TextEditingController();
  final _contactInfoCtrl = TextEditingController();
  final _verificationCtrl = TextEditingController();
  bool _rulesAgreed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _logoCtrl.dispose();
    _descCtrl.dispose();
    _contactNameCtrl.dispose();
    _contactInfoCtrl.dispose();
    _verificationCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final app = await _service.getMyApplication(widget.uid);
    Organization? org;
    if (app != null &&
        app.status == OrganizerApplicationStatus.approved) {
      org = await _service.getMyOrganization(widget.uid);
    }
    Map<String, dynamic>? extra;
    if (app != null) {
      extra = await PlatformLocalStore.loadDraft(
          _extraArea, _extraKey(widget.uid));
    }
    if (!mounted) return;
    setState(() {
      _existing = app;
      _myOrg = org;
      if (app != null) {
        _nameCtrl.text = app.orgName;
        _logoCtrl.text = app.logoUrl;
        _descCtrl.text = app.description;
        _countryCode = app.countryCode;
        _contactNameCtrl.text = (extra?['contact_name'] ?? '').toString();
        _contactInfoCtrl.text = (extra?['contact_info'] ?? '').toString();
        _verificationCtrl.text =
            (extra?['verification_info'] ?? '').toString();
      }
      _loading = false;
    });
  }

  OrganizerApplication get _draft => OrganizerApplication(
        id: _existing?.id ??
            'app_${widget.uid}_${DateTime.now().millisecondsSinceEpoch}',
        orgName: _nameCtrl.text.trim(),
        logoUrl: _logoCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        countryCode: _countryCode,
        applicantUid: widget.uid,
        status: OrganizerApplicationStatus.pending,
        submittedAt: DateTime.now().toUtc(),
      );

  /// Per-step validation. Returns an error message or null.
  String? _stepError(int step) {
    switch (step) {
      case 1:
        if (_nameCtrl.text.trim().isEmpty) {
          return tr('Organization name is required.',
              'Organization ka naam zaroori hai.');
        }
        return null;
      case 4:
        if (_countryCode.trim().isEmpty) {
          return tr('Country is required.', 'Mulk zaroori hai.');
        }
        return null;
      case 5:
        if (_contactNameCtrl.text.trim().isEmpty) {
          return tr('Contact person name is required.',
              'Rabta karne wale ka naam zaroori hai.');
        }
        return null;
      case 8:
        if (!_rulesAgreed) {
          return tr('Please accept the platform rules to continue.',
              'Aage barhne ke liye platform rules accept karen.');
        }
        return null;
      default:
        return null;
    }
  }

  void _next() {
    final err = _stepError(_step);
    if (err != null) {
      toast(context, err);
      return;
    }
    if (_step < 10) {
      setState(() => _step++);
    }
  }

  void _back() {
    if (_step > 0) setState(() => _step--);
  }

  Future<void> _submit() async {
    final errors = OrganizerService.validateApplication(_draft);
    final stepErr = _stepError(8);
    if (errors.isNotEmpty) {
      toast(context, errors.first);
      return;
    }
    if (stepErr != null) {
      toast(context, stepErr);
      return;
    }
    setState(() => _submitting = true);
    final ok = await _service.saveApplication(_draft);
    await PlatformLocalStore.saveDraft(_extraArea, _extraKey(widget.uid), {
      'contact_name': _contactNameCtrl.text.trim(),
      'contact_info': _contactInfoCtrl.text.trim(),
      'verification_info': _verificationCtrl.text.trim(),
    });
    if (!mounted) return;
    setState(() => _submitting = false);
    if (!ok) {
      toast(context,
          tr('Application could not be saved. Try again.', 'Application save nahi ho saki. Dobara koshish karen.'));
      return;
    }
    setState(() {
      _submitted = true;
      _existing = _draft;
    });
  }

  void _applyAgain() {
    setState(() {
      _existing = null;
      _submitted = false;
      _step = 0;
      _rulesAgreed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        iconTheme: IconThemeData(color: kGold),
        title: Text(tr('Become an Organizer', 'Organizer Banen'),
            style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: kGold))
          : _submitted
              ? _successView()
              : _existing != null
                  ? _statusView(_existing!)
                  : _wizardView(),
    );
  }

  Widget _successView() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        MockupCard(
          child: Column(
            children: [
              Icon(Icons.check_circle, color: kGold, size: 56),
              const SizedBox(height: 16),
              Text(tr('Application submitted', 'Application bhej di gayi'),
                  style: TextStyle(
                      color: kText,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                tr('Application submitted — Super Admin will review it. '
                    'You will see the decision here.',
                    'Application bhej di gayi — Super Admin is ka review karega. '
                    'Faisla yahin nazar aayega.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: kMuted, fontSize: 14),
              ),
              const SizedBox(height: 16),
              Text(tr('Step 12 of 12 — done', 'Step 12 of 12 — mukammal'),
                  style: TextStyle(color: kGold, fontSize: 13)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _statusView(OrganizerApplication app) {
    final isRejected = app.status == OrganizerApplicationStatus.rejected;
    final isApproved = app.status == OrganizerApplicationStatus.approved;
    final statusColor = isApproved
        ? const Color(0xFF00F5A0)
        : isRejected
            ? const Color(0xFFFF3B30)
            : kGold;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        MockupCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(app.orgName,
                        style: TextStyle(
                            color: kText,
                            fontSize: 20,
                            fontWeight: FontWeight.bold)),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: statusColor),
                    ),
                    child: Text(app.status.label,
                        style: TextStyle(
                            color: statusColor,
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (app.description.isNotEmpty)
                Text(app.description, style: TextStyle(color: kMuted)),
              const SizedBox(height: 8),
              Text(
                '${RegionService.countryFor(app.countryCode).name} · '
                '${tr('Applied', 'Apply kiya')}: ${_dateLabel(app.submittedAt)}',
                style: TextStyle(color: kMuted, fontSize: 12),
              ),
              if (isRejected && app.reviewNote.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF3B30).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${tr('Reason', 'Wajah')}: ${app.reviewNote}',
                    style: const TextStyle(
                        color: Color(0xFFFF3B30), fontSize: 13),
                  ),
                ),
              ],
              if (isApproved) ...[
                const SizedBox(height: 12),
                Text(
                  tr('Your organization is active. You can now run tournaments.',
                      'Aap ki organization active hai. Ab aap tournaments chala sakte hain.'),
                  style: TextStyle(color: kMuted, fontSize: 13),
                ),
              ],
              if (!isApproved && !isRejected) ...[
                const SizedBox(height: 12),
                Text(
                  tr('Super Admin is reviewing your application. '
                      'You will see the decision here.',
                      'Super Admin aap ki application ka review kar raha hai. '
                      'Faisla yahin nazar aayega.'),
                  style: TextStyle(color: kMuted, fontSize: 13),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (isRejected)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _applyAgain,
              style: ElevatedButton.styleFrom(
                backgroundColor: kGold,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(tr('Apply again', 'Dobara apply karen'),
                  style: const TextStyle(
                      color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ),
        if (isApproved && _myOrg != null)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        OrganizerDashboardPage(organizationId: _myOrg!.id)),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: kGold,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(tr('Open organizer dashboard', 'Organizer dashboard kholen'),
                  style: const TextStyle(
                      color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ),
      ],
    );
  }

  Widget _wizardView() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (_step + 1) / _totalSteps,
                    backgroundColor: kMuted.withValues(alpha: 0.25),
                    valueColor: AlwaysStoppedAnimation<Color>(kGold),
                    minHeight: 6,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                tr('Step ${_step + 1} of $_totalSteps',
                    'Step ${_step + 1} / $_totalSteps'),
                style: TextStyle(color: kMuted, fontSize: 12),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              MockupCard(child: _stepBody()),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(
            children: [
              if (_step > 0)
                Expanded(
                  child: OutlinedButton(
                    onPressed: _back,
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: kMuted),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text(tr('Back', 'Peeche'),
                        style: TextStyle(color: kText)),
                  ),
                ),
              if (_step > 0) const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _submitting
                      ? null
                      : _step == 10
                          ? _submit
                          : _next,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kGold,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: _submitting
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                              color: Colors.black, strokeWidth: 2))
                      : Text(
                          _step == 10
                              ? tr('Submit application', 'Application bhej dein')
                              : tr('Next', 'Aage'),
                          style: const TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stepBody() {
    switch (_step) {
      case 0:
        return _introStep();
      case 1:
        return _fieldStep(
          title: tr('Organization name', 'Organization ka naam'),
          hint: tr('e.g. Quetta Esports Club', 'masalan Quetta Esports Club'),
          controller: _nameCtrl,
          helper: tr('This name appears on your public organizer page and on every tournament you run.',
              'Ye naam aap ke public organizer page aur har tournament par nazar aayega.'),
        );
      case 2:
        return _fieldStep(
          title: tr('Logo (image link)', 'Logo (tasveer ka link)'),
          hint: 'https://…',
          controller: _logoCtrl,
          helper: tr('Optional — a direct link to your logo image. You can change it later from the dashboard.',
              'Optional — apne logo ki tasveer ka direct link. Baad mein dashboard se badal sakte hain.'),
        );
      case 3:
        return _fieldStep(
          title: tr('Description', 'Tafseel'),
          hint: tr('What does your organization do?', 'Aap ki organization kya karti hai?'),
          controller: _descCtrl,
          helper: tr('Optional — shown on your public organizer page.',
              'Optional — aap ke public organizer page par dikhai jayegi.'),
          maxLines: 4,
        );
      case 4:
        return _countryStep();
      case 5:
        return _fieldStep(
          title: tr('Contact person', 'Rabta karne wala'),
          hint: tr('Full name', 'Poora naam'),
          controller: _contactNameCtrl,
          helper: tr('The person Super Admin can contact about this application.',
              'Wo shakhs jis se Super Admin is application ke baare mein rabta kar sakta hai.'),
        );
      case 6:
        return _fieldStep(
          title: tr('Contact email / phone', 'Email / phone number'),
          hint: 'name@example.com / 03xx-xxxxxxx',
          controller: _contactInfoCtrl,
          helper: tr('Optional — how Super Admin reaches you.',
              'Optional — Super Admin aap se kis tarah rabta kare.'),
        );
      case 7:
        return _fieldStep(
          title: tr('Verification info', 'Verification maloomat'),
          hint: tr('Links to your pages, past tournaments, anything that proves your organization is real.',
              'Apne pages ke links, pehle tournaments — kuch bhi jo sabit kare ke organization asli hai.'),
          controller: _verificationCtrl,
          helper: tr('Optional — helps Super Admin approve faster.',
              'Optional — Super Admin ko jaldi approve karne mein madad milti hai.'),
          maxLines: 4,
        );
      case 8:
        return _rulesStep();
      case 9:
        return _tierStep();
      case 10:
      default:
        return _reviewStep();
    }
  }

  Widget _stepTitle(String title, String helper) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: TextStyle(
                color: kText, fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text(helper, style: TextStyle(color: kMuted, fontSize: 13)),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _introStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepTitle(
          tr('Run your own tournaments', 'Apne tournaments chalayen'),
          tr('Organizers create tournaments, invite staff and referees, verify results and build their own community — on one global platform.',
              'Organizers tournaments banate hain, staff aur referees bulate hain, results verify karte hain aur apni community banate hain — ek global platform par.'),
        ),
        _introRow(Icons.business,
            tr('Your own organization page', 'Aap ka apna organization page')),
        _introRow(Icons.group,
            tr('Staff & referee invites', 'Staff aur referee invites')),
        _introRow(Icons.emoji_events,
            tr('Create and manage tournaments', 'Tournaments banayen aur chalayen')),
        _introRow(Icons.verified_user,
            tr('Super Admin reviews every application', 'Har application ka Super Admin review karta hai')),
        const SizedBox(height: 12),
        Text(
          tr('Approval usually takes a few days. You will see the decision here.',
              'Approval mein aam tor par kuch din lagte hain. Faisla yahin nazar aayega.'),
          style: TextStyle(color: kMuted, fontSize: 12),
        ),
      ],
    );
  }

  Widget _introRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, color: kGold, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(color: kText, fontSize: 14))),
        ],
      ),
    );
  }

  Widget _fieldStep({
    required String title,
    required String hint,
    required TextEditingController controller,
    required String helper,
    int maxLines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepTitle(title, helper),
        TextField(
          controller: controller,
          maxLines: maxLines,
          style: TextStyle(color: kText),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: kMuted),
            filled: true,
            fillColor: kBg,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: kMuted.withValues(alpha: 0.4))),
          ),
        ),
      ],
    );
  }

  Widget _countryStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepTitle(
          tr('Country', 'Mulk'),
          tr('Your organization’s home country. Tournaments you run default to this country.',
              'Aap ki organization ka mulk. Aap ke tournaments default isi mulk ke honge.'),
        ),
        for (final c in kSupportedCountries)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: InkWell(
              onTap: () => setState(() => _countryCode = c.code),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  color: c.code == _countryCode
                      ? kGold.withValues(alpha: 0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: c.code == _countryCode
                          ? kGold
                          : kMuted.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(c.name,
                          style: TextStyle(
                              color: kText,
                              fontWeight: c.code == _countryCode
                                  ? FontWeight.bold
                                  : FontWeight.normal)),
                    ),
                    Text(c.currencyCode,
                        style: TextStyle(color: kMuted, fontSize: 12)),
                    const SizedBox(width: 8),
                    Icon(
                      c.code == _countryCode
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      color: c.code == _countryCode ? kGold : kMuted,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _rulesStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepTitle(
          tr('Platform rules', 'Platform rules'),
          tr('Organizers keep the platform fair. Please read and accept.',
              'Organizers platform ko fair rakhte hain. Parh kar accept karen.'),
        ),
        _introRow(Icons.gavel,
            tr('Verify results honestly — only real match outcomes count.',
                'Results imaandaari se verify karen — sirf asli match outcomes count hote hain.')),
        _introRow(Icons.shield,
            tr('No fake tournaments, no fake players.',
                'Naqli tournaments ya naqli players nahi.')),
        _introRow(Icons.money_off,
            tr('Paid entry and billing stay off until the platform approves them.',
                'Paid entry aur billing tab tak band rehti hai jab tak platform approve na kare.')),
        const SizedBox(height: 8),
        InkWell(
          onTap: () => setState(() => _rulesAgreed = !_rulesAgreed),
          borderRadius: BorderRadius.circular(10),
          child: Row(
            children: [
              Checkbox(
                value: _rulesAgreed,
                activeColor: kGold,
                checkColor: Colors.black,
                onChanged: (v) => setState(() => _rulesAgreed = v ?? false),
              ),
              Expanded(
                child: Text(
                  tr('I accept the platform rules for organizers.',
                      'Main organizers ke liye platform rules accept karta hoon.'),
                  style: TextStyle(color: kText, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tierStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepTitle(
          tr('Your tier: Starter', 'Aap ka tier: Starter'),
          tr('Every new organizer starts on Starter. Higher tiers unlock more tournaments, branding and reports — pricing will be decided at launch.',
              'Har naya organizer Starter se shuru karta hai. Oonche tiers mein zyada tournaments, branding aur reports milti hain — pricing launch par decide hogi.'),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: kGold.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kGold),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(OrganizationTier.starter.label,
                  style: TextStyle(
                      color: kGold,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(OrganizationTier.starter.description,
                  style: TextStyle(color: kText, fontSize: 13)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _reviewStep() {
    final rows = <(String, String)>[
      (tr('Organization', 'Organization'), _nameCtrl.text.trim()),
      (tr('Logo', 'Logo'),
          _logoCtrl.text.trim().isEmpty ? '—' : _logoCtrl.text.trim()),
      (tr('Description', 'Tafseel'),
          _descCtrl.text.trim().isEmpty ? '—' : _descCtrl.text.trim()),
      (tr('Country', 'Mulk'),
          RegionService.countryFor(_countryCode).name),
      (tr('Contact person', 'Rabta karne wala'),
          _contactNameCtrl.text.trim()),
      (tr('Contact email / phone', 'Email / phone'),
          _contactInfoCtrl.text.trim().isEmpty
              ? '—'
              : _contactInfoCtrl.text.trim()),
      (tr('Verification info', 'Verification maloomat'),
          _verificationCtrl.text.trim().isEmpty
              ? '—'
              : _verificationCtrl.text.trim()),
      (tr('Tier', 'Tier'), OrganizationTier.starter.label),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepTitle(
          tr('Review your application', 'Application check karen'),
          tr('Check everything once — then submit. Super Admin will review it.',
              'Sab kuch ek dafa check karen — phir submit karein. Super Admin review karega.'),
        ),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 120,
                  child: Text(r.$1,
                      style: TextStyle(color: kMuted, fontSize: 13)),
                ),
                Expanded(
                  child: Text(r.$2,
                      style: TextStyle(color: kText, fontSize: 13)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _dateLabel(DateTime? d) {
    if (d == null) return '—';
    final l = d.toLocal();
    return '${l.day}/${l.month}/${l.year}';
  }
}
