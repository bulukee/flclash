import 'package:dio/dio.dart';
import 'dart:io';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:flutter/widgets.dart';
import 'package:fl_clash/services/salmon_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => AppLocalizations.load(const Locale('zh', 'CN')));
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'salmon_base_url': 'https://saved.example.com',
      'salmon_auth_data': 'session-token',
    });
  });

  test('order timeout cancels the request without replaying a POST', () async {
    final requests = <RequestOptions>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            if (options.uri.path.endsWith('/user/info')) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'data': {'id': 1},
                  },
                ),
              );
            }
            // Simulate a stalled DNS lookup or interceptor.
          },
        ),
      );
    final service = SalmonService(
      dio: dio,
      orderRequestTimeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      service.createOrder(planId: 1, cycle: 'month_price'),
      throwsA(isA<StateError>()),
    );
    expect(requests.map((request) => request.method), ['GET', 'POST', 'GET']);
    expect(
      requests.skip(1).every((request) => request.cancelToken!.isCancelled),
      isTrue,
    );
    expect(
      requests.every((request) => request.uri.host == 'saved.example.com'),
      isTrue,
    );
  });

  test(
    'a pending V2Board order is matched by period after save fails',
    () async {
      final paths = <String>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              paths.add(options.uri.path);
              if (options.method == 'POST') {
                expect((options.data as Map)['period'], 'month_price');
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response(
                      requestOptions: options,
                      statusCode: 422,
                    ),
                  ),
                );
                return;
              }
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'data': [
                      {
                        'status': 0,
                        'plan_id': 2,
                        'period': 'month_price',
                        'trade_no': 'wrong-plan',
                      },
                      {
                        'status': 0,
                        'plan_id': 1,
                        'period': 'year_price',
                        'trade_no': 'wrong-period',
                      },
                      {
                        'status': 0,
                        'plan_id': 1,
                        'period': 'month_price',
                        'trade_no': 'pending-order',
                      },
                    ],
                  },
                ),
              );
            },
          ),
        );
      expect(
        await SalmonService(
          dio: dio,
        ).createOrder(planId: 1, cycle: 'month_price'),
        'pending-order',
      );
      expect(paths.length, 3);
    },
  );

  test('checkout times out instead of spinning forever', () async {
    RequestOptions? request;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(onRequest: (options, handler) => request = options),
      );
    final service = SalmonService(
      dio: dio,
      orderRequestTimeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      service.checkoutOrder(tradeNo: 'order', method: 1),
      throwsA(isA<StateError>()),
    );
    expect(request!.cancelToken!.isCancelled, isTrue);
  });

  for (final nested in [false, true]) {
    test('accepts ${nested ? 'nested' : 'root'} checkout data', () async {
      final checkout = {'type': 1, 'data': 'https://payment.example.com/order'};
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.resolve(
              Response(
                requestOptions: options,
                data: nested ? {'data': checkout} : checkout,
              ),
            ),
          ),
        );
      expect(
        await SalmonService(
          dio: dio,
        ).checkoutOrder(tradeNo: 'order', method: 1),
        checkout,
      );
    });
  }

  for (final payload in [
    false,
    null,
    <String, dynamic>{'unexpected': true},
  ]) {
    test('rejects invalid order identifiers: $payload', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.resolve(
              Response(requestOptions: options, data: {'data': payload}),
            ),
          ),
        );
      await expectLater(
        SalmonService(dio: dio).createOrder(planId: 1, cycle: 'month_price'),
        throwsStateError,
      );
    });
  }

  test(
    'accepts balance checkout without treating true as a QR image',
    () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.resolve(
              Response(
                requestOptions: options,
                data: {'type': -1, 'data': true},
              ),
            ),
          ),
        );
      expect(
        await SalmonService(
          dio: dio,
        ).checkoutOrder(tradeNo: 'order', method: 1),
        {'type': -1, 'data': true},
      );
    },
  );

  test('payment polling respects its deadline with a stalled server', () async {
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (_, _) {}));
    final watch = Stopwatch()..start();
    expect(
      await SalmonService(dio: dio).waitForOrderCompleted(
        'order',
        timeout: const Duration(milliseconds: 40),
      ),
      isFalse,
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test(
    'a paid order returns immediately without repeated membership fetches',
    () async {
      final paths = <String>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              paths.add(options.uri.path);
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'data': [
                      {'trade_no': 'order', 'status': 3},
                    ],
                  },
                ),
              );
            },
          ),
        );
      expect(
        await SalmonService(
          dio: dio,
        ).waitForOrderCompleted('order', timeout: const Duration(seconds: 1)),
        isTrue,
      );
      expect(paths, ['/api/v1/user/order/fetch']);
    },
  );

  test('payment polling stops after leaving the purchase page', () async {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (_, _) {
            fail('Disposed page must not poll');
          },
        ),
      );
    expect(
      await SalmonService(
        dio: dio,
      ).waitForOrderCompleted('order', shouldContinue: () => false),
      isFalse,
    );
  });

  test('TLS failures are translated into a Chinese message', () {
    final error = DioException(
      requestOptions: RequestOptions(path: '/order'),
      error: const HandshakeException('Connection terminated during handshake'),
    );
    expect(salmonFriendlyError(error), '无法建立安全连接，请检查网络或稍后重试');
    expect(
      salmonFriendlyError(
        StateError('Selected subscription changed'),
        fallback: '节点更新失败',
      ),
      '节点更新失败',
    );
    expect(salmonFriendlyError(StateError('余额不足')), '余额不足');
  });

  test('blocked domain probes time out without submitting an order', () async {
    final requests = <RequestOptions>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
          },
        ),
      );
    final watch = Stopwatch()..start();
    await expectLater(
      SalmonService(
        dio: dio,
        orderRequestTimeout: const Duration(milliseconds: 20),
      ).createOrder(planId: 1, cycle: 'month_price'),
      throwsA(isA<DioException>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(requests.single.method, 'GET');
    expect(requests.single.cancelToken!.isCancelled, isTrue);
  });

  test(
    'a TLS failure before order submission does not wait for recovery lookup',
    () async {
      final methods = <String>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              methods.add(options.method);
              if (options.method == 'GET') {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    data: {
                      'data': {'id': 1},
                    },
                  ),
                );
              } else {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    error: const HandshakeException('blocked'),
                  ),
                );
              }
            },
          ),
        );
      await expectLater(
        SalmonService(dio: dio).createOrder(planId: 1, cycle: 'month_price'),
        throwsStateError,
      );
      expect(methods, ['GET', 'POST']);
    },
  );

  test(
    'checks another GitCode domain before submitting a single POST',
    () async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        'salmon_base_urls_cache_source',
        salmonConfigUrl,
      );
      await preferences.setString(
        'salmon_base_urls_cache',
        '["https://saved.example.com","https://working.example.com"]',
      );
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options);
              if (options.uri.host == 'saved.example.com') {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    error: const HandshakeException('blocked'),
                  ),
                );
                return;
              }
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'data': options.method == 'POST'
                        ? 'order-number'
                        : {'id': 1},
                  },
                ),
              );
            },
          ),
        );
      expect(
        await SalmonService(
          dio: dio,
        ).createOrder(planId: 1, cycle: 'month_price'),
        'order-number',
      );
      expect(requests.map((r) => r.method), ['GET', 'GET', 'POST']);
      expect(requests.last.uri.host, 'working.example.com');
      expect(
        preferences.getString('salmon_base_url'),
        'https://working.example.com',
      );
    },
  );
}
