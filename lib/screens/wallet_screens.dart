import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../components/arena_components.dart';
import 'more_screens.dart';
import 'pro_features.dart';
import '../services/payment_service.dart';
import '../services/payfast_service.dart';
import '../services/supabase_db.dart';
import '../utils.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// MISC (2026-11-20): section heading in the global style — small
/// caps, muted olive-gold kSectionLabel (same as MORE worker's
/// ACCOUNT EMAIL pattern). Callers pass the text already cased.
Widget _sectionLabel(String text) => Text(
      text,
      style: const TextStyle(color: kSectionLabel, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1),
    );

/// MISC (2026-11-20): step heading with a gold amount suffix
/// ("STEP 2: PAYMENT METHOD  •  Rs 100.00" — the amount keeps its
/// "Rs" casing instead of being uppercased with the label).
Widget _stepLabel(String label, String amount) => RichText(
      text: TextSpan(
        style: const TextStyle(color: kSectionLabel, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1),
        children: [
          TextSpan(text: '$label  •  '),
          TextSpan(text: amount, style: TextStyle(color: kGold, letterSpacing: 0)),
        ],
      ),
    );

/// FIX ROUND 2026-10-28: Stateful so a failed balance load can be
/// retried. An unloaded profile NEVER renders as "Rs 0.00" (the old
/// code showed 0.00 while the stream had not emitted, which is how a
/// header pill of Rs 10048856 could sit next to a Wallet page of
/// Rs 0.00 for the same account). The total here and the header pill
/// both use the same walletTotal() formula in utils.dart.
class WalletPage extends StatefulWidget {
  final String uid;
  const WalletPage({super.key, required this.uid});
  @override
  State<WalletPage> createState() => _WalletPageState();
}

class _WalletPageState extends State<WalletPage> {
  int _streamNonce = 0;

  // WALLET TAB SELECTION (2026-11-22, Sameer): Add Amount hamesha
  // gold-filled aur Withdraw hamesha outlined tha — is liye
  // highlight Add par STUCK lagta tha. Ab dono ek toggle pair hain.
  // PHASE E (E24, CORRECTED 2026-11-24): the TAPPED one is gold-
  // filled (Sameer: "click pe yellow hona chahiye"); the other
  // is the card fill (shared token) — never black, never stuck.
  // Default 0 (Add Amount).
  int _activeAction = 0;

  /// The Add/Withdraw pair: the tapped one is gold-filled with
  /// dark text, the other is card-styled with grey border.
  /// [index] 0 = Add Amount, 1 = Withdraw.
  Widget _actionButton({
    required int index,
    required String label,
    required VoidCallback onPressed,
  }) {
    final active = _activeAction == index;
    final tap = () {
      setState(() => _activeAction = index);
      onPressed();
    };
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: tap,
        borderRadius: BorderRadius.circular(30),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          alignment: Alignment.center,
          decoration: active
              ? BoxDecoration(
                  color: kGold,
                  borderRadius: BorderRadius.circular(30),
                )
              : cardFillDecoration(radius: 30).copyWith(
                  border: Border.all(color: kBorder, width: 1),
                ),
          child: Text(label,
              style: TextStyle(
                  color: active ? Colors.black : kText,
                  fontWeight: FontWeight.bold,
                  fontSize: 15)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = widget.uid;
    return StreamBuilder<Map<String, dynamic>>(
      key: ValueKey('wallet-$_streamNonce'),
      stream: SupaDb.streamProfile(uid),
      builder: (context, snap) {
        final profile = snap.data ?? {};
        if (snap.connectionState == ConnectionState.waiting && profile.isEmpty) {
          return Center(child: CircularProgressIndicator(color: kGold));
        }
        if (profile.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Balance load nahi hua.', style: TextStyle(color: kMuted)),
                  const SizedBox(height: 12),
                  goldButton(label: 'Retry', onPressed: () => setState(() => _streamNonce++)),
                ],
              ),
            ),
          );
        }
        final deposit = numVal(profile['depositBalance']);
        final winning = numVal(profile['winningCash']);
        final bonus = numVal(profile['bonusCash']);
        final total = walletTotal(profile);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // MISC (2026-11-20): MockupCard — global 2-shine card
              // style instead of appCard's flat full border.
              MockupCard(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    _sectionLabel('TOTAL BALANCE'),
                    const SizedBox(height: 4),
                    Text(fmtRs(total), style: TextStyle(color: kGold, fontSize: 28, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _bal('Deposit', deposit),
                        _bal('Winning', winning),
                        _bal('Bonus', bonus),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                      child: _actionButton(
                          index: 0,
                          label: 'Add Amount',
                          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RechargePage(uid: uid, profile: profile))))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _actionButton(
                        index: 1,
                        label: 'Withdraw',
                        onPressed: () => _withdrawDialog(context, profile)),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              OutlineButton(
                label: 'View Earnings & Referrals',
                icon: Icons.monetization_on,
                goldText: true,
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(appBar: AppBar(title: Text('Earnings', style: TextStyle(color: kGold))), body: EarningsPage(uid: uid)))),
              ),
              const SizedBox(height: 12),
              OutlineButton(
                label: 'Full History, Withdrawals & Referral Board',
                icon: Icons.receipt_long,
                goldText: true,
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TransactionsPage(uid: uid))),
              ),
              const SizedBox(height: 20),
              _sectionLabel('RECENT TRANSACTIONS'),
              const SizedBox(height: 8),
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: SupaDb.streamTransactions(uid),
                builder: (context, tsnap) {
                  final txs = tsnap.data ?? [];
                  if (txs.isEmpty) return Text('No transactions yet.', style: TextStyle(color: kMuted));
                  return Column(
                    children: [
                      for (final t in txs)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          // MISC (2026-11-20): MockupCard — global
                          // 2-shine card style.
                          child: MockupCard(
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(strVal(t['description'], strVal(t['type'], 'Transaction')), style: TextStyle(color: kText, fontWeight: FontWeight.bold)), Text('${strVal(t['type'])} • ${fmtDate(t['timestamp'])}', style: TextStyle(color: kMuted, fontSize: 12))])),
                                Text('${numVal(t['amount']) < 0 ? '' : '+'}${fmtRs(numVal(t['amount']))}', style: TextStyle(color: numVal(t['amount']) < 0 ? Colors.redAccent : Colors.greenAccent, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _bal(String label, double v) => Column(children: [Text(label, style: TextStyle(color: kMuted, fontSize: 12)), Text(fmtRs(v), style: TextStyle(color: kText, fontWeight: FontWeight.bold))]);

  Future<void> _withdrawDialog(BuildContext context, Map<String, dynamic> profile) async {
    final amountCtrl = TextEditingController();
    final methodCtrl = TextEditingController();
    // Live minimum from app_settings (audit fix 2026-11-21) — the old
    // hardcoded 'Rs 50' lied whenever the admin changed the setting.
    final settings = await SupaDb.getAppSettings();
    final minW = SupaDb.numOf(settings['minWithdraw'], 50);
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text('Withdraw', style: TextStyle(color: kText)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Winning balance: ${fmtRs(numVal(profile['winningCash']))}', style: TextStyle(color: kMuted)),
            const SizedBox(height: 4),
            Text('Minimum withdrawal: ${fmtRs(minW)}. Winning balance is deducted when you submit (not after approval).', style: TextStyle(color: kMuted, fontSize: 12)),
            const SizedBox(height: 12),
            // MISC (2026-11-20): shared mockup-styled fields
            // (visible border, radius 12) instead of borderless
            // inline TextFields.
            field(controller: amountCtrl, label: 'Amount', hint: 'Enter amount', keyboardType: TextInputType.number),
            field(controller: methodCtrl, label: 'Withdrawal Method', hint: 'Easypaisa/JazzCash account'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel', style: TextStyle(color: kMuted))),
          TextButton(
            onPressed: () async {
              final amt = double.tryParse(amountCtrl.text.trim()) ?? 0;
              final method = methodCtrl.text.trim();
              try {
                await SupaDb.requestWithdrawal(uid: widget.uid, profile: profile, amount: amt, method: method);
              } catch (e) {
                if (context.mounted) toast(context, e.toString().replaceFirst('Exception: ', ''));
                return;
              }
              if (context.mounted) {
                Navigator.pop(context);
                toast(context, 'Withdrawal request submitted. Winning balance deducted now; it will be processed after admin approval.');
              }
            },
            child: Text('Submit Request', style: TextStyle(color: kGold)),
          ),
        ],
      ),
    );
  }
}

/// 3-step recharge (API ONLY — manual UTR flow REMOVED 2026-10-27):
/// 1 amount (Rs 10–1000), 2 method (EasyPaisa / JazzCash / Bank —
/// UPI REMOVED by user order), 3 API payment. While the provider API
/// is PENDING (no credentials in admin settings), step 3 honestly
/// shows the pending state and offers NO pay-to account, NO QR code,
/// NO TID field and NO manual submission. When configured, step 3
/// starts the API payment and offers "Check payment status", which
/// verifies with the provider and credits on confirmed success.
class RechargePage extends StatefulWidget {
  final String uid;
  final Map<String, dynamic> profile;
  const RechargePage({super.key, required this.uid, required this.profile});
  @override
  State<RechargePage> createState() => _RechargePageState();
}

class _RechargePageState extends State<RechargePage> {
  int _step = 1;
  final _amountCtrl = TextEditingController();
  PaymentMethod? _method;
  PaymentConfig? _config;
  PayFastConfig? _payfastConfig;
  PayFastStartResult? _payfastStart;
  ApiPaymentResult? _payment;
  String _status = '';
  bool _busy = false;
  // Step-2 readiness (audit fix 2026-11-21): a payment method the
  // admin disabled — or never configured — used to sit in the step-2
  // list and only fail at step 3. The three configs are now loaded
  // when step 2 opens; unready methods are hidden, not offered.
  Map<PaymentMethod, bool> _methodReady = {};
  bool _methodsLoading = false;

  double get _amount => double.tryParse(_amountCtrl.text.trim()) ?? 0;

  Future<void> _toStep2() async {
    final amt = _amount;
    if (amt < 10 || amt > 1000) {
      toast(context, 'Amount must be between Rs 10 and Rs 1000.');
      return;
    }
    setState(() {
      _step = 2;
      _methodsLoading = true;
    });
    try {
      final results = await Future.wait([
        PaymentService.loadConfig(PaymentMethod.easypaisa),
        PaymentService.loadConfig(PaymentMethod.jazzcash),
        PayFastService.loadConfig(),
      ]);
      if (!mounted) return;
      setState(() {
        _methodReady = {
          PaymentMethod.easypaisa: (results[0] as PaymentConfig).isConfigured,
          PaymentMethod.jazzcash: (results[1] as PaymentConfig).isConfigured,
          PaymentMethod.bankTransfer: !(results[2] as PayFastConfig).isPending,
        };
        // A previously selected method that is no longer ready must
        // not stay selected (it is no longer on screen).
        if (_method != null && _methodReady[_method] == false) _method = null;
        _methodsLoading = false;
      });
    } catch (_) {
      // Fail OPEN: a settings-read failure must not block recharge —
      // step 3 re-loads the chosen config and surfaces the real error.
      if (!mounted) return;
      setState(() {
        _methodReady = {
          for (final m in PaymentMethod.values) m: true,
        };
        _methodsLoading = false;
      });
    }
  }

  Future<void> _toStep3() async {
    if (_method == null) {
      toast(context, 'Please select a payment method.');
      return;
    }
    setState(() => _busy = true);
    try {
      if (_method == PaymentMethod.bankTransfer) {
        _payfastConfig = await PayFastService.loadConfig();
      } else {
        _config = await PaymentService.loadConfig(_method!);
      }
      setState(() => _step = 3);
    } catch (e) {
      if (mounted) toast(context, 'Could not load payment settings: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// PayFast checkout: token + hosted checkout page. A success
  /// redirect alone NEVER credits — credit happens only in
  /// _checkPayFastStatus, on a verified callback record.
  Future<void> _payViaPayFast() async {
    setState(() => _busy = true);
    try {
      _payfastStart = await PayFastService.startCheckout(
        amount: _amount,
        uid: widget.uid,
        email: strVal(widget.profile['email'], FirebaseAuth.instance.currentUser?.email ?? ''),
        userName: strVal(widget.profile['displayName'], 'N/A'),
      );
      if (_payfastStart!.status == 'pending') {
        if (mounted) toast(context, _payfastStart!.message);
      } else if (_payfastStart!.status == 'ready' && mounted) {
        final result = await Navigator.push<String>(
          context,
          MaterialPageRoute(
            builder: (_) => PayFastCheckoutPage(
              config: _payfastConfig!,
              start: _payfastStart!,
              amount: _amount,
              email: strVal(widget.profile['email'], FirebaseAuth.instance.currentUser?.email ?? ''),
            ),
          ),
        );
        if (!mounted) return;
        if (result == 'success') {
          toast(context, 'Checkout complete — ab "Check payment status" dabayen. Verified callback aane par hi balance milega.');
        } else if (result == 'failure') {
          toast(context, 'PayFast payment fail ho gaya ya cancel hua.');
        }
      } else if (mounted) {
        toast(context, _payfastStart!.message);
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) toast(context, 'PayFast start failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkPayFastStatus() async {
    final depId = _payfastStart?.depositId;
    if (depId == null || depId.isEmpty) {
      toast(context, 'Pehle "Pay via PayFast" dabayen.');
      return;
    }
    setState(() => _busy = true);
    try {
      _status = await PayFastService.checkGatewayStatus(depId);
      if (!mounted) return;
      if (_status == 'completed') {
        toast(context, 'Payment verified! Balance update ho gaya hai.');
        if (mounted) {
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => PaymentSuccessPage(amount: _amount, method: _method!.label)));
        }
      } else if (_status == 'failed') {
        toast(context, 'Payment failed / rejected.');
      } else if (_status == 'rejected') {
        toast(context, 'Payment admin ne reject kar diya hai.');
      } else {
        toast(context, 'PayFast ka verified callback abhi nahi aaya — thodi der baad dobara check karen. Gateway live keys + IPN receiver pending ho to status yahin rukega.');
      }
      setState(() {});
    } catch (e) {
      if (mounted) toast(context, 'Status check failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _payViaApi() async {
    setState(() => _busy = true);
    try {
      _payment = await PaymentService.initiateApiPayment(
        method: _method!,
        amount: _amount,
        uid: widget.uid,
        email: strVal(widget.profile['email'], FirebaseAuth.instance.currentUser?.email ?? ''),
        userName: strVal(widget.profile['displayName'], 'N/A'),
      );
      if (_payment!.status == 'pending') {
        if (mounted) toast(context, _payment!.message);
      } else if (_payment!.paymentUrl != null && mounted) {
        final uri = Uri.parse(_payment!.paymentUrl!);
        if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) toast(context, 'Payment start failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkStatus() async {
    final depId = _payment?.depositId;
    if (depId == null || depId.isEmpty) {
      toast(context, 'Pehle "Pay via API" dabayen.');
      return;
    }
    setState(() => _busy = true);
    try {
      _status = await PaymentService.verifyApiPayment(depositId: depId, method: _method!);
      if (!mounted) return;
      if (_status == 'completed') {
        toast(context, 'Payment verified! Balance update ho gaya hai.');
        // BOARD Payment Success screen — shown ONLY on real
        // verification, never for pending/failed.
        if (mounted) {
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => PaymentSuccessPage(amount: _amount, method: _method!.label)));
        }
      } else if (_status == 'failed') {
        toast(context, 'Payment failed / rejected by provider.');
      } else if (_status == 'api_pending') {
        toast(context, 'Payment API abhi pending hai.');
      } else {
        toast(context, 'Payment abhi pending hai — thodi der baad dobara check karen.');
      }
      setState(() {});
    } catch (e) {
      if (mounted) toast(context, 'Status check failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final deposit = numVal(widget.profile['depositBalance']);
    final pending = _config?.isPending ?? true;
    return Scaffold(
      appBar: AppBar(title: Text('Recharge', style: TextStyle(color: kGold))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // MISC (2026-11-20): deposit header in a MockupCard
            // (global 2-shine card style).
            SizedBox(
              width: double.infinity,
              child: MockupCard(
                child: Column(
                  children: [
                    _sectionLabel('DEPOSIT BALANCE'),
                    const SizedBox(height: 4),
                    Text(fmtRs(deposit), style: TextStyle(color: kGold, fontSize: 26, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            if (_step == 1) ...[
              _sectionLabel('STEP 1: AMOUNT'),
              const SizedBox(height: 12),
              field(controller: _amountCtrl, label: 'Amount', hint: '10 - 1000', keyboardType: TextInputType.number),
              Wrap(
                spacing: 8,
                // PHASE E (E24, CORRECTED 2026-11-24): the
                // selected amount chip is gold-filled (Sameer:
                // "click pe yellow hona chahiye"); the REST are
                // the card fill — never black.
                children: [for (final p in [20, 50, 100, 200, 500, 1000]) ChoiceChip(label: Text('Rs $p'), selected: _amount == p.toDouble(), selectedColor: kGold, backgroundColor: kCardFillColor, side: BorderSide(color: _amount == p.toDouble() ? kGold : kBorder, width: _amount == p.toDouble() ? 1.5 : 1), labelStyle: TextStyle(color: _amount == p.toDouble() ? Colors.black : kText), onSelected: (_) => setState(() => _amountCtrl.text = p.toString()))],
              ),
              const SizedBox(height: 16),
              goldButton(label: 'Continue', onPressed: _toStep2),
            ],
            if (_step == 2) ...[
              _stepLabel('STEP 2: PAYMENT METHOD', fmtRs(_amount)),
              const SizedBox(height: 12),
              if (_methodsLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (!_methodReady.values.any((ready) => ready))
                MockupCard(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    'Koi payment method abhi available nahi hai — admin ne abhi tak koi payment method configure nahi kiya. Thodi der baad dobara try karein ya support se raabta karein.',
                    style: TextStyle(color: kMuted, fontSize: 13),
                  ),
                ),
              for (final m in PaymentMethod.values)
                if (!_methodsLoading && (_methodReady[m] ?? true))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  // MISC (2026-11-20): MockupCard — global 2-shine
                  // card style. (The selected row's gold radio dot
                  // is the selection state, not a card border.)
                  child: MockupCard(
                    padding: const EdgeInsets.all(14),
                    child: RadioListTile<PaymentMethod>(
                      value: m,
                      groupValue: _method,
                      activeColor: kGold,
                      onChanged: (v) => setState(() => _method = v),
                      title: Text(m.label, style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
                      subtitle: Text(
                        m == PaymentMethod.bankTransfer
                            ? 'AUTOMATIC via PayFast gateway: bank list PayFast checkout par dikhegi (12+ Pakistani banks + JazzCash/EasyPaisa). Sirf verified payment par balance milega — koi manual approve nahi.'
                            : 'API payment (EasyPaisa / JazzCash API). Manual UTR system hata diya gaya hai.',
                        style: TextStyle(color: kMuted, fontSize: 12),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              if (!_methodsLoading && _methodReady.values.any((ready) => ready))
                goldButton(label: 'Proceed to Pay', onPressed: _toStep3, busy: _busy),
              TextButton(onPressed: () => setState(() => _step = 1), child: Text('Back', style: TextStyle(color: kMuted))),
            ],
            if (_step == 3 && _method == PaymentMethod.bankTransfer && _payfastConfig != null) ...[
              _stepLabel('STEP 3: PAYFAST BANK PAYMENT', fmtRs(_amount)),
              const SizedBox(height: 12),
              // MISC (2026-11-20): MockupCard — global 2-shine card style.
              MockupCard(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Payment Mode: Bank Transfer (PayFast Gateway)', style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Text(
                      _payfastConfig!.isPending
                          ? 'PAYFAST PENDING: admin ne abhi PayFast merchant credentials (Settings → PayFast: Merchant ID, Secured Key, Callback URL) nahi daale. Jab gateway live hoga to yahin se bank payment hoga. Koi manual payment, koi receipt submit nahi hai — is round me manual bank system NAHI hai.'
                          : 'PayFast configured hai. "Pay via PayFast" dabayen — PayFast checkout par apna bank chunen (12+ Pakistani banks + JazzCash/EasyPaisa wallets), payment mukammal karen, phir "Check payment status" se verify karen. Balance SIRF verified callback par milega.',
                      style: TextStyle(color: kMuted, fontSize: 13),
                    ),
                    if (_payfastStart != null) ...[
                      const SizedBox(height: 8),
                      Text(_payfastStart!.message, style: TextStyle(color: kText, fontSize: 13)),
                      if (_status.isNotEmpty) Text('Status: $_status', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (!_payfastConfig!.isPending) ...[
                goldButton(label: 'Pay via PayFast', onPressed: _payViaPayFast, busy: _busy),
                const SizedBox(height: 8),
                // MISC (2026-11-20): shared secondary button
                // (mockup pill) instead of inline OutlinedButtons.
                OutlineButton(label: 'Check payment status', onPressed: _checkPayFastStatus, goldText: true),
                const SizedBox(height: 8),
                OutlineButton(
                  label: 'My PayFast Deposits',
                  icon: Icons.account_balance,
                  goldText: true,
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PayFastDepositsPage(uid: widget.uid))),
                ),
              ],
              TextButton(onPressed: () => setState(() => _step = 2), child: Text('Back', style: TextStyle(color: kMuted))),
            ],
            if (_step == 3 && _config != null && _method != PaymentMethod.bankTransfer) ...[
              _stepLabel('STEP 3: API PAYMENT', fmtRs(_amount)),
              const SizedBox(height: 12),
              // MISC (2026-11-20): MockupCard — global 2-shine card style.
              MockupCard(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Payment Mode: ${_method!.label}', style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Text(
                      pending
                          ? 'API PENDING: ${_method!.label} API abhi configure nahi hui hai. Admin jab API credentials (Settings → Payment Settings) daalega, tab yahin se payment hoga. Abhi koi payment mat karen — manual TID system khatam ho gaya hai, isliye koi TID submit nahi hoga.'
                          : '${_method!.label} API configured hai. "Pay via API" dabayen, provider par payment mukammal karen, phir "Check payment status" se verify karen.',
                      style: TextStyle(color: kMuted, fontSize: 13),
                    ),
                    if (_payment != null) ...[
                      const SizedBox(height: 8),
                      Text(_payment!.message, style: TextStyle(color: kText, fontSize: 13)),
                      if (_status.isNotEmpty) Text('Status: $_status', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (!pending) ...[
                goldButton(label: 'Pay via API', onPressed: _payViaApi, busy: _busy),
                const SizedBox(height: 8),
                // MISC (2026-11-20): shared secondary button
                // (mockup pill) instead of the inline OutlinedButton.
                OutlineButton(label: 'Check payment status', onPressed: _checkStatus, goldText: true),
              ],
              TextButton(onPressed: () => setState(() => _step = 2), child: Text('Back', style: TextStyle(color: kMuted))),
            ],
          ],
        ),
      ),
    );
  }
}

/// PayFast hosted checkout page ONLY. This is the gateway's own
/// payment page (bank list + wallets live here) — the rest of the
/// app is native, this screen is just the checkout container.
/// Success/failure here only closes the checkout: NOTHING is
/// credited from this page. Credit happens only when the user taps
/// "Check payment status" and a verified callback record exists.
class PayFastCheckoutPage extends StatefulWidget {
  final PayFastConfig config;
  final PayFastStartResult start;
  final double amount;
  final String email;
  const PayFastCheckoutPage({super.key, required this.config, required this.start, required this.amount, required this.email});
  @override
  State<PayFastCheckoutPage> createState() => _PayFastCheckoutPageState();
}

class _PayFastCheckoutPageState extends State<PayFastCheckoutPage> {
  late final WebViewController _controller;
  bool _done = false;

  String _esc(String v) => v.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('"', '&quot;');

  @override
  void initState() {
    super.initState();
    final fields = PayFastService.checkoutFormFields(
      config: widget.config,
      start: widget.start,
      amount: widget.amount,
      email: widget.email,
      mobile: '',
    );
    final inputs = fields.entries.map((e) => '<input type="hidden" name="${_esc(e.key)}" value="${_esc(e.value)}">').join();
    final html = '<html><body onload="document.forms[0].submit()"><form method="POST" action="${_esc(widget.config.checkoutUrl)}">$inputs</form><p style="font-family:sans-serif">PayFast checkout khul raha hai…</p></body></html>';
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (req) {
            if (_done) return NavigationDecision.prevent;
            if (req.url.contains('payfast-success')) {
              _done = true;
              Navigator.pop(context, 'success');
              return NavigationDecision.prevent;
            }
            if (req.url.contains('payfast-failure')) {
              _done = true;
              Navigator.pop(context, 'failure');
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadHtmlString(html);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('PayFast Checkout', style: TextStyle(color: kGold))),
      body: WebViewWidget(controller: _controller),
    );
  }
}

/// The user's own PayFast gateway deposits: gateway_pending until a
/// verified callback credits them, completed only after verification.
/// No manual approve exists for these rows anywhere.
class PayFastDepositsPage extends StatelessWidget {
  final String uid;
  const PayFastDepositsPage({super.key, required this.uid});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('My PayFast Deposits', style: TextStyle(color: kGold))),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: PayFastService.myGatewayDeposits(uid),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator(color: kGold));
          }
          if (snap.hasError) {
            return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Load nahi ho sake: ${snap.error}', style: TextStyle(color: kMuted))));
          }
          final rows = snap.data ?? [];
          if (rows.isEmpty) {
            return Center(child: Text('Abhi koi PayFast deposit nahi.', style: TextStyle(color: kMuted)));
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final d in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  // MISC (2026-11-20): MockupCard — global 2-shine
                  // card style.
                  child: MockupCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(child: Text(fmtRs(numVal(d['amount'])), style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 16))),
                            Text(strVal(d['status'], 'gateway_pending').toUpperCase(), style: TextStyle(color: strVal(d['status']) == 'completed' ? Colors.greenAccent : strVal(d['status']) == 'failed' || strVal(d['status']) == 'rejected' ? Colors.redAccent : kGold, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        Text('Basket: ${strVal(d['order_id'], '—')}', style: TextStyle(color: kMuted, fontSize: 13)),
                        if (strVal(d['provider_txn_id']).isNotEmpty) Text('PayFast Txn: ${strVal(d['provider_txn_id'])}', style: TextStyle(color: kMuted, fontSize: 13)),
                        Text(fmtDate(d['created_at']), style: TextStyle(color: kMuted, fontSize: 12)),
                        if (strVal(d['status']) == 'gateway_pending') Text('Verified callback ka wait hai — Recharge → Check payment status dabayen.', style: TextStyle(color: kMuted, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
