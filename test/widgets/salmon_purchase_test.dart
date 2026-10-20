import 'dart:async';

import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/services/salmon_service.dart';
import 'package:fl_clash/views/purchase.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Service extends SalmonService {
  final saved = Completer<String>();
  final confirmed = Completer<bool>();
  final membership = Completer<Map<String, dynamic>>();
  int creates = 0;
  bool failPlans = false;
  bool failPayments = false;
  bool Function()? shouldPoll;

  @override
  Future<Map<String, dynamic>> refreshMembershipData() => membership.future;

  @override
  Future<List<Map<String, dynamic>>> fetchPlans({
    bool forceRefresh = false,
  }) async {
    if (failPlans) throw StateError('套餐加载失败');
    return [
      {'id': 1, 'name': 'Test plan', 'month_price': 1000},
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> fetchPaymentMethods({
    bool forceRefresh = false,
  }) async {
    if (failPayments) throw StateError('支付方式加载失败');
    return [
      {'id': 1, 'name': 'Test payment'},
    ];
  }

  @override
  Future<String> createOrder({
    required int planId,
    required String cycle,
    String? couponCode,
  }) {
    creates++;
    return saved.future;
  }

  @override
  Future<Map<String, dynamic>> checkoutOrder({
    required String tradeNo,
    required int method,
  }) async => {'type': -1, 'data': true};

  @override
  Future<bool> waitForOrderCompleted(
    String tradeNo, {
    Duration timeout = const Duration(minutes: 3),
    Duration interval = const Duration(seconds: 3),
    bool Function()? shouldContinue,
  }) {
    shouldPoll = shouldContinue;
    return confirmed.future;
  }
}

void main() {
  testWidgets(
    'store errors show retry and payment prefetch errors are observed',
    (tester) async {
      final service = _Service()
        ..failPlans = true
        ..failPayments = true;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            supportedLocales: AppLocalizations.delegate.supportedLocales,
            home: PurchaseView(service: service),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('套餐加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      service.failPlans = false;
      service.failPayments = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('立即购买'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  setUp(() {
    salmonPlansCache = null;
    salmonPaymentsCache = null;
    salmonStoreCacheAt = null;
  });

  tearDown(() {
    salmonPlansCache = null;
    salmonPaymentsCache = null;
    salmonStoreCacheAt = null;
  });

  Future<void> openStore(WidgetTester tester, _Service service) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('zh', 'CN'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          home: PurchaseView(service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('立即购买'));
    await tester.tap(find.text('立即购买'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test payment'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('confirmation releases the blocking order spinner', (
    tester,
  ) async {
    final service = _Service();
    await openStore(tester, service);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    service.saved.complete('order');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('正在等待支付到账确认'), findsOneWidget);
    expect(find.textContaining('最多等待45秒'), findsOneWidget);
    expect(service.shouldPoll!(), isTrue);
    await tester.tap(find.text('立即购买'));
    await tester.pump();
    expect(find.text('Test payment'), findsNothing);
    expect(service.creates, 1);
    service.confirmed.complete(false);
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('正在等待支付到账确认'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('order errors release the spinner and show a message', (
    tester,
  ) async {
    final service = _Service();
    await openStore(tester, service);
    service.saved.completeError(StateError('Server unavailable'));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('下单失败，请稍后重试'), findsOneWidget);
    expect(find.text('Server unavailable'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'paid orders show account sync separately and retain payment success',
    (tester) async {
      final service = _Service();
      await openStore(tester, service);
      service.saved.complete('order');
      await tester.pump();
      service.confirmed.complete(true);
      await tester.pump();
      expect(find.text('支付已到账，正在同步套餐和节点…'), findsOneWidget);
      expect(find.text('正在等待支付到账确认'), findsNothing);
      service.membership.completeError(StateError('Account refresh failed'));
      await tester.pumpAndSettle();
      expect(find.text('支付已到账，正在同步套餐和节点…'), findsNothing);
      expect(find.textContaining('支付成功'), findsOneWidget);
      expect(find.textContaining('下单失败'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('leaving purchase stops payment confirmation', (tester) async {
    final service = _Service();
    await openStore(tester, service);
    service.saved.complete('order');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
    expect(service.shouldPoll!(), isFalse);
    service.confirmed.complete(false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
