import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/proxies/proxies.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final delay in [-1, 0, 120]) {
    testWidgets('node delay $delay displays the correct state', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            delayProvider(
              proxyName: 'test-node',
              testUrl: null,
            ).overrideWith((ref) => delay),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 240,
                height: 124,
                child: SalmonNodeCard(
                  proxy: const Proxy(name: 'test-node', type: 'Shadowsocks'),
                  active: false,
                  testUrl: null,
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );
      final label = delay < 0
          ? 'Timeout'
          : delay == 0
          ? '--'
          : '$delay ms';
      expect(find.text(label), findsOneWidget);
      expect(find.text('-1 ms'), findsNothing);
      if (delay < 0) {
        expect(
          tester.widget<Text>(find.text(label)).style?.color,
          Colors.redAccent,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
