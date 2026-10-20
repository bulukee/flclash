import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final type in [
    DioExceptionType.connectionError,
    DioExceptionType.connectionTimeout,
    DioExceptionType.receiveTimeout,
  ]) {
    test('retries directly after proxy $type', () async {
      final proxy = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.reject(
              DioException(requestOptions: options, type: type),
            ),
          ),
        );
      final direct = Dio();
      var requests = 0;
      direct.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests++;
            expect(options.uri.queryParameters['token'], 'test-token');
            handler.resolve(
              Response(
                requestOptions: options,
                data: Uint8List.fromList([1, 2, 3]),
              ),
            );
          },
        ),
      );
      final request = Request(
        subscriptionDio: proxy,
        directSubscriptionDio: direct,
        isProxyActive: () => true,
      );
      final response = await request.getFileResponseForUrl(
        'https://subscription.example.com/subscribe?token=test-token',
      );
      expect(response.data, [1, 2, 3]);
      expect(requests, 1);
    });
  }

  for (final type in [
    DioExceptionType.cancel,
    DioExceptionType.badCertificate,
  ]) {
    test('does not retry unsafe or cancelled requests: $type', () async {
      final proxy = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.reject(
              DioException(requestOptions: options, type: type),
            ),
          ),
        );
      var retried = false;
      final direct = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              retried = true;
              handler.reject(DioException(requestOptions: options));
            },
          ),
        );
      final request = Request(
        subscriptionDio: proxy,
        directSubscriptionDio: direct,
        isProxyActive: () => true,
      );
      await expectLater(
        request.getFileResponseForUrl(
          'https://subscription.example.com/subscribe',
        ),
        throwsA(isA<DioException>()),
      );
      expect(retried, isFalse);
    });
  }
}
