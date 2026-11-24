import 'dart:convert';

import 'package:http/http.dart' as http;

import 'supabase_db.dart';

/// Central payment layer for EasyPaisa / JazzCash / Bank.
///
/// API SYSTEM (manual flow REMOVED by user order 2026-10-27):
/// the old "pay in your wallet app, then submit a Transaction ID/UTR
/// for admin approval" flow is GONE — there is no UTR field, no
/// manual-deposit submission, and no manual approval path in the
/// user app anymore. Recharge now goes through the provider API.
/// NOTE (2026-10-29): Bank Transfer does NOT use this generic API
/// path — it routes to PayFastService (payfast_service.dart), the
/// PayFast gateway aggregator. Do not send bank payments through
/// initiateApiPayment.
///
/// API-PENDING STATE: until the admin enters real EasyPaisa/JazzCash
/// API credentials in the admin app (Settings → Payment Settings),
/// every method reports `isConfigured == false` and the recharge
/// screen honestly shows "API pending" — it never fakes a payment,
/// never falls back to a manual flow, and never claims automatic
/// verification works. When credentials are entered, the SAME code
/// path activates: initiate → provider checkout → verify → credit.
///
/// Credentials come ONLY at runtime from app_settings `payments`
/// ({easypaisa|jazzcash|bank: {enabled, merchantId, storeId,
/// apiKey, apiSecret, apiEndpoint, verifyEndpoint, callbackUrl}}).
/// No credential is hardcoded anywhere in the app. The endpoint the
/// admin enters must be the provider's payment-initiation endpoint
/// for the JSON contract below (merchant_id, store_id, amount,
/// currency PKR, order_id, callback_url, Bearer apiKey auth, and a
/// JSON reply carrying a checkout/payment URL and a provider
/// transaction id). Provider-specific signing (e.g. a JazzCash
/// integrity hash) cannot be implemented without the provider's
/// actual API docs/credentials — when the user supplies those, the
/// adapter in [_initiateViaApi] is the single place to add it.
class PaymentConfig {
  final bool enabled;
  final String merchantId;
  final String storeId;
  final String apiKey;
  final String apiSecret;
  final String apiEndpoint;
  final String verifyEndpoint;
  final String callbackUrl;
  final String accountNumber;
  final String accountTitle;

  const PaymentConfig({
    this.enabled = false,
    this.merchantId = '',
    this.storeId = '',
    this.apiKey = '',
    this.apiSecret = '',
    this.apiEndpoint = '',
    this.verifyEndpoint = '',
    this.callbackUrl = '',
    this.accountNumber = '',
    this.accountTitle = '',
  });

  factory PaymentConfig.fromMap(Map<String, dynamic> m) => PaymentConfig(
        enabled: m['enabled'] == true,
        merchantId: (m['merchantId'] ?? m['merchant_id'] ?? '').toString(),
        storeId: (m['storeId'] ?? m['store_id'] ?? '').toString(),
        apiKey: (m['apiKey'] ?? m['api_key'] ?? '').toString(),
        apiSecret: (m['apiSecret'] ?? m['api_secret'] ?? '').toString(),
        apiEndpoint: (m['apiEndpoint'] ?? m['api_endpoint'] ?? '').toString(),
        verifyEndpoint: (m['verifyEndpoint'] ?? m['verify_endpoint'] ?? '').toString(),
        callbackUrl: (m['callbackUrl'] ?? m['callback_url'] ?? '').toString(),
        accountNumber: (m['accountNumber'] ?? m['account_number'] ?? '').toString(),
        accountTitle: (m['accountTitle'] ?? m['account_title'] ?? '').toString(),
      );

  /// True only when the admin has entered usable API credentials.
  /// NOTE: `accountNumber` alone does NOT configure the API — that
  /// field is legacy display data from the removed manual flow.
  bool get isConfigured =>
      enabled &&
      apiKey.isNotEmpty &&
      apiEndpoint.isNotEmpty &&
      (merchantId.isNotEmpty || storeId.isNotEmpty);

  bool get isPending => !isConfigured;
}

/// UPI was REMOVED by user order (recharge is EasyPaisa/JazzCash/Bank
/// only). Do not re-add a UPI case here without a new user instruction.
enum PaymentMethod { easypaisa, jazzcash, bankTransfer }

extension PaymentMethodLabel on PaymentMethod {
  String get label {
    switch (this) {
      case PaymentMethod.easypaisa:
        return 'EasyPaisa';
      case PaymentMethod.jazzcash:
        return 'JazzCash';
      case PaymentMethod.bankTransfer:
        return 'Bank Transfer';
    }
  }

  String get depositValue {
    switch (this) {
      case PaymentMethod.easypaisa:
        return 'easypaisa';
      case PaymentMethod.jazzcash:
        return 'jazzcash';
      case PaymentMethod.bankTransfer:
        return 'Bank Transfer';
    }
  }

  String get settingsKey {
    switch (this) {
      case PaymentMethod.easypaisa:
        return 'easypaisa';
      case PaymentMethod.jazzcash:
        return 'jazzcash';
      case PaymentMethod.bankTransfer:
        return 'bank';
    }
  }
}

/// Result of an API payment initiation.
class ApiPaymentResult {
  /// 'pending' (API not configured), 'redirect' (open paymentUrl),
  /// or 'error'.
  final String status;
  final String? paymentUrl;
  final String? providerTransactionId;
  final String? depositId;
  final String message;

  const ApiPaymentResult({
    required this.status,
    this.paymentUrl,
    this.providerTransactionId,
    this.depositId,
    required this.message,
  });
}

class PaymentService {
  /// Loads config at runtime from app_settings payments/{method}.
  static Future<PaymentConfig> loadConfig(PaymentMethod method) async {
    final settings = await SupaDb.getAppSettings();
    final payments = SupaDb.asMap(settings['payments']);
    return PaymentConfig.fromMap(SupaDb.asMap(payments[method.settingsKey]));
  }

  /// Single integration point for a provider initiation call.
  /// Throws on transport / provider errors so the UI can show them
  /// honestly instead of pretending the payment started.
  static Future<(String?, String?)> _initiateViaApi({
    required PaymentConfig config,
    required PaymentMethod method,
    required double amount,
    required String orderId,
  }) async {
    final resp = await http.post(
      Uri.parse(config.apiEndpoint),
      headers: {
        'Content-Type': 'application/json',
        if (config.apiKey.isNotEmpty) 'Authorization': 'Bearer ${config.apiKey}',
      },
      body: jsonEncode({
        'merchant_id': config.merchantId,
        'store_id': config.storeId,
        'method': method.depositValue,
        'amount': amount,
        'currency': 'PKR',
        'order_id': orderId,
        'callback_url': config.callbackUrl,
      }),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('Payment provider rejected the request (HTTP ${resp.statusCode}).');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    String? url;
    for (final k in ['payment_url', 'paymentUrl', 'redirect_url', 'redirectUrl', 'checkout_url', 'checkoutUrl']) {
      final v = data[k];
      if (v != null && v.toString().isNotEmpty) {
        url = v.toString();
        break;
      }
    }
    String? txId;
    for (final k in ['transaction_id', 'transactionId', 'provider_txn_id', 'txn_id', 'id']) {
      final v = data[k];
      if (v != null && v.toString().isNotEmpty) {
        txId = v.toString();
        break;
      }
    }
    return (url, txId);
  }

  /// Starts an API payment. Pending (unconfigured) API → a pending
  /// result, never a fake payment and never a manual fallback.
  /// Configured API → creates an `api_pending` deposit row, calls
  /// the provider, and returns the checkout URL (if any).
  static Future<ApiPaymentResult> initiateApiPayment({
    required PaymentMethod method,
    required double amount,
    required String uid,
    required String email,
    required String userName,
  }) async {
    final config = await loadConfig(method);
    if (config.isPending) {
      return const ApiPaymentResult(
        status: 'pending',
        message: 'Payment API abhi pending hai — admin ne abhi API configure nahi ki. Jab API mil jayegi to yahin se payment hoga.',
      );
    }
    final orderId = 'PT-${DateTime.now().millisecondsSinceEpoch}-$uid';
    final depositId = await SupaDb.createApiDepositRow(
      uid: uid,
      email: email,
      userName: userName,
      amount: amount,
      paymentMethodValue: method.depositValue,
      orderId: orderId,
    );
    try {
      final (url, txId) = await _initiateViaApi(config: config, method: method, amount: amount, orderId: orderId);
      if (txId != null && txId.isNotEmpty) {
        await SupaDb.updateDepositProviderTx(depositId, txId);
      }
      return ApiPaymentResult(
        status: url != null ? 'redirect' : 'created',
        paymentUrl: url,
        providerTransactionId: txId,
        depositId: depositId,
        message: url != null
            ? 'Payment provider par ja kar payment mukammal karen, phir "Check payment status" dabayen.'
            : 'Payment request provider ko bhej di gayi hai. Status check karen.',
      );
    } catch (e) {
      await SupaDb.updateDepositStatus(depositId, 'failed');
      return ApiPaymentResult(
        status: 'error',
        depositId: depositId,
        message: 'Payment start nahi ho saki: $e',
      );
    }
  }

  /// Verifies an API deposit with the provider and, on a confirmed
  /// success, credits the user's deposit balance + transaction.
  /// Returns 'completed', 'pending', 'failed', or 'api_pending'
  /// (API not configured / no verify endpoint — never a fake
  /// success). The credit path is the only balance-crediting path
  /// for API deposits; the removed manual-approval path is gone.
  static Future<String> verifyApiPayment({
    required String depositId,
    required PaymentMethod method,
  }) async {
    final config = await loadConfig(method);
    if (config.isPending) return 'api_pending';
    final dep = await SupaDb.getDeposit(depositId);
    if (dep.isEmpty) return 'not_found';
    if (SupaDb.strOf(dep['status']) == 'completed') return 'completed';
    String providerStatus = 'pending';
    if (config.verifyEndpoint.isNotEmpty) {
      final txId = SupaDb.strOf(dep['provider_txn_id'], SupaDb.strOf(dep['order_id']));
      final resp = await http.post(
        Uri.parse(config.verifyEndpoint),
        headers: {
          'Content-Type': 'application/json',
          if (config.apiKey.isNotEmpty) 'Authorization': 'Bearer ${config.apiKey}',
        },
        body: jsonEncode({
          'merchant_id': config.merchantId,
          'store_id': config.storeId,
          'transaction_id': txId,
          'order_id': SupaDb.strOf(dep['order_id']),
        }),
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final s = (data['status'] ?? data['payment_status'] ?? '').toString().toLowerCase();
        if (s.contains('success') || s.contains('paid') || s.contains('approved') || s.contains('completed')) {
          providerStatus = 'completed';
        } else if (s.contains('fail') || s.contains('reject') || s.contains('cancel')) {
          providerStatus = 'failed';
        }
      }
    }
    if (providerStatus == 'completed') {
      await SupaDb.creditApiDeposit(depositId);
      return 'completed';
    }
    if (providerStatus == 'failed') {
      await SupaDb.updateDepositStatus(depositId, 'failed');
      return 'failed';
    }
    return 'pending';
  }

  static Future<String> getPaymentStatus(String depositId) async {
    final row = await SupaDb.getDeposit(depositId);
    if (row.isEmpty) return 'not_found';
    return SupaDb.strOf(row['status'], 'pending');
  }
}
