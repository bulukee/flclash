import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fl_clash/services/salmon_analytics.dart';
import 'package:fl_clash/services/salmon_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const configJson = {
    'enabled': true,
    'provider': 'matomo',
    'url': 'https://tj.swywl.com/matomo.php',
    'siteId': 2,
  };
  late List<RequestOptions> requests;
  late Dio dio;
  late SalmonAnalytics analytics;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    requests = [];
    dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            handler.resolve(Response(requestOptions: options, statusCode: 204));
          },
        ),
      );
    analytics = SalmonAnalytics(dio: dio);
  });

  tearDown(() async {
    await analytics.setEnabled(false);
    dio.close(force: true);
  });

  test('GitCode analytics is optional and does not change API domains', () {
    final config = SalmonRemoteConfig.parse(
      jsonEncode({
        'urls': ['https://api.example.com'],
        'analytics': configJson,
      }),
    );
    expect(config.urls, ['https://api.example.com']);
    expect(
      config.analytics!.endpoint.toString(),
      'https://tj.swywl.com/matomo.php',
    );
    expect(config.analytics!.siteId, 2);
    expect(
      SalmonRemoteConfig.parse(
        '{"urls":["https://api.example.com"]}',
      ).analytics,
      isNull,
    );
  });

  for (final invalid in [
    null,
    '<script>alert(1)</script>',
    {...configJson, 'enabled': false},
    {...configJson, 'provider': 'script'},
    {...configJson, 'siteId': 0},
    {...configJson, 'url': '//tj.swywl.com/matomo.php'},
    {...configJson, 'url': 'http://tj.swywl.com/matomo.php'},
    {...configJson, 'url': 'https://user:secret@tj.swywl.com/matomo.php'},
    {...configJson, 'url': 'https://tj.swywl.com/matomo.js'},
    {...configJson, 'url': 'https://tj.swywl.com/matomo.php?token_auth=secret'},
    {...configJson, 'url': 'https://tj.swywl.com/matomo.php#script'},
  ]) {
    test('ignores unsafe or disabled analytics: $invalid', () {
      expect(SalmonAnalyticsConfig.fromJson(invalid), isNull);
    });
  }

  test('no remote configuration means no tracking request', () async {
    await analytics.trackScreen(SalmonAnalyticsScreen.login);
    expect(requests, isEmpty);
  });

  test(
    'sends Matomo pageviews with one random installation ID and no account data',
    () async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('salmon_auth_data', 'private-token');
      await preferences.setString(
        'salmon_subscribe_url',
        'https://private.example.com/sub?token=secret',
      );
      analytics.configure(SalmonAnalyticsConfig.fromJson(configJson));
      await analytics.trackScreen(SalmonAnalyticsScreen.login);
      await analytics.trackScreen(SalmonAnalyticsScreen.home);
      await analytics.trackScreen(SalmonAnalyticsScreen.home);
      expect(requests, hasLength(2));
      final first = requests.first.data as Map;
      final second = requests.last.data as Map;
      expect(first['idsite'], 2);
      expect(first['rec'], 1);
      expect(first['_id'], matches(r'^[0-9a-f]{16}$'));
      expect(second['_id'], first['_id']);
      expect(first['new_visit'], 1);
      expect(second.containsKey('new_visit'), isFalse);
      expect(first['action_name'], '客户端 / 登录');
      expect(first['url'], endsWith('/login'));
      expect(jsonEncode([first, second]), isNot(contains('private')));
      expect(jsonEncode([first, second]), isNot(contains('secret')));
      expect(requests.first.headers.containsKey('Authorization'), isFalse);
      expect(requests.first.followRedirects, isFalse);
      expect(first.containsKey('token_auth'), isFalse);
    },
  );

  test(
    'a local opt out persists and cannot be overridden by GitCode',
    () async {
      await analytics.setEnabled(false);
      analytics.configure(SalmonAnalyticsConfig.fromJson(configJson));
      await analytics.trackScreen(SalmonAnalyticsScreen.home);
      final recreated = SalmonAnalytics(dio: dio);
      recreated.configure(SalmonAnalyticsConfig.fromJson(configJson));
      await recreated.trackScreen(SalmonAnalyticsScreen.home);
      expect(recreated.enabled.value, isFalse);
      expect(requests, isEmpty);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('salmon_analytics_visitor_id'), isNull);
    },
  );

  test('disabling analytics cancels in-flight reports', () async {
    final started = Completer<RequestOptions>();
    dio.interceptors.clear();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          started.complete(options);
        },
      ),
    );
    analytics.configure(SalmonAnalyticsConfig.fromJson(configJson));
    final report = analytics.trackScreen(SalmonAnalyticsScreen.plans);
    final request = await started.future;
    await analytics.setEnabled(false);
    await report;
    expect(request.cancelToken!.isCancelled, isTrue);
  });

  test('a stalled analytics server times out without throwing', () async {
    dio.interceptors.clear();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (_, _) {}));
    analytics = SalmonAnalytics(
      dio: dio,
      requestTimeout: const Duration(milliseconds: 20),
    );
    analytics.configure(SalmonAnalyticsConfig.fromJson(configJson));
    final watch = Stopwatch()..start();
    await analytics.trackScreen(SalmonAnalyticsScreen.home);
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('removing analytics in GitCode disables further reporting', () async {
    analytics.configure(SalmonAnalyticsConfig.fromJson(configJson));
    await analytics.trackScreen(SalmonAnalyticsScreen.home);
    analytics.configure(null);
    await analytics.trackScreen(SalmonAnalyticsScreen.plans);
    expect(requests, hasLength(1));
  });

  test('concurrent first page views share one installation ID', () async {
    analytics.configure(SalmonAnalyticsConfig.fromJson(configJson));
    await Future.wait([
      analytics.trackScreen(SalmonAnalyticsScreen.login),
      analytics.trackScreen(SalmonAnalyticsScreen.home),
      analytics.trackScreen(SalmonAnalyticsScreen.plans),
    ]);
    expect(requests, hasLength(3));
    expect(
      requests.map((request) => (request.data as Map)['_id']).toSet(),
      hasLength(1),
    );
  });

  test(
    'concurrent GitCode requests load analytics once without blocking API domains',
    () async {
      var configRequests = 0;
      final configDio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              configRequests++;
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: jsonEncode({
                    'urls': ['https://api.example.com'],
                    'analytics': configJson,
                  }),
                ),
              );
            },
          ),
        );
      addTearDown(() => configDio.close(force: true));
      final service = SalmonService(dio: configDio, analytics: analytics);
      final urls = await Future.wait([
        service.fetchBaseUrls(forceRefresh: true),
        service.fetchBaseUrls(forceRefresh: true),
      ]);
      expect(configRequests, 1);
      expect(urls, everyElement(['https://api.example.com']));
      await analytics.trackScreen(SalmonAnalyticsScreen.home);
      expect(requests.single.uri.toString(), 'https://tj.swywl.com/matomo.php');
    },
  );
}
