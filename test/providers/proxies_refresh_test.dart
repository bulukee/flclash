import 'dart:async';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:flutter/widgets.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';

class _Controller extends Mock implements CoreController {}

class _ProxiesAction extends ProxiesAction {
  final CoreController testController;

  _ProxiesAction(this.testController);

  @override
  CoreController get controller => testController;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => AppLocalizations.load(const Locale('zh', 'CN')));

  const oldGroups = [Group(type: GroupType.Selector, name: 'old')];
  const newGroups = [Group(type: GroupType.Selector, name: 'new')];
  const profile = Profile(
    id: 1,
    url: 'https://subscription.example.com/a',
    autoUpdateDuration: Duration(days: 1),
  );
  late _Controller controller;
  late ProviderContainer container;
  late Future<List<Group>> Function() fetch;
  late int calls;

  setUp(() {
    controller = _Controller();
    calls = 0;
    fetch = () async => newGroups;
    when(
      () => controller.getProxiesGroups(
        sortType: ProxiesSortType.none,
        delayMap: {},
        selectedMap: {},
        defaultTestUrl: const AppSettingProps().testUrl,
      ),
    ).thenAnswer((_) {
      calls++;
      return fetch();
    });
    container = ProviderContainer(
      overrides: [
        currentProfileProvider.overrideWith((ref) {
          final id = ref.watch(currentProfileIdProvider);
          return id == null ? null : profile.copyWith(id: id);
        }),
        currentProfileIdProvider.overrideWithBuild((_, _) => 1),
        proxiesStyleSettingProvider.overrideWithBuild(
          (_, _) => const ProxiesStyleProps(sortType: ProxiesSortType.none),
        ),
        groupsProvider.overrideWithBuild((_, _) => oldGroups),
        proxiesActionProvider.overrideWith(() => _ProxiesAction(controller)),
      ],
    );
    addTearDown(container.dispose);
  });

  test('failed reads retry without erasing current profile nodes', () async {
    fetch = () async => throw StateError('Core disconnected');
    await container.read(proxiesActionProvider.notifier).updateGroups();
    expect(calls, 3);
    expect(container.read(groupsProvider), oldGroups);
  });

  test('empty transient responses do not erase cached nodes', () async {
    fetch = () async => [];
    await container.read(proxiesActionProvider.notifier).updateGroups();
    expect(calls, 3);
    expect(container.read(groupsProvider), oldGroups);
  });

  test('manual refresh reports failure instead of success', () async {
    fetch = () async => throw StateError('Core unavailable');
    await expectLater(
      container
          .read(proxiesActionProvider.notifier)
          .updateGroups(throwOnError: true),
      throwsA(isA<StateError>()),
    );
    expect(container.read(groupsProvider), oldGroups);
  });

  test('a temporary failure can recover on the next attempt', () async {
    fetch = () async {
      if (calls == 1) throw StateError('Core busy');
      return newGroups;
    };
    await container.read(proxiesActionProvider.notifier).updateGroups();
    expect(calls, 2);
    expect(container.read(groupsProvider), newGroups);
  });

  test('a late older request cannot overwrite newer nodes', () async {
    final delayed = Completer<List<Group>>();
    fetch = () => calls == 1 ? delayed.future : Future.value(newGroups);
    final action = container.read(proxiesActionProvider.notifier);
    final first = action.updateGroups();
    await action.updateGroups();
    delayed.complete(oldGroups);
    await first;
    expect(container.read(groupsProvider), newGroups);
  });

  test(
    'changing profiles clears old nodes and rejects an in-flight read',
    () async {
      final delayed = Completer<List<Group>>();
      fetch = () => delayed.future;
      final pending = container
          .read(proxiesActionProvider.notifier)
          .updateGroups();
      container.read(currentProfileIdProvider.notifier).value = 2;
      await container.pump();
      delayed.complete(newGroups);
      await pending;
      expect(container.read(groupsProvider), isEmpty);
    },
  );

  test('signing out removes the previous profile nodes', () async {
    container.read(proxiesActionProvider.notifier);
    container.read(currentProfileIdProvider.notifier).value = null;
    await container.pump();
    expect(container.read(groupsProvider), isEmpty);
    await container.read(proxiesActionProvider.notifier).updateGroups();
    expect(calls, 0);
  });
}
