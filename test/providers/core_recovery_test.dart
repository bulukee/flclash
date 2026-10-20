import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';

class _Controller extends Mock implements CoreController {}

class _CoreAction extends CoreAction {
  final CoreController testController;
  _CoreAction(this.testController);
  @override
  CoreController get controller => testController;
}

class _SetupAction extends SetupAction {
  int applications = 0;
  bool fail = false;

  @override
  Future<void> applyProfile({
    bool silence = false,
    bool force = false,
    bool throwOnError = false,
    VoidCallback? preloadInvoke,
  }) async {
    expect(force, isTrue);
    expect(throwOnError, isTrue);
    applications++;
    if (fail) throw StateError('Config could not be restored');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Controller controller;
  late _SetupAction setup;
  late ProviderContainer container;

  setUp(() {
    controller = _Controller();
    setup = _SetupAction();
    when(() => controller.preload()).thenAnswer((_) async => '');
    when(() => controller.isInit).thenAnswer((_) async => false);
    when(() => controller.init(0)).thenAnswer((_) async => true);
    when(() => controller.startListener()).thenAnswer((_) async => true);
    globalState.lastConfigMd5 = 'previous-core-config';
    container = ProviderContainer(
      overrides: [
        coreActionProvider.overrideWith(() => _CoreAction(controller)),
        setupActionProvider.overrideWith(() => setup),
      ],
    );
    addTearDown(() {
      container.dispose();
      globalState.lastConfigMd5 = null;
    });
  });

  test('a recovered core reloads the selected config', () async {
    expect(
      await container.read(coreActionProvider.notifier).recoverCore(),
      isTrue,
    );
    expect(setup.applications, 1);
    expect(globalState.lastConfigMd5, isNull);
  });

  test('initialization failure is not reported as recovery', () async {
    when(() => controller.init(0)).thenAnswer((_) async => false);
    expect(
      await container.read(coreActionProvider.notifier).recoverCore(),
      isFalse,
    );
    expect(setup.applications, 0);
  });

  test('concurrent recovery requests share one connection attempt', () async {
    final action = container.read(coreActionProvider.notifier);
    expect(await Future.wait([action.recoverCore(), action.recoverCore()]), [
      true,
      true,
    ]);
    verify(() => controller.preload()).called(1);
    expect(setup.applications, 1);
  });

  test('recovery restores listeners only when the proxy was running', () async {
    container.read(runTimeProvider.notifier).value = 1;
    expect(
      await container.read(coreActionProvider.notifier).recoverCore(),
      isTrue,
    );
    verify(() => controller.startListener()).called(1);
  });

  test(
    'preload failure resets connecting state and stops initialization',
    () async {
      when(
        () => controller.preload(),
      ).thenThrow(StateError('Core unavailable'));
      expect(
        await container.read(coreActionProvider.notifier).recoverCore(),
        isFalse,
      );
      expect(container.read(coreStatusProvider), CoreStatus.disconnected);
      verifyNever(() => controller.init(0));
      expect(setup.applications, 0);
    },
  );

  test('a preload error message cannot be treated as a connection', () async {
    when(() => controller.preload()).thenAnswer((_) async => 'Bind failed');
    expect(
      await container.read(coreActionProvider.notifier).recoverCore(),
      isFalse,
    );
    expect(container.read(coreStatusProvider), CoreStatus.disconnected);
    verifyNever(() => controller.init(0));
  });

  test('configuration reload failure is not reported as recovery', () async {
    setup.fail = true;
    expect(
      await container.read(coreActionProvider.notifier).recoverCore(),
      isFalse,
    );
    expect(setup.applications, 1);
  });
}
