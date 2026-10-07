import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _delayCacheKey = 'salmon_delay_cache_v1';
const _delayCacheAtKey = 'salmon_delay_cache_at_v1';
bool _delayCacheRestored = false;

const _delayAttemptCount = 2;
const _delayBatchSize = 10;

/// Restores the last successful delay values immediately. The values remain
/// useful for 90 days and are replaced in the background by the next test.
Future<void> restoreDelayCache() async {
  if (_delayCacheRestored) return;
  _delayCacheRestored = true;
  try {
    final preferences = await SharedPreferences.getInstance();
    final cachedAt = preferences.getInt(_delayCacheAtKey);
    if (cachedAt == null ||
        DateTime.now().millisecondsSinceEpoch - cachedAt >
            const Duration(days: 90).inMilliseconds) {
      return;
    }
    final raw = preferences.getString(_delayCacheKey);
    if (raw == null || raw.isEmpty) return;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    final notifier = globalState.container.read(proxiesActionProvider.notifier);
    for (final urlEntry in decoded.entries) {
      final url = urlEntry.key.toString();
      final values = urlEntry.value;
      if (values is! Map) continue;
      for (final nodeEntry in values.entries) {
        final value = (nodeEntry.value as num?)?.toInt();
        if (value == null || value <= 0) continue;
        notifier.setDelay(
          Delay(name: nodeEntry.key.toString(), url: url, value: value),
        );
      }
    }
  } catch (_) {
    // A damaged cache is non-fatal; a successful test will replace it.
  }
}

Future<void> _persistDelayCache() async {
  try {
    final source = globalState.container.read(delayDataSourceProvider);
    final cache = <String, Map<String, int>>{};
    for (final urlEntry in source.entries) {
      final values = <String, int>{};
      for (final nodeEntry in urlEntry.value.entries) {
        final value = nodeEntry.value;
        if (value != null && value > 0) values[nodeEntry.key] = value;
      }
      if (values.isNotEmpty) cache[urlEntry.key] = values;
    }
    if (cache.isEmpty) return;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_delayCacheKey, jsonEncode(cache));
    await preferences.setInt(
      _delayCacheAtKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  } catch (_) {
    // Cache persistence must never affect the actual network test.
  }
}

double get listHeaderHeight {
  final measure = globalState.measure;
  return 20 + measure.titleMediumHeight + 4 + measure.bodyMediumHeight + 2;
}

double getItemHeight(ProxyCardType proxyCardType) {
  final measure = globalState.measure;
  final baseHeight =
      16 + measure.bodyMediumHeight * 2 + measure.bodySmallHeight + 8 + 4;
  return switch (proxyCardType) {
    ProxyCardType.expand => baseHeight + measure.labelSmallHeight + 6,
    ProxyCardType.shrink => baseHeight,
    ProxyCardType.min => baseHeight - measure.bodyMediumHeight,
  };
}

List<Group> getCurrentGroups() {
  return globalState.container.read(currentGroupsStateProvider).value;
}

List<Group> getGroups() {
  return globalState.container.read(groupsProvider);
}

String? getCurrentGroupName() {
  return globalState.container.read(
    currentProfileProvider.select((state) => state?.currentGroupName),
  );
}

void updateCurrentGroupName(String groupName) {
  globalState.container
      .read(proxiesActionProvider.notifier)
      .updateCurrentGroupName(groupName);
}

void updateCurrentUnfoldSet(Set<String> value) {
  globalState.container
      .read(proxiesActionProvider.notifier)
      .updateCurrentUnfoldSet(value);
}

Future<void> proxyDelayTest(Proxy proxy, [String? testUrl]) async {
  final ref = globalState.container;
  final groups = getGroups();
  final selectedMap = ref.read(
    currentProfileProvider.select((state) => state?.selectedMap ?? {}),
  );
  final state = computeRealSelectedProxyState(
    proxy.name,
    groups: groups,
    selectedMap: selectedMap,
  );
  final displayDelayUrl = state.testUrl.takeFirstValid([
    ref.read(realTestUrlProvider(testUrl)),
  ]);
  if (state.proxyName.isEmpty) {
    return;
  }
  final delaySource = ref.read(delayDataSourceProvider.notifier);
  delaySource.beginDelayTest(state.proxyName);
  // Test every node exactly twice and keep the lowest successful RTT. The UI
  // converts this raw RTT to an explicitly labelled one-way estimate.
  int? measuredDelay;
  try {
    for (var attempt = 0; attempt < _delayAttemptCount; attempt++) {
      try {
        final result = await coreController.getDelay(
          defaultTestUrl,
          state.proxyName,
        );
        final value = result.value;
        if (value != null && value > 0) {
          measuredDelay = measuredDelay == null || value < measuredDelay
              ? value
              : measuredDelay;
        }
      } catch (_) {
        // A second attempt may still succeed; keep the last cached value if both
        // attempts fail.
      }
    }
    // Keep the last successful result if both probes fail. The measured
    // minimum overrides any individual core event buffered during the test.
    if (measuredDelay != null) {
      final notifier = ref.read(proxiesActionProvider.notifier);
      notifier.setDelay(
        Delay(
          url: displayDelayUrl,
          name: state.proxyName,
          value: measuredDelay,
        ),
      );
      if (proxy.name.isNotEmpty && proxy.name != state.proxyName) {
        notifier.setDelay(
          Delay(url: displayDelayUrl, name: proxy.name, value: measuredDelay),
        );
      }
    }
  } finally {
    delaySource.endDelayTest(state.proxyName);
  }
  if (measuredDelay != null && !delaySource.isTesting) {
    await _persistDelayCache();
  }
}

/// Mihomo URLTest reports a request round trip.  The desktop product displays
/// an estimated one-way value so the meaning is explicit and the core result
/// remains untouched for sorting and diagnostics.
int? estimatedOneWayDelay(int? roundTripDelay) {
  if (roundTripDelay == null || roundTripDelay <= 0) return roundTripDelay;
  return (roundTripDelay / 2).round();
}

Future<void> delayTest(
  List<Proxy> proxies, [
  String? testUrl,
  String? groupName,
]) async {
  // Do not use the group-delay endpoint here: several subscriptions return
  // aliases that do not match the visible card names, leaving cards at `--`.
  // Ten parallel nodes keeps the test responsive without flooding the core.
  for (final proxyBatch in proxies.batch(_delayBatchSize)) {
    await Future.wait(
      proxyBatch.map((proxy) => proxyDelayTest(proxy, testUrl)),
    );
  }
  globalState.container.read(sortNumProvider.notifier).add();
  await _persistDelayCache();
}

double getScrollToSelectedOffset({
  required String groupName,
  required List<Proxy> proxies,
}) {
  final ref = globalState.container;
  final columns = ref.read(proxiesColumnsProvider);
  final proxyCardType = ref.read(
    proxiesStyleSettingProvider.select((state) => state.cardType),
  );
  final selectedProxyName = ref.read(selectedProxyNameProvider(groupName));
  final findSelectedIndex = proxies.indexWhere(
    (proxy) => proxy.name == selectedProxyName,
  );
  final selectedIndex = findSelectedIndex != -1 ? findSelectedIndex : 0;
  final rows = (selectedIndex / columns).floor();
  return rows * getItemHeight(proxyCardType) + (rows - 1) * 8;
}
