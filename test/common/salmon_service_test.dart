import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_clash/services/salmon_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final days in [15, 90, 365]) {
    test(
      'a saved login remains available after $days days without a client TTL',
      () async {
        SharedPreferences.setMockInitialValues({
          'salmon_base_url': 'https://saved.example.com',
          'salmon_auth_data': 'session-token',
          'salmon_subscribe_url': 'https://saved.example.com/sub',
          'salmon_base_urls_cache_at': DateTime.now()
              .subtract(Duration(days: days))
              .millisecondsSinceEpoch,
        });
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (_, _) =>
                  fail('Cached login should not await network'),
            ),
          );
        final service = SalmonService(dio: dio);
        expect((await service.restore())?.authData, 'session-token');
        expect(
          (await SalmonService(dio: dio).restore())?.authData,
          'session-token',
        );
      },
    );
  }

  test(
    'a blocked domain mixed with an auth rejection does not erase login',
    () async {
      SharedPreferences.setMockInitialValues({
        'salmon_base_url': 'https://saved.example.com',
        'salmon_auth_data': 'session-token',
        'salmon_subscribe_url': 'https://saved.example.com/sub',
        'salmon_base_urls_cache_source': salmonConfigUrl,
        'salmon_base_urls_cache': jsonEncode([
          'https://saved.example.com',
          'https://blocked.example.com',
        ]),
      });
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              final unauthorized = options.uri.host == 'saved.example.com';
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: unauthorized
                      ? DioExceptionType.badResponse
                      : DioExceptionType.connectionError,
                  response: unauthorized
                      ? Response(requestOptions: options, statusCode: 401)
                      : null,
                ),
              );
            },
          ),
        );
      final service = SalmonService(dio: dio);
      expect((await service.refreshSession())?.authData, 'session-token');
      expect(
        (await SharedPreferences.getInstance()).getString('salmon_auth_data'),
        'session-token',
      );
    },
  );

  test(
    'logout clears the previously selected node and in-memory account data',
    () async {
      SharedPreferences.setMockInitialValues({});
      salmonCurrentNodeName = 'old-node';
      salmonAccountCache = {'email': 'old@example.com'};
      salmonPlansCache = [
        {'id': 1},
      ];
      await SalmonService().clear();
      expect(salmonCurrentNodeName, isNull);
      expect(salmonAccountCache, isNull);
      expect(salmonPlansCache, isNull);
    },
  );
  for (final kind in ['account', 'subscription']) {
    test('rejects malformed $kind data instead of reporting no plan', () async {
      SharedPreferences.setMockInitialValues({
        'salmon_base_url': 'https://saved.example.com',
        'salmon_auth_data': 'session-token',
      });
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.resolve(
              Response(requestOptions: options, data: {'data': []}),
            ),
          ),
        );
      final service = SalmonService(dio: dio);
      await expectLater(
        kind == 'account'
            ? service.fetchUserInfo(forceRefresh: true)
            : service.fetchSubscribeInfo(forceRefresh: true),
        throwsFormatException,
      );
    });
  }
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

  test(
    'parses the optional customer service URL without changing API URLs',
    () {
      const supportUrl =
          'https://support.example.com/widget?website_token=new-inbox#/';
      final config = SalmonRemoteConfig.parse(
        jsonEncode({
          'urls': ['https://main.example.com'],
          'customerService': {'url': supportUrl},
          'updates': {
            'android': {'versionName': '1.2.11'},
          },
          'releaseNotes': ['Update'],
        }),
      );

      expect(config.urls, ['https://main.example.com']);
      expect(config.customerServiceUrl, supportUrl);
      expect(
        SalmonRemoteConfig.parse(
          '{"urls":["https://main.example.com"]}',
        ).customerServiceUrl,
        isNull,
      );
    },
  );

  test('parses and applies a remote invitation URL', () {
    const invitationUrl = 'https://swy1.sanweny.com/register?code=NoEYnmwU';
    final config = SalmonRemoteConfig.parse(
      jsonEncode({
        'urls': ['https://main.example.com'],
        'invitation': {'url': invitationUrl},
      }),
    );

    expect(config.invitationUrl, invitationUrl);
    expect(salmonInvitationCodeFromUrl(invitationUrl), 'NoEYnmwU');
    expect(
      buildSalmonInvitationUrl(invitationUrl, 'CUSTOM_CODE'),
      'https://swy1.sanweny.com/register?code=CUSTOM_CODE',
    );
  });

  test('ignores an unsafe remote invitation URL', () {
    final config = SalmonRemoteConfig.parse(
      '{"urls":["https://main.example.com"],'
      '"invitation":{"url":"http://example.com/register?code=bad"}}',
    );

    expect(config.invitationUrl, isNull);
  });

  test('keeps extra invitation query parameters when changing the code', () {
    const invitationUrl =
        'https://example.com/register?source=app&code=old-code';

    expect(
      buildSalmonInvitationUrl(invitationUrl, 'new-code'),
      'https://example.com/register?source=app&code=new-code',
    );
  });

  test('uses the default invitation URL when remote config omits it', () async {
    SharedPreferences.setMockInitialValues({});
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response(
              requestOptions: options,
              data: '{"urls":["https://main.example.com"]}',
            ),
          ),
        ),
      );

    expect(
      await SalmonService(dio: dio).fetchInvitationUrl(),
      salmonDefaultInvitationUrl,
    );
  });

  for (final supportUrl in [
    'http://support.example.com',
    'javascript:alert(1)',
    'https://user:password@support.example.com',
    '',
  ]) {
    test('ignores an unsafe customer service URL: $supportUrl', () {
      final config = SalmonRemoteConfig.parse(
        jsonEncode({
          'urls': ['https://main.example.com'],
          'customerService': {'url': supportUrl},
        }),
      );

      expect(config.customerServiceUrl, isNull);
      expect(config.urls, ['https://main.example.com']);
    });
  }

  test(
    'caches the customer service URL for offline use after restart',
    () async {
      SharedPreferences.setMockInitialValues({});
      const supportUrl =
          'https://support.example.com/widget?website_token=new-inbox#/';
      const invitationUrl =
          'https://swy1.sanweny.com/register?code=REMOTE_CODE';
      var offline = false;
      var configRequests = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              configRequests++;
              if (offline) {
                handler.reject(DioException(requestOptions: options));
                return;
              }
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: jsonEncode({
                    'urls': ['https://main.example.com'],
                    'customerService': {'url': supportUrl},
                    'invitation': {'url': invitationUrl},
                  }),
                ),
              );
            },
          ),
        );

      expect(await SalmonService(dio: dio).fetchSupportUrl(), supportUrl);
      expect(await SalmonService(dio: dio).fetchSupportUrl(), supportUrl);
      expect(await SalmonService(dio: dio).fetchInvitationUrl(), invitationUrl);
      expect(configRequests, 1);
      offline = true;
      expect(
        await SalmonService(dio: dio).fetchInvitationUrl(forceRefresh: true),
        invitationUrl,
      );
      expect(configRequests, 1 + salmonConfigUrls.length * 2);
    },
  );

  test(
    'missing customer service config keeps the default or last URL',
    () async {
      SharedPreferences.setMockInitialValues({});
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.resolve(
              Response(
                requestOptions: options,
                data: '{"urls":["https://main.example.com"]}',
              ),
            ),
          ),
        );

      expect(await SalmonService(dio: dio).fetchSupportUrl(), salmonSupportUrl);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        'salmon_customer_service_url',
        'https://support.example.com',
      );
      expect(
        await SalmonService(dio: dio).fetchSupportUrl(forceRefresh: true),
        'https://support.example.com',
      );
    },
  );

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
    'login prefers a saved domain only when GitCode still lists it',
    () async {
      SharedPreferences.setMockInitialValues({
        'salmon_base_url': 'https://saved.example.com',
      });
      final requests = <Uri>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options.uri);
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: options.uri.host == 'raw.gitcode.com'
                      ? jsonEncode({
                          'urls': [
                            'https://first.example.com',
                            'https://saved.example.com',
                          ],
                        })
                      : options.uri.path.endsWith('/passport/auth/login')
                      ? {
                          'data': {'auth_data': 'session-token'},
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

      expect(session.baseUrl, 'https://saved.example.com');
      expect(requests.map((uri) => uri.host), [
        'raw.gitcode.com',
        'saved.example.com',
        'saved.example.com',
      ]);
    },
  );
  test(
    'restore returns the cached session before network validation',
    () async {
      SharedPreferences.setMockInitialValues({
        'salmon_base_url': 'https://saved.example.com',
        'salmon_auth_data': 'session-token',
        'salmon_subscribe_url': 'https://saved.example.com/sub',
      });
      var requests = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests++;
              handler.reject(DioException(requestOptions: options));
            },
          ),
        );

      final session = await SalmonService(dio: dio).restore();

      expect(session?.baseUrl, 'https://saved.example.com');
      expect(session?.authData, 'session-token');
      expect(session?.subscribeUrl, 'https://saved.example.com/sub');
      expect(requests, 0);
    },
  );

  for (final failure in [
    'connection',
    'timeout',
    '403',
    '404',
    '503',
    'invalid',
  ]) {
    test(
      'login skips a GitCode domain after $failure and saves a working one',
      () async {
        SharedPreferences.setMockInitialValues({
          'salmon_base_url': 'https://ap.swywl.com',
          'salmon_base_urls_cache': jsonEncode(['https://old.example.com']),
        });
        final requests = <Uri>[];
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                requests.add(options.uri);
                if (options.uri.host == 'raw.gitcode.com') {
                  expect(options.data, isNull);
                  handler.resolve(
                    Response(
                      requestOptions: options,
                      data: jsonEncode({
                        'urls': [
                          'https://blocked.example.com',
                          'https://working.example.com/',
                          'https://working.example.com',
                          'https://unused.example.com',
                        ],
                      }),
                    ),
                  );
                } else if (options.uri.host == 'blocked.example.com') {
                  if (failure == 'invalid') {
                    handler.resolve(
                      Response(
                        requestOptions: options,
                        data: '<html>Blocked</html>',
                      ),
                    );
                    return;
                  }
                  final status = int.tryParse(failure);
                  handler.reject(
                    DioException(
                      requestOptions: options,
                      response: status == null
                          ? null
                          : Response(
                              requestOptions: options,
                              statusCode: status,
                            ),
                      type: status != null
                          ? DioExceptionType.badResponse
                          : failure == 'timeout'
                          ? DioExceptionType.connectionTimeout
                          : DioExceptionType.connectionError,
                    ),
                  );
                } else {
                  expect(options.uri.host, 'working.example.com');
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
                }
              },
            ),
          );

        final session = await SalmonService(
          dio: dio,
        ).login(account: 'user@example.com', password: 'secret');

        expect(session.baseUrl, 'https://working.example.com');
        expect(session.subscribeUrl, 'https://working.example.com/sub');
        expect(requests.map((uri) => uri.host), [
          'raw.gitcode.com',
          'blocked.example.com',
          'working.example.com',
          'working.example.com',
        ]);
        final preferences = await SharedPreferences.getInstance();
        expect(preferences.getString('salmon_base_url'), session.baseUrl);
        expect(
          preferences.getString('salmon_base_urls_cache_source'),
          salmonConfigUrl,
        );
      },
    );
  }

  for (final source in [
    null,
    'https://raw.githubusercontent.com/old/config.json',
    salmonConfigUrl,
  ]) {
    test(
      'GitCode outage only reuses a GitCode cache (source: $source)',
      () async {
        SharedPreferences.setMockInitialValues({
          'salmon_base_url': 'https://ap.swywl.com',
          'salmon_base_urls_cache': jsonEncode(['https://cached.example.com']),
          'salmon_base_urls_cache_source': ?source,
          'salmon_base_urls_cache_at': DateTime.now().millisecondsSinceEpoch,
        });
        final requests = <Uri>[];
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                requests.add(options.uri);
                if (options.uri.host == 'raw.gitcode.com') {
                  handler.reject(
                    DioException(
                      requestOptions: options,
                      type: DioExceptionType.connectionError,
                    ),
                  );
                } else {
                  expect(source, salmonConfigUrl);
                  expect(options.uri.host, 'cached.example.com');
                  handler.resolve(
                    Response(
                      requestOptions: options,
                      data: options.uri.path.endsWith('/passport/auth/login')
                          ? {
                              'data': {'auth_data': 'cached-token'},
                            }
                          : {
                              'data': {'subscribe_url': '/sub'},
                            },
                    ),
                  );
                }
              },
            ),
          );
        final login = SalmonService(
          dio: dio,
        ).login(account: 'user@example.com', password: 'secret');
        if (source == salmonConfigUrl) {
          expect((await login).baseUrl, 'https://cached.example.com');
          expect(requests, hasLength(4));
        } else {
          await expectLater(login, throwsStateError);
          expect(requests.map((uri) => uri.host), [
            'raw.gitcode.com',
            'raw.gitcode.com',
          ]);
        }
      },
    );
  }

  for (final config in [
    '{"urls":["https://1111.swyyy.com","http://unsafe.example.com"]}',
    '{"urls":[]}',
    '<html>Blocked</html>',
  ]) {
    test(
      'invalid GitCode config never falls back to a saved domain: $config',
      () async {
        SharedPreferences.setMockInitialValues({
          'salmon_base_url': 'https://ap.swywl.com',
        });
        final requests = <Uri>[];
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                requests.add(options.uri);
                handler.resolve(
                  Response(requestOptions: options, data: config),
                );
              },
            ),
          );
        await expectLater(
          SalmonService(
            dio: dio,
          ).login(account: 'user@example.com', password: 'secret'),
          throwsStateError,
        );
        expect(requests.map((uri) => uri.host), [
          'raw.gitcode.com',
          if (config !=
              '{"urls":["https://1111.swyyy.com","http://unsafe.example.com"]}')
            'raw.gitcode.com',
        ]);
      },
    );
  }

  test(
    'login replaces a stale GitCode cache before trying any API domain',
    () async {
      SharedPreferences.setMockInitialValues({
        'salmon_base_url': 'https://stale.example.com',
        'salmon_base_urls_cache_source': salmonConfigUrl,
        'salmon_base_urls_cache': jsonEncode(['https://stale.example.com']),
        'salmon_base_urls_cache_at': DateTime.now().millisecondsSinceEpoch,
      });
      final requests = <Uri>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options.uri);
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: options.uri.host == 'raw.gitcode.com'
                      ? '{"urls":["https://fresh.example.com"]}'
                      : options.uri.path.endsWith('/passport/auth/login')
                      ? {
                          'data': {'auth_data': 'fresh-token'},
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
      expect(session.baseUrl, 'https://fresh.example.com');
      expect(requests.map((uri) => uri.host), [
        'raw.gitcode.com',
        'fresh.example.com',
        'fresh.example.com',
      ]);
    },
  );
  test('in-flight refresh cannot restore a session after logout', () async {
    SharedPreferences.setMockInitialValues({
      'salmon_base_url': 'https://saved.example.com',
      'salmon_auth_data': 'old-token',
      'salmon_subscribe_url': 'https://saved.example.com/old-sub',
      'salmon_base_urls_cache_source': salmonConfigUrl,
      'salmon_base_urls_cache': jsonEncode(['https://saved.example.com']),
      'salmon_base_urls_cache_at': DateTime.now().millisecondsSinceEpoch,
    });
    final requestStarted = Completer<void>();
    final completeRequest = Completer<void>();
    var delayedRequestSeen = false;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            if (!delayedRequestSeen &&
                options.uri.path.endsWith('/user/getSubscribe') &&
                options.headers['Authorization'] == 'old-token') {
              delayedRequestSeen = true;
              requestStarted.complete();
              await completeRequest.future;
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'data': {'subscribe_url': '/new-sub'},
                  },
                ),
              );
              return;
            }
            if (options.uri.path.endsWith('/passport/auth/login')) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'data': {'auth_data': 'new-token'},
                  },
                ),
              );
            } else if (options.uri.path.endsWith('/user/getSubscribe') &&
                options.headers['Authorization'] == 'new-token') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'data': {'subscribe_url': '/new-sub'},
                  },
                ),
              );
            } else {
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(requestOptions: options, statusCode: 401),
                  type: DioExceptionType.badResponse,
                ),
              );
            }
          },
        ),
      );
    final service = SalmonService(dio: dio);
    final refresh = service.refreshSession();

    await requestStarted.future;
    await service.clear();
    completeRequest.complete();

    expect(await refresh, isNull);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('salmon_auth_data'), isNull);
    expect(preferences.getString('salmon_base_url'), isNull);
  });

  test('stale refresh failure cannot clear a same-token re-login', () async {
    SharedPreferences.setMockInitialValues({
      'salmon_base_url': 'https://current.example.com',
      'salmon_auth_data': 'old-token',
      'salmon_base_urls_cache_source': salmonConfigUrl,
      'salmon_base_urls_cache': jsonEncode(['https://current.example.com']),
      'salmon_base_urls_cache_at': DateTime.now().millisecondsSinceEpoch,
    });
    final requestStarted = Completer<void>();
    final completeRequest = Completer<void>();
    var delayedRequestSeen = false;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            if (!delayedRequestSeen &&
                options.uri.path.endsWith('/user/getSubscribe') &&
                options.headers['Authorization'] == 'old-token') {
              delayedRequestSeen = true;
              requestStarted.complete();
              await completeRequest.future;
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(requestOptions: options, statusCode: 401),
                  type: DioExceptionType.badResponse,
                ),
              );
              return;
            }
            if (options.uri.path.endsWith('/passport/auth/login')) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'data': {'auth_data': 'old-token'},
                  },
                ),
              );
            } else if (options.uri.path.endsWith('/user/getSubscribe') &&
                options.headers['Authorization'] == 'old-token') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'data': {'subscribe_url': '/new-sub'},
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
    final service = SalmonService(dio: dio);
    final refresh = service.refreshSession();

    await requestStarted.future;
    await service.clear();
    final newSession = await service.login(
      account: 'member@example.com',
      password: 'secret',
    );
    completeRequest.complete();

    expect(await refresh, isNull);
    final preferences = await SharedPreferences.getInstance();
    expect(newSession.authData, 'old-token');
    expect(preferences.getString('salmon_auth_data'), 'old-token');
    expect(
      preferences.getString('salmon_base_url'),
      'https://current.example.com',
    );
  });

  for (final firstFailure in ['config', 'login']) {
    test(
      'one login press recovers a transient $firstFailure failure',
      () async {
        SharedPreferences.setMockInitialValues({});
        var configAttempts = 0;
        var loginAttempts = 0;
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                final isConfig = options.uri.host == 'raw.gitcode.com';
                final isLogin = options.uri.path.endsWith(
                  '/passport/auth/login',
                );
                if (isConfig) configAttempts++;
                if (isLogin) loginAttempts++;
                if ((firstFailure == 'config' &&
                        isConfig &&
                        configAttempts == 1) ||
                    (firstFailure == 'login' &&
                        isLogin &&
                        loginAttempts == 1)) {
                  handler.reject(
                    DioException(
                      requestOptions: options,
                      type: DioExceptionType.connectionError,
                    ),
                  );
                  return;
                }
                handler.resolve(
                  Response(
                    requestOptions: options,
                    data: isConfig
                        ? '{"urls":["https://working.example.com"]}'
                        : isLogin
                        ? {
                            'data': {'auth_data': 'token'},
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
        expect(session.baseUrl, 'https://working.example.com');
        expect(configAttempts, firstFailure == 'config' ? 2 : 1);
        expect(loginAttempts, firstFailure == 'login' ? 2 : 1);
      },
    );
  }

  test('credential rejection does not masquerade as a network error', () async {
    SharedPreferences.setMockInitialValues({
      'salmon_base_urls_cache_source': salmonConfigUrl,
      'salmon_base_urls_cache': jsonEncode(['https://current.example.com']),
    });
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

  test('a blocked domain does not report an incorrect password', () async {
    SharedPreferences.setMockInitialValues({
      'salmon_base_urls_cache_source': salmonConfigUrl,
      'salmon_base_urls_cache': jsonEncode(['https://blocked.example.com']),
    });
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.reject(
            DioException(
              requestOptions: options,
              response: Response(requestOptions: options, statusCode: 403),
              type: DioExceptionType.badResponse,
            ),
          ),
        ),
      );
    await expectLater(
      SalmonService(
        dio: dio,
      ).login(account: 'user@example.com', password: 'secret'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          isNot('账号或密码错误'),
        ),
      ),
    );
  });
  test(
    'authenticated GET requests fail over to a healthy cached endpoint',
    () async {
      SharedPreferences.setMockInitialValues({
        'salmon_base_url': 'https://stale.example.com',
        'salmon_auth_data': 'session-token',
        'salmon_base_urls_cache_source': salmonConfigUrl,
        'salmon_base_urls_cache': jsonEncode(['https://fresh.example.com']),
        'salmon_base_urls_cache_at': DateTime.now().millisecondsSinceEpoch,
      });
      final requests = <String>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options.uri.toString());
              if (options.uri.host == 'fresh.example.com') {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    data: {
                      'data': {'email': 'fresh@example.com'},
                    },
                  ),
                );
                return;
              }
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                ),
              );
            },
          ),
        );

      final result = await SalmonService(
        dio: dio,
      ).fetchUserInfo(forceRefresh: true);

      expect(result['email'], 'fresh@example.com');
      expect(requests, contains('https://fresh.example.com/api/v1/user/info'));
      expect(
        (await SharedPreferences.getInstance()).getString('salmon_base_url'),
        'https://fresh.example.com',
      );
    },
  );

  test(
    'force refresh keeps stale account data during a network outage',
    () async {
      SharedPreferences.setMockInitialValues({
        'salmon_base_url': 'https://saved.example.com',
        'salmon_auth_data': 'session-token',
        'salmon_user_data_cache': jsonEncode({
          'email': 'cached@example.com',
          'plan_name': '黄金会员',
        }),
        'salmon_user_data_cache.at': DateTime.now().millisecondsSinceEpoch,
      });
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionTimeout,
              ),
            ),
          ),
        );

      final result = await SalmonService(
        dio: dio,
      ).fetchUserInfo(forceRefresh: true);

      expect(result['email'], 'cached@example.com');
      expect(result['plan_name'], '黄金会员');
    },
  );

  test('all authenticated 401 responses clear the saved session', () async {
    SharedPreferences.setMockInitialValues({
      'salmon_base_url': 'https://saved.example.com',
      'salmon_auth_data': 'session-token',
      'salmon_base_urls_cache_source': salmonConfigUrl,
      'salmon_base_urls_cache': jsonEncode(['https://saved.example.com']),
      'salmon_base_urls_cache_at': DateTime.now().millisecondsSinceEpoch,
    });
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

    await expectLater(
      SalmonService(dio: dio).fetchUserInfo(forceRefresh: true),
      throwsA(isA<SalmonSessionExpiredException>()),
    );
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('salmon_base_url'), isNull);
    expect(preferences.getString('salmon_auth_data'), isNull);
  });

  test('successful authenticated responses may contain null data', () async {
    SharedPreferences.setMockInitialValues({
      'salmon_base_url': 'https://saved.example.com',
      'salmon_auth_data': 'session-token',
    });
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response(requestOptions: options, data: {'data': null}),
          ),
        ),
      );

    await SalmonService(dio: dio).generateInvite();
  });

  test(
    'keeps the account plan when the plan catalog is temporarily empty',
    () async {
      SharedPreferences.setMockInitialValues({
        'salmon_base_url': 'https://saved.example.com',
        'salmon_auth_data': 'session-token',
      });
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              final path = options.uri.path;
              final data = path.endsWith('/user/info')
                  ? {'plan_id': 7, 'transfer_enable': 100}
                  : path.endsWith('/user/getSubscribe')
                  ? {'plan_id': 7, 'plan_name': '暂无套餐', 'transfer_enable': 100}
                  : path.endsWith('/user/plan/fetch')
                  ? <dynamic>[]
                  : <dynamic>[];
              handler.resolve(
                Response(requestOptions: options, data: {'data': data}),
              );
            },
          ),
        );

      final result = await SalmonService(dio: dio).refreshMembershipData();

      expect(result['plan_name'], '已有套餐');
      expect(result['plan_quota_gb'], 100);
    },
  );

  test('customer service reuses the conversation after reopening', () async {
    SharedPreferences.setMockInitialValues({});
    var contactsCreated = 0;
    var conversationsCreated = 0;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final path = options.uri.path;
            if (options.method == 'POST' && path.endsWith('/contacts')) {
              contactsCreated++;
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {'source_id': 'contact-$contactsCreated'},
                ),
              );
            } else if (options.method == 'POST' &&
                path.endsWith('/conversations')) {
              conversationsCreated++;
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {'id': conversationsCreated},
                ),
              );
            } else if (options.method == 'GET' && path.endsWith('/messages')) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'payload': [
                      {'id': 12, 'content': '继续上次会话'},
                    ],
                  },
                ),
              );
            } else {
              handler.reject(DioException(requestOptions: options));
            }
          },
        ),
      );

    final first = await SalmonService(
      dio: dio,
    ).prepareChatwoot(' Member@Example.com ');
    final reopened = await SalmonService(
      dio: dio,
    ).prepareChatwoot('member@example.com');
    expect(reopened, first);
    expect(first, {'source_id': 'contact-1', 'conversation_id': 1});
    expect(contactsCreated, 1);
    expect(conversationsCreated, 1);
    expect(
      await SalmonService(dio: dio).fetchChatwootMessages('contact-1', 1),
      [
        {'id': 12, 'content': '继续上次会话'},
      ],
    );

    final other = await SalmonService(
      dio: dio,
    ).prepareChatwoot('other@example.com');
    expect(other, {'source_id': 'contact-2', 'conversation_id': 2});
    expect(contactsCreated, 2);
    expect(conversationsCreated, 2);
  });

  test('customer service refuses an unidentified account', () async {
    SharedPreferences.setMockInitialValues({});
    final service = SalmonService(dio: Dio());
    await expectLater(service.prepareChatwoot('  '), throwsStateError);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('salmon_chatwoot_contact'), isNull);
  });

  test('remote customer service API keeps its saved conversation', () async {
    SharedPreferences.setMockInitialValues({});
    final paths = <String>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (salmonConfigUrls.contains(
              options.uri.toString().split('?').first,
            )) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: jsonEncode({
                    'urls': ['https://main.example.com'],
                    'customerService': {
                      'url':
                          'https://support.example.com/widget?website_token=new-inbox#/',
                    },
                  }),
                ),
              );
              return;
            }
            expect(options.uri.host, 'support.example.com');
            paths.add(options.uri.path);
            handler.resolve(
              Response(
                requestOptions: options,
                data: options.uri.path.endsWith('/contacts')
                    ? {'source_id': 'saved-contact'}
                    : options.uri.path.endsWith('/conversations')
                    ? {'id': 42}
                    : {'payload': []},
              ),
            );
          },
        ),
      );

    final firstService = SalmonService(dio: dio);
    final first = await firstService.prepareChatwoot('member@example.com');
    final reopenedService = SalmonService(dio: dio);
    expect(await reopenedService.prepareChatwoot('member@example.com'), first);
    await reopenedService.fetchChatwootMessages('saved-contact', 42);
    expect(paths, [
      '/public/api/v1/inboxes/new-inbox/contacts',
      '/public/api/v1/inboxes/new-inbox/contacts/saved-contact/conversations',
      '/public/api/v1/inboxes/new-inbox/contacts/saved-contact/conversations/42/messages',
    ]);
  });

  test(
    'changing customer service does not send old IDs to the new inbox',
    () async {
      SharedPreferences.setMockInitialValues({});
      var inbox = 'first-inbox';
      var contactsCreated = 0;
      var conversationsCreated = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (salmonConfigUrls.contains(
                options.uri.toString().split('?').first,
              )) {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    data: jsonEncode({
                      'urls': ['https://main.example.com'],
                      'customerService': {
                        'url':
                            'https://support.example.com/widget?website_token=$inbox#/',
                      },
                    }),
                  ),
                );
                return;
              }
              expect(
                options.uri.path,
                startsWith('/public/api/v1/inboxes/$inbox/'),
              );
              if (options.uri.path.endsWith('/contacts')) {
                contactsCreated++;
                handler.resolve(
                  Response(
                    requestOptions: options,
                    data: {'source_id': 'contact-$contactsCreated'},
                  ),
                );
              } else {
                conversationsCreated++;
                handler.resolve(
                  Response(
                    requestOptions: options,
                    data: {'id': conversationsCreated},
                  ),
                );
              }
            },
          ),
        );
      final service = SalmonService(dio: dio);
      expect(await service.prepareChatwoot('member@example.com'), {
        'source_id': 'contact-1',
        'conversation_id': 1,
      });
      inbox = 'second-inbox';
      await service.fetchSupportUrl(forceRefresh: true);
      final changed = await service.prepareChatwoot('member@example.com');
      expect(changed, {'source_id': 'contact-2', 'conversation_id': 2});
      expect(await service.prepareChatwoot('member@example.com'), changed);
      expect(contactsCreated, 2);
      expect(conversationsCreated, 2);
    },
  );

  test('the default inbox keeps sessions saved by older clients', () async {
    SharedPreferences.setMockInitialValues({
      'salmon_chatwoot_email': 'member@example.com',
      'salmon_chatwoot_contact': 'existing-contact',
      'salmon_chatwoot_conversation': 42,
      'salmon_base_urls_cache_source': salmonConfigUrl,
      'salmon_base_urls_cache': jsonEncode(['https://main.example.com']),
      'salmon_base_urls_cache_at': DateTime.now().millisecondsSinceEpoch,
    });
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            fail('The existing conversation should not make an HTTP request');
          },
        ),
      );

    expect(
      await SalmonService(dio: dio).prepareChatwoot('member@example.com'),
      {'source_id': 'existing-contact', 'conversation_id': 42},
    );
  });

  test('a config refresh does not redirect an active conversation', () async {
    SharedPreferences.setMockInitialValues({
      'salmon_chatwoot_email': 'member@example.com',
      'salmon_chatwoot_contact': 'existing-contact',
      'salmon_chatwoot_conversation': 42,
      'salmon_base_urls_cache_source': salmonConfigUrl,
      'salmon_base_urls_cache': jsonEncode(['https://main.example.com']),
      'salmon_base_urls_cache_at': DateTime.now().millisecondsSinceEpoch,
    });
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (salmonConfigUrls.contains(
              options.uri.toString().split('?').first,
            )) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: jsonEncode({
                    'urls': ['https://main.example.com'],
                    'customerService': {
                      'url':
                          'https://support.example.com/widget?website_token=new-inbox#/',
                    },
                  }),
                ),
              );
              return;
            }
            expect(options.uri.host, 'chat.swywl.com');
            expect(
              options.uri.path,
              endsWith('/contacts/existing-contact/conversations/42/messages'),
            );
            handler.resolve(
              Response(requestOptions: options, data: {'payload': []}),
            );
          },
        ),
      );
    final service = SalmonService(dio: dio);
    await service.prepareChatwoot('member@example.com');
    await service.fetchSupportUrl(forceRefresh: true);
    await service.fetchChatwootMessages('existing-contact', 42);
  });

  test(
    'customer service uploads an attachment to the saved conversation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'salmon-chat-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(
        '${directory.path}${Platform.pathSeparator}example.txt',
      );
      await file.writeAsString('test attachment');
      String? requestPath;
      FormData? uploaded;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requestPath = options.uri.path;
              uploaded = options.data as FormData;
              handler.resolve(
                Response(requestOptions: options, data: {'id': 3}),
              );
            },
          ),
        );

      await SalmonService(dio: dio).sendChatwootAttachment(
        'saved-contact',
        42,
        file.path,
        file.uri.pathSegments.last,
      );

      expect(
        requestPath,
        endsWith('/contacts/saved-contact/conversations/42/messages'),
      );
      expect(uploaded!.files.single.key, 'attachments[]');
      expect(uploaded!.files.single.value.filename, 'example.txt');
    },
  );
}
