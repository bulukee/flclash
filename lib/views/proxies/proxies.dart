import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/services/salmon_service.dart';
import 'package:fl_clash/services/salmon_profile_sync.dart';
import 'package:fl_clash/views/proxies/common.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ProxiesView extends ConsumerStatefulWidget {
  const ProxiesView({super.key});
  @override
  ConsumerState<ProxiesView> createState() => _ProxiesViewState();
}

class _ProxiesViewState extends ConsumerState<ProxiesView> {
  bool updating = false;
  bool testing = false;
  bool autoTested = false;
  String? selectedNode;

  @override
  void initState() {
    super.initState();
    restoreDelayCache();
  }

  bool _real(Proxy proxy) {
    const computed = {
      'Selector',
      'URLTest',
      'Fallback',
      'LoadBalance',
      'Direct',
      'Reject',
      'Compatible',
    };
    if (computed.contains(proxy.type)) return false;
    final name = proxy.name.toLowerCase();
    const hidden = [
      '剩余流量',
      '下次重置',
      '套餐到期',
      '到期时间',
      '邮箱',
      '官网',
      'traffic',
      'expire',
      'email',
    ];
    return !hidden.any(name.contains);
  }

  List<Proxy> _nodes(Group group) => group.all.where(_real).toList();

  Group? _group(List<Group> groups) {
    final selectors =
        groups
            .where((g) => g.type == GroupType.Selector && _nodes(g).isNotEmpty)
            .toList()
          ..sort((a, b) => _nodes(b).length.compareTo(_nodes(a).length));
    return selectors.isEmpty ? null : selectors.first;
  }

  String _selected(List<Group> groups, Group group) {
    var value = group.realNow;
    final visited = <String>{group.name};
    while (value.isNotEmpty && !visited.contains(value)) {
      final nested = groups.getGroup(value);
      if (nested == null) break;
      visited.add(value);
      value = nested.realNow;
    }
    return value;
  }

  Future<void> _update() async {
    if (updating) return;
    setState(() => updating = true);
    try {
      final profile = ref.read(currentProfileProvider);
      if (profile == null) {
        await refreshSalmonProfile(ref);
      } else {
        await ref.read(profilesActionProvider.notifier).updateProfile(profile);
      }
      await Future<void>.delayed(const Duration(milliseconds: 650));
      await ref.read(proxiesActionProvider.notifier).updateGroups();
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('节点更新完成')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              salmonFriendlyError(error, fallback: '当前订阅更新失败，已继续使用原有线路'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => updating = false);
    }
  }

  Future<void> _test(Group? group) async {
    if (group == null || testing) return;
    setState(() => testing = true);
    try {
      await delayTest(_nodes(group), group.testUrl, group.name);
    } finally {
      if (mounted) setState(() => testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(currentGroupsStateProvider).value;
    final group = _group(groups);
    final nodes = group == null ? const <Proxy>[] : _nodes(group);
    final selected =
        selectedNode ??
        salmonCurrentNodeName ??
        (group == null ? '' : _selected(groups, group));
    final current = nodes.any((node) => node.name == selected)
        ? selected
        : group == null
        ? ''
        : _selected(groups, group);
    if (!autoTested && group != null && nodes.isNotEmpty) {
      autoTested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _test(group));
    }
    return CommonScaffold(
      title: '节点',
      actions: [
        FilledButton.tonalIcon(
          onPressed: updating ? null : _update,
          icon: updating
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh_rounded),
          label: const Text('更新'),
        ),
        const SizedBox(width: 6),
        FilledButton.icon(
          onPressed: testing ? null : () => _test(group),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF2C5DFF),
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFFD8DCE5),
            disabledForegroundColor: const Color(0xFF8992A3),
          ),
          icon: testing
              ? const SizedBox.square(
                  dimension: 17,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Color(0xFF2C5DFF),
                  ),
                )
              : const Icon(Icons.speed_rounded),
          label: const Text('测速'),
        ),
        const SizedBox(width: 10),
      ],
      body: nodes.isEmpty
          ? const Center(child: Text('暂无可用线路，请点击更新'))
          : LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth < 520
                    ? 2
                    : constraints.maxWidth < 850
                    ? 3
                    : 4;
                return CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '选择线路',
                              style: TextStyle(
                                color: Color(0xFF29496F),
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (current.isNotEmpty) ...[
                              const SizedBox(height: 5),
                              Text(
                                '当前使用：$current',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF64748B),
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 30),
                      sliver: SliverGrid.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                          mainAxisExtent: 124,
                        ),
                        itemCount: nodes.length,
                        itemBuilder: (_, index) {
                          final proxy = nodes[index];
                          return SalmonNodeCard(
                            proxy: proxy,
                            active: proxy.name == current,
                            testUrl: group!.testUrl,
                            onTap: () async {
                              await ref
                                  .read(proxiesActionProvider.notifier)
                                  .changeProxy(
                                    groupName: group.name,
                                    proxyName: proxy.name,
                                  );
                              ref
                                  .read(profilesActionProvider.notifier)
                                  .updateCurrentSelectedMap(
                                    group.name,
                                    proxy.name,
                                  );
                              salmonCurrentNodeName = proxy.name;
                              if (mounted) {
                                setState(() => selectedNode = proxy.name);
                              }
                              await proxyDelayTest(proxy, group.testUrl);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class SalmonNodeCard extends ConsumerWidget {
  final Proxy proxy;
  final bool active;
  final String? testUrl;
  final VoidCallback onTap;
  const SalmonNodeCard({
    super.key,
    required this.proxy,
    required this.active,
    required this.testUrl,
    required this.onTap,
  });

  String _flag(String name) {
    final lower = name.toLowerCase();
    if (name.contains('香港') ||
        lower.contains('hong kong') ||
        lower.contains('hk'))
      return '🇭🇰';
    if (name.contains('台湾') || lower.contains('taiwan') || lower.contains('tw'))
      return '🇹🇼';
    if (name.contains('日本') || lower.contains('japan') || lower.contains('jp'))
      return '🇯🇵';
    if (name.contains('新加坡') ||
        lower.contains('singapore') ||
        lower.contains('sg'))
      return '🇸🇬';
    if (name.contains('美国') || lower.contains('usa') || lower.contains('us'))
      return '🇺🇸';
    if (name.contains('韩国') || lower.contains('korea') || lower.contains('kr'))
      return '🇰🇷';
    if (name.contains('英国') ||
        lower.contains('kingdom') ||
        lower.contains('uk'))
      return '🇬🇧';
    if (name.contains('德国') || lower.contains('germany')) return '🇩🇪';
    if (name.contains('法国') || lower.contains('france')) return '🇫🇷';
    return '🌐';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final delay = ref.watch(
      delayProvider(proxyName: proxy.name, testUrl: testUrl),
    );
    final color = delay == null || delay == 0
        ? context.colorScheme.onSurfaceVariant
        : delay < 0
        ? Colors.redAccent
        : delay < 350
        ? Colors.green
        : delay < 600
        ? Colors.amber.shade700
        : Colors.redAccent;
    return Material(
      color: active
          ? const Color(0xFFE7F0FF)
          : context.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: active ? const Color(0xFF5B91D8) : const Color(0xFFE1E7F0),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    _flag(proxy.name),
                    style: const TextStyle(fontSize: 22, fontFamily: 'Twemoji'),
                  ),
                  const Spacer(),
                  if (active)
                    const Icon(
                      Icons.check_circle_rounded,
                      color: Color(0xFF5B91D8),
                      size: 20,
                    ),
                ],
              ),
              const Spacer(),
              Text(
                proxy.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      active ? '使用中' : proxy.type,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: active
                            ? const Color(0xFF467BC4)
                            : context.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    delay == null || delay == 0
                        ? '--'
                        : delay < 0
                        ? 'Timeout'
                        : '$delay ms',
                    style: TextStyle(
                      fontSize: 11,
                      color: color,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
