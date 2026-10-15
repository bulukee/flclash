import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/views/dashboard/dashboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [320.0, 360.0, 412.0, 600.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('dashboard width $width text scale $scale', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      DashboardQuickStats(
                        upload: '123.45 MB/s',
                        download: '987.65 MB/s',
                        mode: Mode.rule,
                        onModeTap: () {},
                      ),
                      const SizedBox(height: 12),
                      DashboardPlanSummary(
                        plan: '黄金会员长期套餐',
                        remaining: '130 GB',
                        expiry: '2026-11-10',
                        resetLabel: '今日重置流量',
                        showResetTraffic: true,
                        onResetTraffic: () {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('123.45 MB/s'), findsOneWidget);
        expect(find.text('到期 2026-11-10'), findsOneWidget);
        final title = tester.getRect(find.text('当前套餐'));
        final expiry = tester.getRect(find.text('到期 2026-11-10'));
        expect(title.overlaps(expiry), isFalse);
        if (width >= 360 && scale == 1.0) {
          expect(expiry.left, greaterThan(title.right));
          expect(
            tester.getRect(find.text('剩余 130 GB')).right,
            closeTo(expiry.right, 1),
          );
        }
      });
    }
  }

  testWidgets('unopened plans are not presented as expired', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: DashboardPlanSummary(
              plan: '未开通套餐',
              remaining: '0 GB',
              expiry: '未开通套餐',
              resetLabel: null,
              showResetTraffic: false,
              onResetTraffic: () {},
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('未开通套餐'), findsWidgets);
    expect(find.text('套餐已过期'), findsNothing);
  });
}
