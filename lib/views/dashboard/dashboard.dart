import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/services/salmon_service.dart';
import 'package:fl_clash/services/salmon_traffic_reset.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/proxies/common.dart';
import 'package:fl_clash/views/purchase.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

String _nodeFlag(String name) {
  final lower = name.toLowerCase();
  bool code(String value) =>
      RegExp(r'(^|[^a-z])' + value + r'([^a-z]|$)').hasMatch(lower);
  if (name.contains('香港') || lower.contains('hong kong') || code('hk'))
    return '🇭🇰';
  if (name.contains('台湾') || lower.contains('taiwan') || code('tw'))
    return '🇹🇼';
  if (name.contains('日本') || lower.contains('japan') || code('jp'))
    return '🇯🇵';
  if (name.contains('新加坡') || lower.contains('singapore') || code('sg'))
    return '🇸🇬';
  if (name.contains('美国') || lower.contains('united states') || code('us'))
    return '🇺🇸';
  if (name.contains('韩国') || lower.contains('korea') || code('kr'))
    return '🇰🇷';
  if (name.contains('英国') || lower.contains('united kingdom') || code('uk'))
    return '🇬🇧';
  if (name.contains('德国') || lower.contains('germany')) return '🇩🇪';
  if (name.contains('法国') || lower.contains('france')) return '🇫🇷';
  if (name.contains('加拿大') || lower.contains('canada')) return '🇨🇦';
  if (name.contains('澳大利亚') || lower.contains('australia')) return '🇦🇺';
  if (name.contains('俄罗斯') || lower.contains('russia')) return '🇷🇺';
  return '🌐';
}

class DashboardView extends ConsumerStatefulWidget {
  const DashboardView({super.key});

  @override
  ConsumerState<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends ConsumerState<DashboardView> {
  late Future<Map<String, dynamic>> _account;
  late Future<List<Map<String, dynamic>>> _notices;
  bool _testing = false;
  bool _updating = false;
  String? _lastAutoTestNode;
  String? _selectedNode;
  bool _planWarningShown = false;

  @override
  void initState() {
    super.initState();
    salmonService.membershipRevision.addListener(_onMembershipChanged);
    restoreDelayCache();
    _account = salmonAccountCache == null
        ? _loadAccount()
        : Future.value(salmonAccountCache!);
    _notices = salmonNoticeCache == null
        ? _loadNotices()
        : Future.value(salmonNoticeCache!);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !salmonNodesUpdatedThisSession) {
        salmonNodesUpdatedThisSession = true;
        _updateNodes(silent: true);
      }
      _showPlanWarningIfNeeded();
      final cachedAt = salmonAccountCacheAt;
      if (mounted &&
          cachedAt != null &&
          DateTime.now().difference(cachedAt) > const Duration(minutes: 5)) {
        _refreshCachedAccount();
      }
      final noticeCachedAt = salmonNoticeCacheAt;
      if (mounted &&
          noticeCachedAt != null &&
          DateTime.now().difference(noticeCachedAt) >
              const Duration(minutes: 30)) {
        _refreshNotices();
      }
    });
  }

  void _onMembershipChanged() {
    if (!mounted) return;
    setState(() {
      _account = salmonAccountCache == null
          ? _loadAccount()
          : Future.value(salmonAccountCache!);
      _planWarningShown = false;
    });
  }

  @override
  void dispose() {
    salmonService.membershipRevision.removeListener(_onMembershipChanged);
    super.dispose();
  }

  Future<void> _showPlanWarningIfNeeded() async {
    if (_planWarningShown) return;
    _planWarningShown = true;
    try {
      final data = await _account;
      var total = num.tryParse('${data['transfer_enable'] ?? 0}') ?? 0;
      final quotaGb = num.tryParse('${data['plan_quota_gb'] ?? 0}') ?? 0;
      if (quotaGb > 0) total = quotaGb * 1024 * 1024 * 1024;
      final used =
          (num.tryParse('${data['u'] ?? 0}') ?? 0) +
          (num.tryParse('${data['d'] ?? 0}') ?? 0);
      final expired =
          '${data['plan_name'] ?? ''}' == '暂无套餐' ||
          _isExpired(data['expired_at'] ?? data['expire']);
      // A low-balance threshold is only a reminder; it must not block
      // connecting while any traffic remains.
      if (!expired || !mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          icon: Container(
            width: 68,
            height: 68,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF245CFF), Color(0xFF755BFF)],
              ),
              shape: BoxShape.circle,
            ),
            child: Icon(
              expired
                  ? Icons.workspace_premium_rounded
                  : Icons.data_usage_rounded,
              color: Colors.white,
              size: 34,
            ),
          ),
          title: Text(expired ? '套餐已过期' : '本期流量已用完'),
          content: Text(
            expired
                ? '当前套餐已经失效，暂时无法开启加速。请前往商店续费或购买新套餐。'
                : '本期可用流量已经使用完毕，暂时无法开启加速。请前往商店购买流量或升级套餐。',
            textAlign: TextAlign.center,
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('我知道了'),
            ),
          ],
        ),
      );
    } catch (_) {
      _planWarningShown = false;
    }
  }

  Future<List<Map<String, dynamic>>> _loadNotices() async {
    final value = await salmonService.fetchNotices();
    salmonNoticeCache = value;
    salmonNoticeCacheAt = DateTime.now();
    return value;
  }

  Future<void> _refreshNotices() async {
    final value = await _loadNotices();
    if (mounted) setState(() => _notices = Future.value(value));
  }

  Future<void> _refreshCachedAccount() async {
    final value = await _loadAccount();
    if (mounted) setState(() => _account = Future.value(value));
  }

  Future<Map<String, dynamic>> _loadAccount() async {
    final values = await Future.wait([
      salmonService.fetchSubscribeInfo(),
      salmonService.fetchUserInfo(),
      salmonService.fetchPlans(),
    ]);
    final subscription = Map<String, dynamic>.from(values[0] as Map);
    final user = Map<String, dynamic>.from(values[1] as Map);
    final plans = values[2] as List<Map<String, dynamic>>;
    for (final key in ['u', 'd', 'transfer_enable', 'expired_at', 'expire']) {
      if (user[key] != null) subscription[key] = user[key];
    }
    final planId = int.tryParse(
      '${subscription['plan_id'] ?? user['plan_id'] ?? ''}',
    );
    Map<String, dynamic>? currentPlan;
    for (final plan in plans) {
      if (int.tryParse('${plan['id']}') == planId) {
        currentPlan = plan;
        break;
      }
    }
    final userPlan = user['plan'];
    final originalPlanName = subscription['plan_name']?.toString();
    subscription['plan_name'] =
        currentPlan?['name']?.toString() ??
        (userPlan is Map ? userPlan['name']?.toString() : null) ??
        user['plan_name']?.toString() ??
        originalPlanName ??
        (planId != null && planId > 0 ? '已有套餐' : '暂无套餐');
    subscription['plan_quota_gb'] = currentPlan?['transfer_enable'];
    for (final key in [
      'reset_at',
      'reset_time',
      'reset_date',
      'reset_day',
      'reset_traffic_method',
    ]) {
      if (subscription[key] == null && currentPlan?[key] != null) {
        subscription[key] = currentPlan![key];
      }
    }
    salmonAccountCache = subscription;
    salmonAccountCacheAt = DateTime.now();
    return subscription;
  }

  Future<void> _toggleConnection() async {
    if (!ref.read(isStartProvider)) {
      final data = await _account;
      final rawExpiry = data['expired_at'] ?? data['expire'];
      var total = num.tryParse('${data['transfer_enable'] ?? 0}') ?? 0;
      final quotaGb = num.tryParse('${data['plan_quota_gb'] ?? 0}') ?? 0;
      if (quotaGb > 0) total = quotaGb * 1024 * 1024 * 1024;
      final used =
          (num.tryParse('${data['u'] ?? 0}') ?? 0) +
          (num.tryParse('${data['d'] ?? 0}') ?? 0);
      final expired =
          '${data['plan_name'] ?? ''}' == '暂无套餐' || _isExpired(rawExpiry);
      // Do not block at the 10% reminder threshold. Only an expired plan
      // prevents starting the tunnel.
      if (expired) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                expired ? '套餐已过期，请先前往商店购买或续费' : '本期流量已用完，请先购买流量或升级套餐',
              ),
            ),
          );
        }
        return;
      }
    }
    final next = !ref.read(isStartProvider);
    globalState.container
        .read(setupActionProvider.notifier)
        .updateStatus(next, isInit: !ref.read(initProvider));
  }

  Group? _currentGroup(List<Group> groups) {
    if (groups.isEmpty) return null;
    final selectors =
        groups
            .where(
              (group) =>
                  group.type == GroupType.Selector && _nodes(group).isNotEmpty,
            )
            .toList()
          ..sort((a, b) => _nodes(b).length.compareTo(_nodes(a).length));
    if (selectors.isNotEmpty) return selectors.first;
    return groups.first;
  }

  bool _isRealNode(Proxy proxy) {
    const computedTypes = {
      'Selector',
      'URLTest',
      'Fallback',
      'LoadBalance',
      'Direct',
      'Reject',
      'Compatible',
    };
    if (computedTypes.contains(proxy.type)) return false;
    final name = proxy.name.toLowerCase();
    const infoWords = [
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
    return !infoWords.any(name.contains);
  }

  List<Proxy> _nodes(Group group) => group.all.where(_isRealNode).toList();

  String _currentNodeName(List<Group> groups, Group? group) {
    if (group == null) return '智能推荐线路';
    var value = group.realNow;
    final visited = <String>{group.name};
    while (value.isNotEmpty && !visited.contains(value)) {
      final nested = groups.getGroup(value);
      if (nested == null) break;
      visited.add(value);
      value = nested.realNow;
    }
    if (value.isEmpty || value == '智能线路' || value == '自动选择') {
      return '智能推荐线路';
    }
    return value;
  }

  Future<void> _updateNodes({bool silent = false}) async {
    if (_updating) return;
    setState(() => _updating = true);
    try {
      final profile = ref.read(currentProfileProvider);
      if (profile == null) {
        throw StateError('当前没有可更新的订阅');
      }
      await ref.read(profilesActionProvider.notifier).updateProfile(profile);
      await Future<void>.delayed(const Duration(milliseconds: 650));
      await ref.read(proxiesActionProvider.notifier).updateGroups();
      if (mounted) {
        setState(() => _account = _loadAccount());
        if (!silent) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('节点已更新')));
        }
      }
    } catch (error) {
      if (mounted && !silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              salmonFriendlyError(error, fallback: '当前订阅更新失败，已继续使用原有线路'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _showModeSelector(Mode current) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Consumer(
                builder: (context, ref, _) {
                  final tunEnabled = ref.watch(
                    patchClashConfigProvider.select(
                      (state) => state.tun.enable,
                    ),
                  );
                  return Container(
                    margin: const EdgeInsets.only(bottom: 18),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEAF1FF),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: const Color(0xFFD8E3F3)),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(22),
                      onTap: () {
                        ref
                            .read(patchClashConfigProvider.notifier)
                            .update(
                              (state) =>
                                  state.copyWith.tun(enable: !tunEnabled),
                            );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            Switch(
                              value: tunEnabled,
                              onChanged: (value) {
                                ref
                                    .read(patchClashConfigProvider.notifier)
                                    .update(
                                      (state) =>
                                          state.copyWith.tun(enable: value),
                                    );
                              },
                            ),
                            const SizedBox(width: 8),
                            Container(
                              width: 44,
                              height: 44,
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.router_rounded,
                                color: Color(0xFF245CFF),
                              ),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '虚拟网卡',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  SizedBox(height: 2),
                                  Text(
                                    '接管应用流量，可与代理模式同时使用',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
              const Text(
                '选择代理模式',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 12),
              for (final item in const [
                (Mode.rule, '规则模式', '按规则智能分流'),
                (Mode.global, '全局模式', '所有流量通过代理'),
                (Mode.direct, '直连模式', '所有流量直接连接'),
              ])
                RadioListTile<Mode>(
                  value: item.$1,
                  groupValue: current,
                  title: Text(item.$2),
                  subtitle: Text(item.$3),
                  onChanged: (value) {
                    if (value == null) return;
                    ref.read(setupActionProvider.notifier).changeMode(value);
                    Navigator.pop(sheetContext);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _testNodes(Group? group) async {
    if (group == null || _testing) return;
    final nodes = _nodes(group);
    if (nodes.isEmpty) return;
    setState(() => _testing = true);
    try {
      await delayTest(nodes, group.testUrl, group.name);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  void _autoTestCurrentNode(Group? group, String nodeName, bool connected) {
    if (!connected) {
      _lastAutoTestNode = null;
      return;
    }
    if (group == null || nodeName.isEmpty) return;
    final key = '${group.name}|$nodeName';
    if (_lastAutoTestNode == key) return;
    _lastAutoTestNode = key;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await proxyDelayTest(Proxy(name: nodeName, type: ''), group.testUrl);
      } catch (_) {
        _lastAutoTestNode = null;
      }
    });
  }

  Future<void> _refreshNodeSheet(BuildContext sheetContext) async {
    Navigator.pop(sheetContext);
    await _updateNodes();
    if (!mounted) return;
    final refreshed = _currentGroup(ref.read(currentGroupsStateProvider).value);
    if (refreshed != null) await _showNodes(refreshed);
  }

  Future<void> _showNodes(Group group) async {
    final nodes = _nodes(group);
    var sheetTesting = false;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * 0.90,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 2, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '选择节点',
                              style: context.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            Text('${nodes.length} 个可用节点'),
                          ],
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _updating
                            ? null
                            : () => _refreshNodeSheet(sheetContext),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('更新'),
                      ),
                      const SizedBox(width: 6),
                      FilledButton.icon(
                        onPressed: sheetTesting || _testing
                            ? null
                            : () async {
                                setSheetState(() => sheetTesting = true);
                                try {
                                  await _testNodes(group);
                                } finally {
                                  if (sheetContext.mounted) {
                                    setSheetState(() => sheetTesting = false);
                                  }
                                }
                              },
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF2C5DFF),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: const Color(0xFFD8DCE5),
                          disabledForegroundColor: const Color(0xFF8992A3),
                        ),
                        icon: sheetTesting || _testing
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                  color: Color(0xFF2C5DFF),
                                ),
                              )
                            : const Icon(Icons.speed_rounded, size: 19),
                        label: const Text('测速'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: nodes.isEmpty
                      ? const Center(child: Text('暂无可用节点，请点击右上角更新'))
                      : ListView.separated(
                          padding: const EdgeInsets.all(14),
                          itemCount: nodes.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (_, index) {
                            final proxy = nodes[index];
                            final selected =
                                proxy.name ==
                                (_selectedNode ??
                                    _currentNodeName(
                                      ref
                                          .read(currentGroupsStateProvider)
                                          .value,
                                      group,
                                    ));
                            return _NodeTile(
                              proxy: proxy,
                              selected: selected,
                              testUrl: group.testUrl,
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
                                if (mounted) {
                                  salmonCurrentNodeName = proxy.name;
                                  setState(() => _selectedNode = proxy.name);
                                }
                                if (sheetContext.mounted) {
                                  Navigator.pop(sheetContext);
                                }
                                await proxyDelayTest(proxy, group.testUrl);
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _traffic(num bytes) {
    final gb = bytes / 1024 / 1024 / 1024;
    return '${gb.toStringAsFixed(gb >= 10 ? 0 : 1)} GB';
  }

  String _speed(num bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB/s';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB/s';
    return '${bytes.toStringAsFixed(0)} B/s';
  }

  String _expiry(dynamic raw) {
    final value = int.tryParse('${raw ?? ''}');
    if (value == null || value <= 0) return '长期有效';
    final date = DateTime.fromMillisecondsSinceEpoch(
      value < 100000000000 ? value * 1000 : value,
    );
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  bool _isExpired(dynamic raw) {
    final value = int.tryParse('${raw ?? ''}');
    if (value == null || value <= 0) return false;
    final date = DateTime.fromMillisecondsSinceEpoch(
      value < 100000000000 ? value * 1000 : value,
    );
    return !date.isAfter(DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    final connected = ref.watch(isStartProvider);
    final mode = ref.watch(
      patchClashConfigProvider.select((state) => state.mode),
    );
    final groups = ref.watch(currentGroupsStateProvider).value;
    final group = _currentGroup(groups);
    final nodeName =
        _selectedNode ??
        salmonCurrentNodeName ??
        _currentNodeName(groups, group);
    final currentDelay = ref.watch(
      delayProvider(proxyName: nodeName, testUrl: group?.testUrl),
    );
    final traffic = ref.watch(
      trafficsProvider.select((state) => state.list.safeLast(const Traffic())),
    );
    _autoTestCurrentNode(group, nodeName, connected);

    return CommonScaffold(
      appBar: AppBar(
        // The desktop side rail already carries the brand. Repeating the
        // small mark here made the header look like an unrelated button.
        title: const SizedBox.shrink(),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final desktop = system.isWindows;
          if (desktop) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(28, 12, 28, 16),
              child: Column(
                children: [
                  SizedBox(
                    width: math.min(760, constraints.maxWidth - 56),
                    child: FutureBuilder<List<Map<String, dynamic>>>(
                      future: _notices,
                      builder: (_, snapshot) {
                        final fetched = snapshot.data ?? const [];
                        final notices = fetched.isEmpty
                            ? const <Map<String, dynamic>>[
                                {'title': '公告中心', 'content': '暂无最新公告'},
                              ]
                            : fetched;
                        return _NoticeCard(
                          notices: notices,
                          onRefresh: () =>
                              setState(() => _notices = _loadNotices()),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Center(
                      child: SizedBox(
                        width: math.min(860, constraints.maxWidth - 56),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _ConnectionHero(
                              compact: true,
                              showNode: true,
                              connected: connected,
                              nodeName: nodeName,
                              delay: currentDelay,
                              onPowerTap: _toggleConnection,
                              onNodeTap: group == null
                                  ? null
                                  : () => _showNodes(group),
                            ),
                            const SizedBox(height: 14),
                            _DesktopModeCard(
                              mode: mode,
                              onTap: () => _showModeSelector(mode),
                            ),
                            FutureBuilder<Map<String, dynamic>>(
                              future: _account,
                              builder: (_, snapshot) {
                                final data = snapshot.data ?? const {};
                                var total =
                                    num.tryParse(
                                      '${data['transfer_enable'] ?? 0}',
                                    ) ??
                                    0;
                                final quotaGb =
                                    num.tryParse(
                                      '${data['plan_quota_gb'] ?? 0}',
                                    ) ??
                                    0;
                                if (quotaGb > 0) {
                                  total = quotaGb * 1024 * 1024 * 1024;
                                }
                                final used =
                                    (num.tryParse('${data['u'] ?? 0}') ?? 0) +
                                    (num.tryParse('${data['d'] ?? 0}') ?? 0);
                                final expired =
                                    '${data['plan_name'] ?? ''}' == '暂无套餐' ||
                                    _isExpired(
                                      data['expired_at'] ?? data['expire'],
                                    );
                                final remaining = expired
                                    ? 0
                                    : (total - used).clamp(0, total);
                                if (expired ||
                                    total <= 0 ||
                                    remaining > total * .1) {
                                  return const SizedBox.shrink();
                                }
                                return Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: FilledButton.tonalIcon(
                                    onPressed: () {
                                      Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => const PurchaseView(),
                                        ),
                                      );
                                    },
                                    icon: const Icon(Icons.restart_alt_rounded),
                                    label: const Text('剩余流量不足 10%，立即重置'),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }
          final contentWidth = math.min(
            desktop ? 860.0 : 620.0,
            constraints.maxWidth - 16,
          );
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
            child: Align(
              alignment: Alignment.topCenter,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: contentWidth,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FutureBuilder<List<Map<String, dynamic>>>(
                        future: _notices,
                        builder: (_, snapshot) {
                          final fetched = snapshot.data ?? const [];
                          final notices = fetched.isEmpty
                              ? const <Map<String, dynamic>>[
                                  {'title': '公告中心', 'content': '暂无最新公告'},
                                ]
                              : fetched;
                          return _NoticeCard(
                            notices: notices,
                            onRefresh: () =>
                                setState(() => _notices = _loadNotices()),
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: SizedBox(
                          width: desktop ? 500 : contentWidth,
                          child: _ConnectionHero(
                            compact: desktop,
                            connected: connected,
                            nodeName: nodeName,
                            delay: currentDelay,
                            onPowerTap: _toggleConnection,
                            onNodeTap: group == null
                                ? null
                                : () => _showNodes(group),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FutureBuilder<Map<String, dynamic>>(
                        future: _account,
                        builder: (_, snapshot) {
                          final data = snapshot.data ?? const {};
                          var total =
                              num.tryParse('${data['transfer_enable'] ?? 0}') ??
                              0;
                          final planQuotaGb =
                              num.tryParse('${data['plan_quota_gb'] ?? 0}') ??
                              0;
                          if (planQuotaGb > 0) {
                            total = planQuotaGb * 1024 * 1024 * 1024;
                          }
                          final used =
                              (num.tryParse('${data['u'] ?? 0}') ?? 0) +
                              (num.tryParse('${data['d'] ?? 0}') ?? 0);
                          final rawExpiry =
                              data['expired_at'] ?? data['expire'];
                          final expired =
                              '${data['plan_name'] ?? ''}' == '暂无套餐' ||
                              _isExpired(rawExpiry);
                          final remaining = expired
                              ? 0
                              : (total - used).clamp(0, total);
                          final lowTraffic =
                              !expired && total > 0 && remaining <= total * .1;
                          if (desktop) return const SizedBox.shrink();
                          return Align(
                            alignment: desktop
                                ? Alignment.centerLeft
                                : Alignment.center,
                            child: SizedBox(
                              width: desktop ? 580 : contentWidth,
                              child: Column(
                                children: [
                                  _QuickStats(
                                    upload: connected
                                        ? _speed(traffic.up)
                                        : '0 B/s',
                                    download: connected
                                        ? _speed(traffic.down)
                                        : '0 B/s',
                                    mode: mode,
                                    onModeTap: () => _showModeSelector(mode),
                                  ),
                                  const SizedBox(height: 14),
                                  _PlanSummary(
                                    plan: expired
                                        ? '套餐已过期'
                                        : '${data['plan_name'] ?? '正在获取'}',
                                    remaining: _traffic(remaining),
                                    expiry: expired
                                        ? '套餐已过期'
                                        : _expiry(rawExpiry),
                                    resetLabel: expired
                                        ? null
                                        : salmonTrafficResetSummary(data),
                                    showResetTraffic: lowTraffic,
                                    onResetTraffic: () {
                                      Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => const PurchaseView(),
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  final List<Map<String, dynamic>> notices;
  final VoidCallback onRefresh;

  const _NoticeCard({required this.notices, required this.onRefresh});

  String _plain(dynamic source) => '${source ?? ''}'
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .trim();

  @override
  Widget build(BuildContext context) {
    final first = notices.first;
    final title = _plain(first['title']).isEmpty
        ? '最新公告'
        : _plain(first['title']);
    final content = _plain(first['content'] ?? first['message']);
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .68,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '公告中心',
                          style: context.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          Navigator.pop(context);
                          onRefresh();
                        },
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: notices.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, index) {
                      final notice = notices[index];
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(17),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _plain(notice['title']).isEmpty
                                    ? '平台公告'
                                    : _plain(notice['title']),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 17,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _plain(notice['content'] ?? notice['message']),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color: context.colorScheme.secondaryContainer.withValues(alpha: .55),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Icon(Icons.campaign_rounded, color: context.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                content.isEmpty ? title : '$title · $content',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    );
  }
}

class _NodeTile extends ConsumerWidget {
  final Proxy proxy;
  final bool selected;
  final String? testUrl;
  final VoidCallback onTap;

  const _NodeTile({
    required this.proxy,
    required this.selected,
    required this.testUrl,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final delay = ref.watch(
      delayProvider(proxyName: proxy.name, testUrl: testUrl),
    );
    final displayDelay = estimatedOneWayDelay(delay);
    final delayText = displayDelay == null
        ? '-- ms'
        : displayDelay == 0
        ? '测速中'
        : '$displayDelay ms';
    final delayColor = displayDelay == null || displayDelay == 0
        ? context.colorScheme.onSurfaceVariant
        : displayDelay < 350
        ? Colors.green
        : displayDelay < 600
        ? Colors.amber.shade700
        : Colors.redAccent;
    return ListTile(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      tileColor: selected
          ? context.colorScheme.primaryContainer
          : context.colorScheme.surfaceContainerLow,
      leading: CircleAvatar(
        backgroundColor: selected
            ? context.colorScheme.primary
            : context.colorScheme.surfaceContainerHighest,
        child: Text(
          _nodeFlag(proxy.name),
          style: const TextStyle(fontSize: 22, fontFamily: 'Twemoji'),
        ),
      ),
      title: Text(
        proxy.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(proxy.type),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: delayColor.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          delayText,
          style: TextStyle(color: delayColor, fontWeight: FontWeight.w900),
        ),
      ),
      onTap: onTap,
    );
  }
}

class _UsageBar extends StatelessWidget {
  final String email;
  final String used;
  final String total;
  final double ratio;

  const _UsageBar({
    required this.email,
    required this.used,
    required this.total,
    required this.ratio,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(26),
      border: Border.all(color: const Color(0xFFE3EBF8)),
      boxShadow: [
        BoxShadow(
          color: const Color(0xFF7B9BC5).withValues(alpha: .10),
          blurRadius: 24,
          offset: const Offset(0, 10),
        ),
      ],
    ),
    child: Column(
      children: [
        Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF39BDF2), Color(0xFF65DDF4)],
                ),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.set_meal_rounded,
                color: Colors.white,
                size: 27,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '欢迎回来',
                    style: TextStyle(color: Color(0xFF8392A8), fontSize: 12),
                  ),
                  Text(
                    email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF173F46),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFFEDF5FF),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                '$used / $total',
                style: const TextStyle(
                  color: Color(0xFF527DB5),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 8,
            backgroundColor: const Color(0xFFEDF2FA),
            color: const Color(0xFF2A9D98),
          ),
        ),
      ],
    ),
  );
}

class _ConnectionHero extends StatelessWidget {
  final bool compact;
  final bool showNode;
  final bool connected;
  final String nodeName;
  final int? delay;
  final VoidCallback onPowerTap;
  final VoidCallback? onNodeTap;

  const _ConnectionHero({
    this.compact = false,
    this.showNode = true,
    required this.connected,
    required this.nodeName,
    required this.delay,
    required this.onPowerTap,
    this.onNodeTap,
  });

  @override
  Widget build(BuildContext context) {
    final displayDelay = estimatedOneWayDelay(delay);
    return Container(
      constraints: BoxConstraints(minHeight: compact ? 430 : 0),
      padding: EdgeInsets.fromLTRB(
        20,
        compact ? 16 : 24,
        20,
        compact ? 16 : 20,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFFFFF), Color(0xFFF2F6FF), Color(0xFFF7F3FF)],
        ),
        border: Border.fromBorderSide(BorderSide(color: Color(0xFFD9E5FA))),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF245CFF).withValues(alpha: 0.12),
            blurRadius: 26,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: compact
            ? MainAxisAlignment.spaceBetween
            : MainAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F8FF),
              borderRadius: BorderRadius.circular(30),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: connected
                        ? const Color(0xFF55C68A)
                        : const Color(0xFFFFB064),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  connected ? '网络保护已开启' : '等待连接',
                  style: const TextStyle(
                    color: Color(0xFF587396),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: compact ? 12 : 24),
          _PowerOrb(
            connected: connected,
            onTap: onPowerTap,
            scale: compact ? .78 : 1,
          ),
          SizedBox(height: compact ? 14 : 26),
          if (showNode)
            Center(
              child: SizedBox(
                width: compact ? 620 : double.infinity,
                child: Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  child: InkWell(
                    onTap: onNodeTap,
                    borderRadius: BorderRadius.circular(18),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 15,
                        vertical: 13,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            alignment: Alignment.center,
                            decoration: const BoxDecoration(
                              color: Color(0xFFDCE7FA),
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              _nodeFlag(nodeName),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 23,
                                fontFamily: 'Twemoji',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  nodeName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: const Color(0xFF10233F),
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            displayDelay == null || displayDelay == 0
                                ? '-- ms'
                                : '$displayDelay ms',
                            style: const TextStyle(
                              color: Color(0xFF245CFF),
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: Color(0xFF245CFF),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DesktopModeCard extends StatelessWidget {
  final Mode mode;
  final VoidCallback onTap;

  const _DesktopModeCard({required this.mode, required this.onTap});

  String get label => switch (mode) {
    Mode.rule => '规则模式',
    Mode.global => '全局模式',
    Mode.direct => '直连模式',
  };

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFFF7F8FC),
    borderRadius: BorderRadius.circular(20),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Row(
          children: [
            const Icon(Icons.tune_rounded, color: Color(0xFF755BFF)),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                '代理模式',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFF245CFF),
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    ),
  );
}

class _QuickStats extends StatelessWidget {
  final String upload;
  final String download;
  final Mode mode;
  final VoidCallback onModeTap;

  const _QuickStats({
    required this.upload,
    required this.download,
    required this.mode,
    required this.onModeTap,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: _StatPanel(
          icon: Icons.speed_rounded,
          label: '实时流量',
          child: Row(
            children: [
              Icon(
                Icons.arrow_upward_rounded,
                size: 16,
                color: Colors.orange.shade700,
              ),
              Flexible(child: Text(upload, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 6),
              Icon(
                Icons.arrow_downward_rounded,
                size: 16,
                color: Colors.green.shade600,
              ),
              Flexible(child: Text(download, overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: InkWell(
          onTap: onModeTap,
          borderRadius: BorderRadius.circular(26),
          child: _StatPanel(
            icon: Icons.tune_rounded,
            label: '代理模式',
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    switch (mode) {
                      Mode.rule => '规则模式',
                      Mode.global => '全局模式',
                      Mode.direct => '直连模式',
                    },
                    style: TextStyle(
                      color: context.colorScheme.primary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

class _PlanSummary extends StatelessWidget {
  final String plan;
  final String remaining;
  final String expiry;
  final String? resetLabel;
  final bool showResetTraffic;
  final VoidCallback onResetTraffic;

  const _PlanSummary({
    required this.plan,
    required this.remaining,
    required this.expiry,
    required this.resetLabel,
    required this.showResetTraffic,
    required this.onResetTraffic,
  });

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFE8F0FF), Color(0xFFEDF1FF)],
      ),
      borderRadius: BorderRadius.circular(30),
      border: Border.all(color: const Color(0xFFD9E4F6)),
      boxShadow: [
        BoxShadow(
          color: const Color(0xFF245CFF).withValues(alpha: .13),
          blurRadius: 24,
          offset: const Offset(0, 10),
        ),
      ],
    ),
    child: Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF245CFF), Color(0xFF755BFF)],
            ),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.auto_awesome_rounded, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Text('当前套餐', style: TextStyle(color: Color(0xFF64789A))),
                  SizedBox(width: 5),
                  Icon(
                    Icons.favorite_rounded,
                    size: 13,
                    color: Color(0xFF755BFF),
                  ),
                ],
              ),
              Text(
                plan,
                style: const TextStyle(
                  color: Color(0xFF10233F),
                  fontWeight: FontWeight.w900,
                ),
              ),
              if (showResetTraffic) ...[
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: onResetTraffic,
                  icon: const Icon(Icons.restart_alt_rounded, size: 18),
                  label: const Text('重置流量'),
                ),
              ],
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              expiry == '套餐已过期' ? '套餐已过期' : '到期 $expiry',
              style: const TextStyle(
                color: Color(0xFF405E86),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              expiry == '套餐已过期' ? '剩余 0 GB' : '剩余 $remaining',
              style: const TextStyle(
                color: Color(0xFF245CFF),
                fontWeight: FontWeight.w900,
              ),
            ),
            if (resetLabel != null) ...[
              const SizedBox(height: 4),
              Text(
                resetLabel!,
                style: const TextStyle(
                  color: Color(0xFF405E86),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ],
    ),
  );
}

class _StatPanel extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget child;

  const _StatPanel({
    required this.icon,
    required this.label,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final isMode = icon == Icons.tune_rounded;
    return Container(
      width: double.infinity,
      height: 116,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isMode
              ? const [Color(0xFFF0FAFF), Color(0xFFF1F4FC)]
              : const [Color(0xFFEDF6FF), Color(0xFFF5F8FE)],
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6F91BF).withValues(alpha: .08),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
        border: Border.all(
          color: context.colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: isMode
                      ? const Color(0xFFE7EDFF)
                      : const Color(0xFFDCE7FA),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  size: 19,
                  color: isMode
                      ? const Color(0xFF755BFF)
                      : const Color(0xFF245CFF),
                ),
              ),
              const SizedBox(width: 7),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const Spacer(),
          child,
        ],
      ),
    );
  }
}

class _PowerOrb extends StatefulWidget {
  final bool connected;
  final VoidCallback onTap;
  final double scale;

  const _PowerOrb({
    required this.connected,
    required this.onTap,
    this.scale = 1,
  });

  @override
  State<_PowerOrb> createState() => _PowerOrbState();
}

class _PowerOrbState extends State<_PowerOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _pulse;
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(seconds: widget.connected ? 3 : 5),
    )..repeat();
    _pulse = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: .97, end: 1.055), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.055, end: .97), weight: 50),
    ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    _glow = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: .12, end: .42), weight: 50),
      TweenSequenceItem(tween: Tween(begin: .42, end: .12), weight: 50),
    ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void didUpdateWidget(covariant _PowerOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connected != widget.connected) {
      _controller.duration = Duration(seconds: widget.connected ? 3 : 5);
      _controller
        ..reset()
        ..repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => SizedBox.square(
        dimension: 190 * widget.scale,
        child: FittedBox(
          child: _PowerButtonFace(
            connected: widget.connected,
            onTap: widget.onTap,
            pulse: _pulse.value,
            glow: _glow.value,
            rotation: _controller.value,
          ),
        ),
      ),
    );
  }

  // Kept temporarily as a fallback until the new button has been device-tested.
  Widget legacyBuild(BuildContext context) {
    final color = widget.connected
        ? const Color(0xFF1A6CFF)
        : const Color(0xFF64748B);
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) => Transform.scale(
          scale: widget.connected ? .99 + ((_pulse.value - .97) * .28) : 1,
          child: SizedBox.square(
            dimension: 184,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 180,
                  height: 180,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        color.withValues(alpha: _glow.value * .24),
                        const Color(0x0000CFFF),
                      ],
                    ),
                    border: Border.all(
                      color: color.withValues(alpha: _glow.value),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: color.withValues(alpha: _glow.value),
                        blurRadius: 52,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                ),
                if (widget.connected)
                  CustomPaint(
                    size: const Size.square(180),
                    painter: _EnergyFlamePainter(
                      _controller.value,
                      _glow.value,
                    ),
                  ),
                Transform.rotate(
                  angle: widget.connected
                      ? _controller.value * 6.283185307179586
                      : 0,
                  child: Container(
                    width: 174,
                    height: 174,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: SweepGradient(
                        colors: widget.connected
                            ? const [
                                Color(0x00245CFF),
                                Color(0xFF00E5FF),
                                Color(0x00245CFF),
                                Color(0xFF3574FF),
                                Color(0xFF9D5CFF),
                                Color(0x00245CFF),
                              ]
                            : const [
                                Color(0x0064748B),
                                Color(0x4064748B),
                                Color(0x0064748B),
                                Color(0x4064748B),
                                Color(0x0064748B),
                              ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(
                            alpha: widget.connected ? .34 : .14,
                          ),
                          blurRadius: widget.connected ? 38 : 22,
                          spreadRadius: widget.connected ? 4 : 1,
                        ),
                      ],
                    ),
                  ),
                ),
                Container(
                  width: 148,
                  height: 148,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: widget.connected
                          ? const [Color(0xFFB9F3FF), Color(0xFF6A69FF)]
                          : const [Color(0xFFE8EEF7), Color(0xFFB8C5D8)],
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .72),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF245CFF).withValues(alpha: .34),
                        blurRadius: 26,
                      ),
                    ],
                  ),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 420),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: widget.connected
                            ? const [
                                Color(0xFF0A245A),
                                Color(0xFF154ED8),
                                Color(0xFF4928C7),
                              ]
                            : const [Color(0xFFF8FAFD), Color(0xFFE2E9F3)],
                      ),
                      border: Border.all(
                        color: const Color(0xFF8DEBFF).withValues(alpha: .48),
                        width: 1,
                      ),
                      boxShadow: widget.connected
                          ? [
                              BoxShadow(
                                color: const Color(
                                  0xFF245CFF,
                                ).withValues(alpha: .36),
                                blurRadius: 24,
                                spreadRadius: 2,
                              ),
                            ]
                          : null,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Stack(
                          alignment: Alignment.center,
                          children: [
                            Icon(
                              Icons.power_settings_new_rounded,
                              color: widget.connected
                                  ? const Color(
                                      0xFF00E5FF,
                                    ).withValues(alpha: .5)
                                  : const Color(0xFFB8C4D4),
                              size: 70,
                            ),
                            Icon(
                              Icons.power_settings_new_rounded,
                              color: widget.connected
                                  ? Colors.white
                                  : const Color(0xFF53657C),
                              size: 54,
                            ),
                          ],
                        ),
                        Text(
                          widget.connected ? 'ON' : 'OFF',
                          style: TextStyle(
                            color: widget.connected
                                ? const Color(0xFFBDF5FF)
                                : const Color(0xFF6B7C93),
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 2.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (widget.connected)
                  Positioned(
                    top: 23,
                    right: 38,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: const Color(0xFFB8F7FF),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: const Color(
                              0xFF00D8FF,
                            ).withValues(alpha: .8),
                            blurRadius: 12,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PowerButtonFace extends StatelessWidget {
  final bool connected;
  final VoidCallback onTap;
  final double pulse;
  final double glow;
  final double rotation;

  const _PowerButtonFace({
    required this.connected,
    required this.onTap,
    required this.pulse,
    required this.glow,
    required this.rotation,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: connected ? '关闭加速' : '开启加速',
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox.square(
          dimension: 190,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Transform.rotate(
                angle: rotation * math.pi * 2,
                child: CustomPaint(
                  size: const Size.square(186),
                  painter: _OrbitRingPainter(connected: connected, glow: glow),
                ),
              ),
              Transform.scale(
                scale: connected ? .99 + ((pulse - .97) * .18) : 1,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 360),
                  width: 158,
                  height: 158,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: connected
                        ? const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Color(0xFF00CFFF),
                              Color(0xFF2767FF),
                              Color(0xFF7047F5),
                            ],
                          )
                        : const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFFFFFFFF), Color(0xFFE7EDF7)],
                          ),
                    border: Border.all(
                      color: connected
                          ? Colors.white.withValues(alpha: .62)
                          : const Color(0xFFCBD7E8),
                      width: connected ? 2 : 1.5,
                    ),
                    boxShadow: connected
                        ? [
                            BoxShadow(
                              color: const Color(
                                0xFF216BFF,
                              ).withValues(alpha: .28 + glow * .42),
                              blurRadius: 26 + glow * 25,
                              spreadRadius: 2 + glow * 5,
                            ),
                            const BoxShadow(
                              color: Color(0x42008DFF),
                              offset: Offset(0, 12),
                              blurRadius: 22,
                            ),
                          ]
                        : const [
                            BoxShadow(
                              color: Color(0x1F27466E),
                              offset: Offset(0, 10),
                              blurRadius: 22,
                            ),
                          ],
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.power_settings_new_rounded,
                        size: 61,
                        color: connected
                            ? Colors.white
                            : const Color(0xFF48617F),
                      ),
                      const SizedBox(height: 7),
                      AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 280),
                        style: TextStyle(
                          color: connected
                              ? const Color(0xFFE9FCFF)
                              : const Color(0xFF48617F),
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          letterSpacing: .6,
                        ),
                        child: Text(connected ? '已连接' : '点击连接'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrbitRingPainter extends CustomPainter {
  final bool connected;
  final double glow;

  const _OrbitRingPainter({required this.connected, required this.glow});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width * .455;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final track = Paint()
      ..color = const Color(0xFFB9C9E5).withValues(alpha: .38)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, radius, track);

    final colors = connected
        ? const [
            Color(0xFF234FC8),
            Color(0xFF347DFF),
            Color(0xFF22CFFF),
            Color(0xFF8AEAFF),
            Color(0xFF22CFFF),
            Color(0xFF347DFF),
            Color(0xFF234FC8),
          ]
        : const [
            Color(0xFF607A9D),
            Color(0xFF91A6C3),
            Color(0xFFC4D1E2),
            Color(0xFF91A6C3),
            Color(0xFF607A9D),
          ];
    final shader = SweepGradient(
      startAngle: -math.pi / 2,
      endAngle: math.pi * 3 / 2,
      colors: colors,
    ).createShader(rect);

    if (connected) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = shader
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8.5
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2.2 + glow * 3.2),
      );
    }
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = connected ? 5.8 : 4.6
        ..strokeCap = StrokeCap.butt,
    );
  }

  @override
  bool shouldRepaint(covariant _OrbitRingPainter oldDelegate) =>
      connected != oldDelegate.connected || glow != oldDelegate.glow;
}

class _EnergyFlamePainter extends CustomPainter {
  final double progress;
  final double glow;

  const _EnergyFlamePainter(this.progress, this.glow);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final rect = Rect.fromCircle(center: center, radius: size.width * .455);
    final shader = const SweepGradient(
      colors: [
        Color(0x0000E5FF),
        Color(0xFF00E5FF),
        Color(0xFF3478FF),
        Color(0xFF9D5CFF),
        Color(0x0000E5FF),
      ],
    ).createShader(rect);
    final paint = Paint()
      ..shader = shader
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 5 + glow * 5
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 5 + glow * 8);
    final start = progress * math.pi * 2;
    canvas.drawArc(rect, start, math.pi * .38, false, paint);
    canvas.drawArc(rect, start + math.pi * .82, math.pi * .23, false, paint);
    canvas.drawArc(rect, start + math.pi * 1.42, math.pi * .15, false, paint);
  }

  @override
  bool shouldRepaint(covariant _EnergyFlamePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.glow != glow;
}

class _ConnectionTips extends StatelessWidget {
  const _ConnectionTips();

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xFFF0F6FF), Color(0xFFF3FAFF)],
      ),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0xFFE1EAF7)),
    ),
    child: const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.lightbulb_rounded, color: Color(0xFF755BFF)),
            SizedBox(width: 8),
            Text(
              '连接小贴士',
              style: TextStyle(
                color: Color(0xFF10233F),
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        SizedBox(height: 12),
        Text('• 延迟数值越低，线路通常越流畅'),
        SizedBox(height: 6),
        Text('• 网络异常时，可前往节点页面更新并重新测速'),
      ],
    ),
  );
}

class _ModeSelector extends StatelessWidget {
  final Mode value;
  final ValueChanged<Mode> onChanged;

  const _ModeSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const labels = {
      Mode.rule: '规则模式',
      Mode.global: '全局模式',
      Mode.direct: '直连模式',
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: Mode.values.map((mode) {
          final active = value == mode;
          return Expanded(
            child: InkWell(
              onTap: () => onChanged(mode),
              borderRadius: BorderRadius.circular(14),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: active
                      ? context.colorScheme.primary
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: Text(
                  labels[mode]!,
                  style: TextStyle(
                    color: active
                        ? context.colorScheme.onPrimary
                        : context.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
