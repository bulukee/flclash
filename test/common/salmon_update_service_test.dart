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

  group('SalmonUpdateService.selectMacOSUpdateConfig', () {
    const source = <String, dynamic>{
      'versionName': '1.2.25',
      'versionCode': 2026101701,
      'arm64Url': 'https://client.example.com/Salmon-macOS-arm64-1.2.25.dmg',
      'arm64Sha256': 'arm-hash',
      'x64Url': 'https://client.example.com/Salmon-macOS-x64-1.2.25.dmg',
      'x64Sha256': 'x64-hash',
    };

    test('selects the Apple Silicon package and its checksum', () {
      final selected = SalmonUpdateService.selectMacOSUpdateConfig(
        source,
        arm64: true,
      );
      final update = SalmonAppUpdate.fromJson(selected);

      expect(
        update.url,
        'https://client.example.com/Salmon-macOS-arm64-1.2.25.dmg',
      );
      expect(update.sha256Value, 'arm-hash');
    });

    test('selects the Intel package and its checksum', () {
      final selected = SalmonUpdateService.selectMacOSUpdateConfig(
        source,
        arm64: false,
      );
      final update = SalmonAppUpdate.fromJson(selected);

      expect(
        update.url,
        'https://client.example.com/Salmon-macOS-x64-1.2.25.dmg',
      );
      expect(update.sha256Value, 'x64-hash');
    });
  });

  group('SalmonUpdateService.selectUpdateResult', () {
    final installedVersion = '1.2.25';
    final installedCode = 2026101502;
    final remote125 = SalmonAppUpdate.fromJson({
      'versionName': '1.2.25',
      'versionCode': 2026101701,
      'url': 'https://client.example.com/1.2.25.exe',
    });
    test('returns the update from the valid remote manifest', () {
      final selected = SalmonUpdateService.selectUpdateResult(
        remoteUpdate: remote125,
        hasValidRemoteConfig: true,
        installedVersion: installedVersion,
        installedVersionCode: installedCode,
      );

      expect(selected?.version, '1.2.25');
      expect(selected?.url, remote125.url);
    });

    test('a valid current remote release means no update is available', () {
      final selected = SalmonUpdateService.selectUpdateResult(
        remoteUpdate: null,
        hasValidRemoteConfig: true,
        installedVersion: '1.2.25',
        installedVersionCode: 2026101701,
      );

      expect(selected, isNull);
    });

    test('does not offer an update when the primary manifest fails', () {
      final selected = SalmonUpdateService.selectUpdateResult(
        remoteUpdate: null,
        hasValidRemoteConfig: false,
        installedVersion: installedVersion,
        installedVersionCode: installedCode,
      );

      expect(selected, isNull);
    });
  });
}
