import 'dart:convert';

import 'package:http/http.dart' as http;

import 'supabase_db.dart';

/// AUTOMATIC BANK TRANSFER via PayFast gateway aggregator
/// (user order 2026-10-29 ~15:22 PKT — replaces the cancelled manual
/// bank-transfer / receipt-approval system; there is NO manual
/// approve button for gateway payments anywhere in this round).
///
/// Flow (PayFast Pakistan, ipg1.apps.net.pk — the published
/// payfast_flutter flow):
///  1. Admin enters PayFast merchant credentials in the admin app
///     (Settings → PayFast). Empty = gateway NOT configured, and the
///     user app says so honestly instead of faking a checkout.
///  2. User picks Bank Transfer → "Pay via PayFast". The app creates
///     a deposit row with status 'gateway_pending' (NO balance
///     change) and fetches an access token from PayFast's
///     GetAccessToken endpoint with merchantId + securedKey.
///  3. The PayFast hosted checkout page opens (WebView, checkout
///     ONLY — the rest of the app stays native). PayFast itself
///     shows its bank list (12+ Pakistani banks) + JazzCash /
///     EasyPaisa wallets; the user picks their bank THERE and pays.
///  4. PayFast redirects to the admin's callback URLs. Credit
///     happens ONLY through [checkGatewayStatus]: it credits when
///     — and only when — a gateway_callbacks row with verified=true
///     + success exists for this basket. A success redirect alone
///     never credits, and no manual approve path exists.
///
/// EXTERNAL-PENDING (honest): the verified callback record can only
/// be written by a server-side IPN receiver (Supabase Edge Function
/// or hosted callback page) registered in the PayFast dashboard,
/// plus live merchant keys. Until both exist, Check Status honestly
/// stays on 'gateway_pending'. The token-request field names below
/// follow the published PayFast Flutter flow (MERCHANT_ID,
/// SECURED_KEY, BASKET_ID, TXNAMT); the merchant's own PayFast
/// dashboard docs are the final word at sandbox-test time, and the
/// sandbox test — not this code — is what proves the live contract.
///
/// Credentials come ONLY at runtime from app_settings
/// payments.payfast. NOTHING is hardcoded here — not merchant id,
/// not secured key, not a single account number.
class PayFastConfig {
  final bool enabled;
  final String merchantId;
  final String securedKey;
  final String environment;
  final String tokenUrl;
  final String checkoutUrl;
  final String callbackBaseUrl;

  const PayFastConfig({
    this.enabled = false,
    this.merchantId = '',
    this.securedKey = '',
    this.environment = 'sandbox',
    this.tokenUrl = 'https://ipg1.apps.net.pk/Ecommerce/api/Transaction/GetAccessToken',
    this.checkoutUrl = 'https://ipg1.apps.net.pk/Ecommerce/api/Transaction/PostTransaction',
    this.callbackBaseUrl = '',
  });

  factory PayFastConfig.fromMap(Map<String, dynamic> m) => PayFastConfig(
        enabled: m['enabled'] == true,
        merchantId: (m['merchantId'] ?? m['merchant_id'] ?? '').toString(),
        securedKey: (m['securedKey'] ?? m['secured_key'] ?? m['apiSecret'] ?? m['api_secret'] ?? '').toString(),
        environment: (m['environment'] ?? 'sandbox').toString(),
        tokenUrl: (m['tokenUrl'] ?? m['token_url'] ?? 'https://ipg1.apps.net.pk/Ecommerce/api/Transaction/GetAccessToken').toString(),
        checkoutUrl: (m['checkoutUrl'] ?? m['checkout_url'] ?? 'https://ipg1.apps.net.pk/Ecommerce/api/Transaction/PostTransaction').toString(),
        callbackBaseUrl: (m['callbackUrl'] ?? m['callback_url'] ?? m['callbackBaseUrl'] ?? '').toString(),
      );

  /// Configured only when the admin has entered merchant id +
  /// secured key + a callback base URL. Any piece missing = the
  /// gateway is pending and checkout must not start.
  bool get isConfigured =>
      enabled &&
      merchantId.isNotEmpty &&
      securedKey.isNotEmpty &&
      callbackBaseUrl.isNotEmpty;

  bool get isPending => !isConfigured;

  String get successUrl => '$callbackBaseUrl/payfast-success';
  String get failureUrl => '$callbackBaseUrl/payfast-failure';
  String get checkoutCallbackUrl => '$callbackBaseUrl/payfast-ipn';
}

/// Result of starting a PayFast checkout.
class PayFastStartResult {
  /// 'pending' (gateway not configured), 'ready' (open checkout),
  /// or 'error'.
  final String status;
  final String? depositId;
  final String? basketId;
  final String? accessToken;
  final String message;

  const PayFastStartResult({
    required this.status,
    this.depositId,
    this.basketId,
    this.accessToken,
    required this.message,
  });
}

class PayFastService {
  static Future<PayFastConfig> loadConfig() async {
    final settings = await SupaDb.getAppSettings();
    final payments = SupaDb.asMap(settings['payments']);
    return PayFastConfig.fromMap(SupaDb.asMap(payments['payfast']));
  }

  static String? _extractToken(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return null;
    try {
      final data = jsonDecode(trimmed);
      if (data is Map) {
        for (final k in ['ACCESS_TOKEN', 'access_token', 'token', 'accessToken']) {
          final v = data[k];
          if (v != null && v.toString().isNotEmpty) return v.toString();
        }
        final nested = data['data'];
        if (nested is Map) {
          for (final k in ['ACCESS_TOKEN', 'access_token', 'token']) {
            final v = nested[k];
            if (v != null && v.toString().isNotEmpty) return v.toString();
          }
        }
      }
      if (data is String && data.isNotEmpty) return data;
    } catch (_) {
      // Not JSON: a bare token string is itself the token.
      if (!trimmed.contains(' ') && trimmed.length > 10) return trimmed;
    }
    return null;
  }

  /// Creates the gateway_pending deposit, then fetches the PayFast
  /// access token. On token failure the deposit is marked failed
  /// and an error is returned — never a fake checkout page.
  static Future<PayFastStartResult> startCheckout({
    required double amount,
    required String uid,
    required String email,
    required String userName,
  }) async {
    final config = await loadConfig();
    if (config.isPending) {
      return const PayFastStartResult(
        status: 'pending',
        message: 'PayFast gateway abhi pending hai — admin ne abhi merchant credentials (Settings → PayFast) nahi daale. Jab gateway live hoga to yahin se bank payment hoga.',
      );
    }
    final basketId = 'PT-PF-${DateTime.now().millisecondsSinceEpoch}-$uid';
    final depositId = await SupaDb.createGatewayDepositRow(
      uid: uid,
      email: email,
      userName: userName,
      amount: amount,
      paymentMethodValue: 'payfast',
      orderId: basketId,
    );
    try {
      final resp = await http.post(
        Uri.parse(config.tokenUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'MERCHANT_ID': config.merchantId,
          'SECURED_KEY': config.securedKey,
          'BASKET_ID': basketId,
          'TXNAMT': amount.toStringAsFixed(2),
        },
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        await SupaDb.updateDepositStatus(depositId, 'failed');
        return PayFastStartResult(
          status: 'error',
          depositId: depositId,
          basketId: basketId,
          message: 'PayFast se token nahi mila (HTTP ${resp.statusCode}). Gateway credentials ya endpoint check karen.',
        );
      }
      final token = _extractToken(resp.body);
      if (token == null || token.isEmpty) {
        await SupaDb.updateDepositStatus(depositId, 'failed');
        return PayFastStartResult(
          status: 'error',
          depositId: depositId,
          basketId: basketId,
          message: 'PayFast ne token nahi diya. Gateway credentials check karen.',
        );
      }
      return PayFastStartResult(
        status: 'ready',
        depositId: depositId,
        basketId: basketId,
        accessToken: token,
        message: 'PayFast checkout khul raha hai — apna bank chunen aur payment mukammal karen.',
      );
    } catch (e) {
      await SupaDb.updateDepositStatus(depositId, 'failed');
      return PayFastStartResult(
        status: 'error',
        depositId: depositId,
        basketId: basketId,
        message: 'PayFast start nahi ho saka: $e',
      );
    }
  }

  /// The PostTransaction form fields for the hosted checkout page.
  /// Field names follow the published PayFast Flutter checkout flow.
  static Map<String, String> checkoutFormFields({
    required PayFastConfig config,
    required PayFastStartResult start,
    required double amount,
    required String email,
    required String mobile,
  }) {
    return {
      'MERCHANT_ID': config.merchantId,
      'TOKEN': start.accessToken ?? '',
      'BASKET_ID': start.basketId ?? '',
      'TXNAMT': amount.toStringAsFixed(2),
      'CUSTOMER_EMAIL_ADDRESS': email,
      'CUSTOMER_MOBILE_NO': mobile,
      'SUCCESS_URL': config.successUrl,
      'FAILURE_URL': config.failureUrl,
      'CHECKOUT_URL': config.checkoutCallbackUrl,
      'TXNDESC': 'Pro Tournament wallet recharge',
      'CURRENCY_CODE': 'PKR',
    };
  }

  /// Verifies a gateway deposit and credits it ONLY on a verified
  /// success callback. Returns 'completed', 'failed', 'rejected',
  /// or 'gateway_pending' (no verified callback yet — the honest
  /// state until the IPN receiver + live keys exist). This is the
  /// ONLY credit path for gateway deposits; there is no manual
  /// approve button for them anywhere.
  static Future<String> checkGatewayStatus(String depositId) async {
    final dep = await SupaDb.getDeposit(depositId);
    if (dep.isEmpty) return 'not_found';
    final status = SupaDb.strOf(dep['status']);
    if (status == 'completed') return 'completed';
    if (status == 'failed') return 'failed';
    if (status == 'rejected') return 'rejected';
    if (status != 'gateway_pending') return status;
    final orderId = SupaDb.strOf(dep['order_id']);
    if (orderId.isEmpty) return 'gateway_pending';
    final callbacks = await SupaDb.client
        .from('gateway_callbacks')
        .select()
        .eq('order_id', orderId)
        .eq('verified', true)
        .order('created_at', ascending: false)
        .limit(1);
    final rows = callbacks as List;
    if (rows.isEmpty) return 'gateway_pending';
    final cb = Map<String, dynamic>.from(rows.first as Map);
    final cbStatus = SupaDb.strOf(cb['status']).toLowerCase();
    if (cbStatus.contains('success') || cbStatus.contains('complete') || cbStatus.contains('paid') || cbStatus.contains('approved')) {
      await SupaDb.creditGatewayDeposit(
        depositId,
        SupaDb.strOf(cb['provider_txn_id']),
      );
      return 'completed';
    }
    if (cbStatus.contains('fail') || cbStatus.contains('reject') || cbStatus.contains('cancel')) {
      await SupaDb.updateDepositStatus(depositId, 'failed');
      return 'failed';
    }
    return 'gateway_pending';
  }

  /// The user's own PayFast gateway deposits, newest first.
  static Future<List<Map<String, dynamic>>> myGatewayDeposits(String uid) async {
    final rows = await SupaDb.client
        .from('deposits')
        .select()
        .eq('firebase_uid', uid)
        .eq('payment_method', 'payfast')
        .order('created_at', ascending: false);
    return (rows as List).map((r) => Map<String, dynamic>.from(r as Map)).toList();
  }
}
