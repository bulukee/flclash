import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_clash/services/salmon_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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
                  }),
                ),
              );
            },
          ),
        );

      expect(await SalmonService(dio: dio).fetchSupportUrl(), supportUrl);
      expect(await SalmonService(dio: dio).fetchSupportUrl(), supportUrl);
      expect(configRequests, 1);
      offline = true;
      expect(
        await SalmonService(dio: dio).fetchSupportUrl(forceRefresh: true),
        supportUrl,
      );
      expect(configRequests, 1 + salmonConfigUrls.length);
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
