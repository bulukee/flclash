import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/services/salmon_analytics.dart';
import 'package:fl_clash/widgets/salmon_analytics_setting.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'the Chinese statistics switch discloses data and persists opt out',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final analytics = SalmonAnalytics();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh', 'CN'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          home: Scaffold(body: SalmonAnalyticsSetting(analytics: analytics)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('使用统计'), findsOneWidget);
      expect(find.textContaining('统计服务器会收到网络 IP'), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
      await tester.tap(find.text('使用统计'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'salmon_analytics_enabled',
        ),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
