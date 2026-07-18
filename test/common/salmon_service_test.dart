import 'dart:convert';

import 'package:fl_clash/services/salmon_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses plain and Base64 fallback URLs', () {
    final encoded = base64Encode(utf8.encode('https://backup.example.com'));
    final config = SalmonRemoteConfig.parse('''
      {
        "urls": ["https://main.example.com/"],
        "urlsBase64": ["$encoded"]
      }
    ''');

    expect(config.urls, [
      'https://main.example.com',
      'https://backup.example.com',
    ]);
  });

  test('rejects non-HTTPS remote URLs', () {
    expect(
      () => SalmonRemoteConfig.parse('{"urls":["http://example.com"]}'),
      throwsFormatException,
    );
  });

  test('parses a Base64-encoded JSON document', () {
    final source = base64Encode(
      utf8.encode(
        jsonEncode({
          'urlsBase64': [base64Encode(utf8.encode('https://ap.swywl.com'))],
        }),
      ),
    );

    expect(SalmonRemoteConfig.parse(source).urls, ['https://ap.swywl.com']);
  });
}
