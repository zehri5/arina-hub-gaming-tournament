import 'package:protournament_user/platform/core/local_store.dart';

/// Financial records (ChatGPT blueprint §4; backend guide §4
/// `financial_records` table). RECORDS ONLY — no money movement, no
/// billing, no payout execution.
///
/// Platform revenue and organizer business records are SEPARATE
/// kinds and are NEVER mixed: [mixesKinds] proves a list is clean
/// before a report renders it.
///
/// LOCAL-STORE ONLY until the backend `financial_records` table
/// lands (guide §3 Phase 8): records live in PlatformLocalStore
/// area 'finance'. [FinancialRecord.toMap] already uses the guide's
/// column names, so the same maps can be sent to Supabase later.
enum FinancialRecordKind {
  platformRevenue,
  organizerRevenue,
  refund,
  payout;

  /// Guide §4 wire values (`financial_records.kind`).
  String get wireValue => switch (this) {
        FinancialRecordKind.platformRevenue => 'platform_revenue',
        FinancialRecordKind.organizerRevenue => 'organizer_revenue',
        FinancialRecordKind.refund => 'refund',
        FinancialRecordKind.payout => 'payout',
      };

  static FinancialRecordKind fromString(String? raw,
      [FinancialRecordKind fallback = FinancialRecordKind.platformRevenue]) {
    final n = (raw ?? '').toLowerCase().replaceAll(RegExp(r'[_\-\s]'), '');
    for (final k in FinancialRecordKind.values) {
      if (k.name.toLowerCase() == n) return k;
    }
    return fallback;
  }
}

/// True when a list contains BOTH platform revenue and organizer
/// revenue records — a report must never render such a list as one
/// total. Pure guard, no side effects.
bool mixesKinds(List<FinancialRecord> records) {
  var hasPlatform = false;
  var hasOrganizer = false;
  for (final r in records) {
    if (r.kind == FinancialRecordKind.platformRevenue) hasPlatform = true;
    if (r.kind == FinancialRecordKind.organizerRevenue) hasOrganizer = true;
    if (hasPlatform && hasOrganizer) return true;
  }
  return false;
}

class FinancialRecord {
  final String id;
  final String organizationId;
  final FinancialRecordKind kind;

  /// External reference (provider reference, invoice no, etc.).
  final String reference;
  final String currency;
  final double amount;
  final double taxAmount;
  final String status;
  final DateTime? reconciledAt;
  final DateTime createdAt;

  const FinancialRecord({
    required this.id,
    required this.organizationId,
    required this.kind,
    required this.reference,
    required this.currency,
    required this.amount,
    this.taxAmount = 0,
    this.status = 'pending',
    this.reconciledAt,
    required this.createdAt,
  });

  factory FinancialRecord.fromMap(Map<String, dynamic> map) {
    double numOf(Object? v) =>
        v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
    DateTime? dateOf(Object? v) =>
        v == null ? null : DateTime.tryParse(v.toString());
    return FinancialRecord(
      id: (map['id'] ?? '').toString(),
      organizationId:
          (map['organization_id'] ?? map['organizationId'] ?? '').toString(),
      kind: FinancialRecordKind.fromString(map['kind']?.toString()),
      reference: (map['reference'] ?? '').toString(),
      currency: (map['currency'] ?? '').toString(),
      amount: numOf(map['amount']),
      taxAmount: numOf(map['tax_amount'] ?? map['taxAmount']),
      status: (map['status'] ?? 'pending').toString(),
      reconciledAt:
          dateOf(map['reconciled_at'] ?? map['reconciledAt']),
      createdAt:
          dateOf(map['created_at'] ?? map['createdAt']) ?? DateTime.now(),
    );
  }

  /// Keys are the guide §4 `financial_records` column names.
  Map<String, dynamic> toMap() => {
        'id': id,
        'organization_id': organizationId,
        'kind': kind.wireValue,
        'reference': reference,
        'currency': currency,
        'amount': amount,
        'tax_amount': taxAmount,
        'status': status,
        'reconciled_at': reconciledAt?.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
      };
}

class FinancialRecordsService {
  static const String _area = 'finance';
  static const String _listId = 'records';

  static Future<List<FinancialRecord>> _loadAll() async {
    final rows = await PlatformLocalStore.loadList(_area, _listId);
    return rows.map(FinancialRecord.fromMap).toList();
  }

  /// Appends a record. Returns false when the local write failed.
  static Future<bool> addRecord(FinancialRecord record) async {
    final all = await _loadAll();
    all.add(record);
    return PlatformLocalStore.saveList(
        _area, _listId, all.map((r) => r.toMap()).toList());
  }

  /// Records for one organization only (tenant-scoped read).
  static Future<List<FinancialRecord>> listByOrganization(
      String organizationId) async {
    final all = await _loadAll();
    return all.where((r) => r.organizationId == organizationId).toList();
  }

  /// Records of one kind only — a by-kind list can never mix
  /// platform revenue with organizer revenue.
  static Future<List<FinancialRecord>> listByKind(
      FinancialRecordKind kind) async {
    final all = await _loadAll();
    return all.where((r) => r.kind == kind).toList();
  }
}
