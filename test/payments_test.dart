// WORKSTREAM F (payments / finance + notifications) — unit tests for
// lib/platform/payments/*.dart and lib/platform/notifications/*.dart
// (ChatGPT blueprint §4 + §5-6; backend guide §4 + §5-6).
//
// Pinned contracts: PaymentStatus = exactly 6 values with the guide's
// wire values; EntryModel = exactly 4 values; the payment iron rule
// (confirmed ONLY from the provider); commercial finance OFF;
// financial-record kind separation; all 10 lifecycle events produce
// non-empty title + body.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/platform/core/lifecycle.dart';
import 'package:protournament_user/platform/core/tournament_enums.dart';
import 'package:protournament_user/platform/notifications/notification_center_additions.dart';
import 'package:protournament_user/platform/payments/entry_models.dart';
import 'package:protournament_user/platform/payments/financial_records.dart';
import 'package:protournament_user/platform/payments/payment_rules.dart';
import 'package:protournament_user/platform/payments/policy_display.dart';
import 'package:protournament_user/utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

FinancialRecord _record({
  required String id,
  required String org,
  required FinancialRecordKind kind,
}) =>
    FinancialRecord(
      id: id,
      organizationId: org,
      kind: kind,
      reference: 'ref-$id',
      currency: 'PKR',
      amount: 100,
      createdAt: DateTime.utc(2026, 11, 21),
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    langUrduNotifier.value = false;
  });

  group('policies', () {
    test('policiesComplete: all three present', () {
      expect(
          policiesComplete(
              refund: 'r', cancellation: 'c', postponement: 'p'),
          isTrue);
    });

    test('policiesComplete: each single missing fails', () {
      expect(
          policiesComplete(
              refund: '', cancellation: 'c', postponement: 'p'),
          isFalse);
      expect(
          policiesComplete(
              refund: 'r', cancellation: '', postponement: 'p'),
          isFalse);
      expect(
          policiesComplete(
              refund: 'r', cancellation: 'c', postponement: ''),
          isFalse);
    });

    test('policiesComplete: whitespace-only counts as missing', () {
      expect(
          policiesComplete(
              refund: '  ', cancellation: 'c', postponement: 'p'),
          isFalse);
    });

    test('policiesComplete: all missing fails', () {
      expect(
          policiesComplete(refund: '', cancellation: '', postponement: ''),
          isFalse);
    });

    test('missingPolicies: none missing -> empty list', () {
      expect(
          missingPolicies(
              refund: 'r', cancellation: 'c', postponement: 'p'),
          isEmpty);
    });

    test('missingPolicies: lists exactly the empty ones', () {
      expect(
          missingPolicies(
              refund: '', cancellation: 'c', postponement: ''),
          ['Refund policy', 'Postponement policy']);
      expect(
          missingPolicies(
              refund: 'r', cancellation: '', postponement: 'p'),
          ['Cancellation policy']);
      expect(
          missingPolicies(refund: '', cancellation: '', postponement: ''),
          hasLength(3));
    });
  });

  group('financial records', () {
    test('mixesKinds: false for single-kind lists', () {
      expect(mixesKinds([]), isFalse);
      expect(
          mixesKinds([
            _record(id: '1', org: 'o1', kind: FinancialRecordKind.platformRevenue),
            _record(id: '2', org: 'o1', kind: FinancialRecordKind.platformRevenue),
          ]),
          isFalse);
      expect(
          mixesKinds([
            _record(id: '1', org: 'o1', kind: FinancialRecordKind.organizerRevenue),
            _record(id: '2', org: 'o1', kind: FinancialRecordKind.refund),
          ]),
          isFalse);
    });

    test('mixesKinds: true when platform + organizer revenue mix', () {
      expect(
          mixesKinds([
            _record(id: '1', org: 'o1', kind: FinancialRecordKind.platformRevenue),
            _record(id: '2', org: 'o1', kind: FinancialRecordKind.organizerRevenue),
          ]),
          isTrue);
    });

    test('toMap uses the guide §4 column names, fromMap round-trips', () {
      final record = FinancialRecord(
        id: 'r1',
        organizationId: 'org-1',
        kind: FinancialRecordKind.organizerRevenue,
        reference: 'INV-1',
        currency: 'PKR',
        amount: 500,
        taxAmount: 25,
        status: 'reconciled',
        reconciledAt: DateTime.utc(2026, 11, 20, 10, 30),
        createdAt: DateTime.utc(2026, 11, 21, 1, 0),
      );
      final map = record.toMap();
      expect(map['organization_id'], 'org-1');
      expect(map['kind'], 'organizer_revenue');
      expect(map['tax_amount'], 25);
      expect(map['reconciled_at'], '2026-11-20T10:30:00.000Z');
      expect(map['created_at'], '2026-11-21T01:00:00.000Z');
      final back = FinancialRecord.fromMap(map);
      expect(back.id, 'r1');
      expect(back.organizationId, 'org-1');
      expect(back.kind, FinancialRecordKind.organizerRevenue);
      expect(back.amount, 500);
      expect(back.taxAmount, 25);
      expect(back.status, 'reconciled');
      expect(back.reconciledAt, DateTime.utc(2026, 11, 20, 10, 30));
    });

    test('kind wire values match the guide', () {
      expect(FinancialRecordKind.platformRevenue.wireValue,
          'platform_revenue');
      expect(FinancialRecordKind.organizerRevenue.wireValue,
          'organizer_revenue');
      expect(FinancialRecordKind.refund.wireValue, 'refund');
      expect(FinancialRecordKind.payout.wireValue, 'payout');
      expect(FinancialRecordKind.values, hasLength(4));
    });

    test('service: lists by kind never mix', () async {
      await FinancialRecordsService.addRecord(
          _record(id: 'p1', org: 'o1', kind: FinancialRecordKind.platformRevenue));
      await FinancialRecordsService.addRecord(
          _record(id: 'o1', org: 'o1', kind: FinancialRecordKind.organizerRevenue));
      await FinancialRecordsService.addRecord(
          _record(id: 'o2', org: 'o2', kind: FinancialRecordKind.organizerRevenue));

      final platform = await FinancialRecordsService.listByKind(
          FinancialRecordKind.platformRevenue);
      final organizer = await FinancialRecordsService.listByKind(
          FinancialRecordKind.organizerRevenue);
      expect(platform, hasLength(1));
      expect(organizer, hasLength(2));
      expect(mixesKinds(platform), isFalse);
      expect(mixesKinds(organizer), isFalse);
      expect(mixesKinds([...platform, ...organizer]), isTrue);
    });

    test('service: listByOrganization is tenant-scoped', () async {
      await FinancialRecordsService.addRecord(
          _record(id: 'a', org: 'o1', kind: FinancialRecordKind.refund));
      await FinancialRecordsService.addRecord(
          _record(id: 'b', org: 'o2', kind: FinancialRecordKind.refund));
      final o1 =
          await FinancialRecordsService.listByOrganization('o1');
      expect(o1.map((r) => r.id), ['a']);
    });
  });

  group('payment rules (iron rule)', () {
    test('canMarkConfirmed is false without provider confirmation', () {
      expect(canMarkConfirmed(providerConfirmed: false), isFalse);
    });

    test('canMarkConfirmed is true with provider confirmation', () {
      expect(canMarkConfirmed(providerConfirmed: true), isTrue);
    });

    test('screenshot copy pins the iron rule', () {
      expect(kScreenshotNotProof, contains('screenshot'));
      expect(kScreenshotNotProof, contains('authorized payment provider'));
      expect(screenshotNotProofText, isNotEmpty);
    });

    test('commercial finance is OFF', () {
      expect(commercialFinanceEnabled, isFalse);
    });
  });

  group('enums', () {
    test('PaymentStatus has exactly 6 values, guide wire values', () {
      expect(PaymentStatus.values, hasLength(6));
      expect(
          PaymentStatus.values.map((s) => s.wireValue).toList(),
          [
            'not_required',
            'pending',
            'confirmed',
            'failed',
            'refunded',
            'under_review',
          ]);
    });

    test('EntryModel has exactly 4 values', () {
      expect(EntryModel.values, hasLength(4));
      expect(
          EntryModel.values.map((m) => m.wireValue).toList(),
          ['free', 'sponsored', 'organizer_funded', 'approved_paid']);
    });
  });

  group('lifecycle notification content', () {
    test('all 10 events produce non-empty title + body', () {
      expect(NotificationEvent.values, hasLength(10));
      for (final event in NotificationEvent.values) {
        final content = notificationContent(
            event, {'tournament': 'Test Cup', 'date': '21 Nov', 'time': '20:00', 'rank': '3'});
        expect(content.title, isNotEmpty,
            reason: '${event.name} title is empty');
        expect(content.body, isNotEmpty,
            reason: '${event.name} body is empty');
      }
    });

    test('every event has an icon', () {
      for (final event in NotificationEvent.values) {
        expect(iconForEvent(event), isA<IconData>());
      }
    });
  });

  group('widgets', () {
    testWidgets('PaymentStatusBadge shows the status label', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: PaymentStatusBadge(status: PaymentStatus.confirmed),
        ),
      ));
      expect(find.text('Confirmed'), findsOneWidget);
    });

    testWidgets('LifecycleEventChip shows the event title', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: LifecycleEventChip(
              event: NotificationEvent.roomPublished),
        ),
      ));
      expect(find.text('Room details published'), findsOneWidget);
      expect(find.byIcon(Icons.meeting_room), findsOneWidget);
    });

    testWidgets('EntryModelPicker shows the gate note for paid without approval',
        (tester) async {
      var selected = EntryModel.approvedPaid;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: EntryModelPicker(
              value: selected,
              paidApprovalSet: false,
              onChanged: (m) => selected = m,
            ),
          ),
        ),
      ));
      expect(find.textContaining('Paid entry needs Super Admin approval'),
          findsOneWidget);
      // Selection is NOT blocked: tapping Free calls onChanged.
      await tester.tap(find.text('Free'));
      expect(selected, EntryModel.free);
    });

    testWidgets('EntryModelPicker hides the gate note when approval is set',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: EntryModelPicker(
              value: EntryModel.approvedPaid,
              paidApprovalSet: true,
              onChanged: (_) {},
            ),
          ),
        ),
      ));
      expect(find.textContaining('Paid entry needs Super Admin approval'),
          findsNothing);
    });

    testWidgets('RefundPolicyDisplay shows the no-show rule for paid entry',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RefundPolicyDisplay(
              refundPolicy: 'Full refund before check-in.',
              cancellationPolicy: 'Cancelled by organizer.',
              postponementPolicy: 'Rescheduled within 7 days.',
              hasEntryFee: true,
            ),
          ),
        ),
      ));
      expect(find.textContaining('No-show: 10-minute grace'),
          findsOneWidget);
      expect(find.text('Full refund before check-in.'), findsOneWidget);
    });
  });
}
