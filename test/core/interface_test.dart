import 'dart:async';

import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

class _CoreHandler extends CoreHandlerInterface {
  Object? response;

  @override
  final completer = Completer<void>()..complete();

  @override
  Future<T?> invoke<T>({
    required ActionMethod method,
    dynamic data,
    Duration? timeout,
  }) async => response as T?;

  @override
  Future<String> preload() async => '';

  @override
  Future<bool> shutdown(bool isUser) async => true;

  @override
  Future<bool> destroy() async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CoreHandler handler;

  setUp(() => handler = _CoreHandler());

  test('missing core response is not an empty node list', () async {
    await expectLater(handler.getProxies(), throwsA(isA<StateError>()));
  });

  test('missing validation response does not accept a subscription', () async {
    await expectLater(
      handler.validateConfig('subscription.yaml'),
      throwsA(isA<StateError>()),
    );
  });

  test('missing config response is not a successful empty config', () async {
    await expectLater(
      handler.getConfig('subscription.yaml'),
      throwsA(isA<StateError>()),
    );
  });

  test('missing setup response does not report success', () async {
    await expectLater(
      handler.setupConfig(const SetupParams(selectedMap: {}, testUrl: '')),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'a real empty node response stays distinct from transport failure',
    () async {
      handler.response = <String, dynamic>{
        'proxies': <String, dynamic>{},
        'all': <String>[],
      };
      expect(
        await handler.getProxies(),
        const ProxiesData(proxies: {}, all: []),
      );
    },
  );

  test('a real successful validation still returns no error', () async {
    handler.response = '';
    expect(await handler.validateConfig('subscription.yaml'), isEmpty);
  });

  test('core error replies do not masquerade as node data', () async {
    await expectLater(
      handler.parasResult<Map<String, dynamic>>(
        const ActionResult(
          method: ActionMethod.getProxies,
          code: ResultType.error,
          data: 'internal panic',
        ),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('config error replies retain their Result contract', () async {
    final result = await handler.parasResult<Result>(
      const ActionResult(
        method: ActionMethod.getConfig,
        code: ResultType.error,
        data: 'invalid config',
      ),
    );
    expect(result.isError, isTrue);
  });
}
