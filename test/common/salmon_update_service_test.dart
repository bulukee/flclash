import 'package:fl_clash/services/salmon_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SalmonUpdateService.isNewerThanInstalled', () {
    test('recognizes the 1.2.20 release for an older client', () {
      final update = SalmonAppUpdate.fromJson({
        'versionName': '1.2.20',
        'versionCode': 2026101501,
        'url':
            'https://client.sanweny.com/swywl/Salmon-Windows-x64-1.2.20-Setup.exe',
      });

      expect(
        SalmonUpdateService.isNewerThanInstalled(update, '1.2.15', 2026101401),
        isTrue,
      );
    });

    test('does not treat the stale 1.1.22 config as an update', () {
      final update = SalmonAppUpdate.fromJson({
        'versionName': '1.1.22',
        'versionCode': 2,
        'url': 'https://client.swywl.com/swywl/old-installer.exe',
      });

      expect(
        SalmonUpdateService.isNewerThanInstalled(update, '1.2.15', 2026101401),
        isFalse,
      );
    });

    test('clears the pending update condition after installation', () {
      final update = SalmonAppUpdate.fromJson({
        'versionName': '1.2.20',
        'versionCode': 2026101501,
        'url':
            'https://client.sanweny.com/swywl/Salmon-Windows-x64-1.2.20-Setup.exe',
      });

      expect(
        SalmonUpdateService.isNewerThanInstalled(update, '1.2.20', 2026101501),
        isFalse,
      );
    });
  });
}
