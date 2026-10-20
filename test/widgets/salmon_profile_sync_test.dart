import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/services/salmon_profile_sync.dart';
import 'package:fl_clash/services/salmon_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'a signed-out account cannot select nodes and the next sync can run',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      late WidgetRef ref;
      await tester.pumpWidget(
        ProviderScope(
          child: Consumer(
            builder: (context, value, child) {
              ref = value;
              return const SizedBox();
            },
          ),
        ),
      );
      final generation = salmonService.sessionGeneration;
      await salmonService.clear();
      await expectLater(
        syncSalmonProfile(
          ref,
          'https://old.example.com/sub',
          expectedGeneration: generation,
        ),
        throwsA(isA<SalmonSessionExpiredException>()),
      );
      expect(ref.read(currentProfileIdProvider), isNull);
      // A failed/cancelled queued sync must not block the next login's work.
      await syncSalmonProfile(
        ref,
        '',
        expectedGeneration: salmonService.sessionGeneration,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
