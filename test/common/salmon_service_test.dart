import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fl_clash/services/salmon_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  test(
    'login uses the saved endpoint before refreshing remote config',
    () async {
      SharedPreferences.setMockInitialValues({
        'salmon_base_url': 'https://saved.example.com',
      });
      final requests = <String>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options.uri.toString());
              if (options.uri.path.endsWith('/passport/auth/login')) {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    data: {
                      'data': {'auth_data': 'session-token'},
                    },
                  ),
                );
              } else {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    data: {
                      'data': {
                        'subscribe_url': 'https://saved.example.com/sub',
                      },
                    },
                  ),
                );
              }
            },
          ),
        );

      final session = await SalmonService(
        dio: dio,
      ).login(account: 'user@example.com', password: 'secret');

      expect(session.baseUrl, 'https://saved.example.com');
      expect(
        requests.first,
        'https://saved.example.com/api/v1/passport/auth/login',
      );
      expect(requests, hasLength(2));
    },
  );

  test(
    'first login reaches the bootstrap endpoint without config fetch',
    () async {
      SharedPreferences.setMockInitialValues({});
      final requests = <String>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options.uri.toString());
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: options.uri.path.endsWith('/passport/auth/login')
                      ? {
                          'data': {'auth_data': 'new-token'},
                        }
                      : {
                          'data': {'subscribe_url': '/sub'},
                        },
                ),
              );
            },
          ),
        );

      final session = await SalmonService(
        dio: dio,
      ).login(account: 'user@example.com', password: 'secret');

      expect(session.baseUrl, salmonBootstrapBaseUrl);
      expect(
        requests.first,
        '$salmonBootstrapBaseUrl/api/v1/passport/auth/login',
      );
      expect(requests, hasLength(2));
    },
  );

  test('login skips the retired endpoint in saved and remote caches', () async {
    SharedPreferences.setMockInitialValues({
      'salmon_base_url': 'https://1111.swyyy.com',
      'salmon_base_urls_cache': jsonEncode([
        'https://1111.swyyy.com',
        'https://fresh.example.com',
      ]),
    });
    final requests = <String>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options.uri.toString());
            handler.resolve(
              Response(
                requestOptions: options,
                data: options.uri.path.endsWith('/passport/auth/login')
                    ? {
                        'data': {'auth_data': 'new-token'},
                      }
                    : {
                        'data': {'subscribe_url': '/sub'},
                      },
              ),
            );
          },
        ),
      );

    final session = await SalmonService(
      dio: dio,
    ).login(account: 'user@example.com', password: 'secret');

    expect(session.baseUrl, salmonBootstrapBaseUrl);
    expect(requests.every((url) => !url.contains('1111.swyyy.com')), isTrue);
  });

  test('login refreshes config after cached endpoints fail', () async {
    SharedPreferences.setMockInitialValues({
      'salmon_base_url': 'https://stale.example.com',
    });
    final requests = <String>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options.uri.toString());
            if (salmonConfigUrls.contains(
              options.uri.toString().split('?').first,
            )) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: '{"urls":["https://fresh.example.com"]}',
                ),
              );
            } else if (options.uri.host == 'fresh.example.com') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: options.uri.path.endsWith('/passport/auth/login')
                      ? {
                          'data': {'auth_data': 'fresh-token'},
                        }
                      : {
                          'data': {'subscribe_url': '/sub'},
                        },
                ),
              );
            } else {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                ),
              );
            }
          },
        ),
      );

    final session = await SalmonService(
      dio: dio,
    ).login(account: 'user@example.com', password: 'secret');

    expect(session.baseUrl, 'https://fresh.example.com');
    expect(
      requests.first,
      'https://stale.example.com/api/v1/passport/auth/login',
    );
    expect(
      requests.indexWhere((url) => url.startsWith(salmonConfigUrl)),
      greaterThan(0),
    );
    expect(requests.last, 'https://fresh.example.com/api/v1/user/getSubscribe');
  });

  test('credential rejection does not masquerade as a network error', () async {
    SharedPreferences.setMockInitialValues({});
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.reject(
            DioException(
              requestOptions: options,
              response: Response(requestOptions: options, statusCode: 401),
              type: DioExceptionType.badResponse,
            ),
          ),
        ),
      );

    expect(
      SalmonService(
        dio: dio,
      ).login(account: 'user@example.com', password: 'bad'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          '账号或密码错误',
        ),
      ),
    );
  });

  test(
    'current API credential rejection wins over stale host timeout',
    () async {
      SharedPreferences.setMockInitialValues({
        'salmon_base_url': 'https://stale.example.com',
      });
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: options.uri.host == 'ap.swywl.com'
                      ? Response(requestOptions: options, statusCode: 401)
                      : null,
                  type: options.uri.host == 'ap.swywl.com'
                      ? DioExceptionType.badResponse
                      : DioExceptionType.connectionTimeout,
                ),
              );
            },
          ),
        );

      expect(
        SalmonService(
          dio: dio,
        ).login(account: 'user@example.com', password: 'bad'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            '账号或密码错误',
          ),
        ),
      );
    },
  );
}
