import 'dart:async';

import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/services/salmon_service.dart';
import 'package:fl_clash/views/account.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

class _Service extends SalmonService {
  bool failLoad = false;
  bool empty = false;
  int cancels = 0;
  final canceled = Completer<void>();

  @override
  Future<List<Map<String, dynamic>>> fetchOrders({
    bool forceRefresh = false,
  }) async {
    if (failLoad) throw StateError('订单加载失败');
    if (empty) return [];
    return [
      {'trade_no': 'test-order', 'status': 0, 'total_amount': 1000},
    ];
  }

  @override
  Future<void> cancelOrder(String tradeNo) {
    cancels++;
    return canceled.future;
  }
}

Future<void> _open(WidgetTester tester, _Service service) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh', 'CN'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      supportedLocales: AppLocalizations.delegate.supportedLocales,
      home: OrdersPage(service: service),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('failed order list shows retry instead of an endless spinner', (
    tester,
  ) async {
    final service = _Service()..failLoad = true;
    await _open(tester, service);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('订单加载失败'), findsOneWidget);
    service.failLoad = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('test-order'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel errors release controls and repeated taps submit once', (
    tester,
  ) async {
    final service = _Service();
    await _open(tester, service);
    await tester.tap(find.text('取消订单'));
    await tester.tap(find.text('取消订单'));
    await tester.pump();
    expect(service.cancels, 1);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    service.canceled.completeError(StateError('取消失败'));
    await tester.pumpAndSettle();
    expect(find.text('取消失败'), findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving during cancel does not update a disposed page', (
    tester,
  ) async {
    final service = _Service();
    await _open(tester, service);
    await tester.tap(find.text('取消订单'));
    await tester.pumpWidget(const SizedBox());
    service.canceled.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
