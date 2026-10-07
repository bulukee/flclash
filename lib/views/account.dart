import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/services/salmon_service.dart';
import 'package:fl_clash/services/salmon_traffic_reset.dart';
import 'package:fl_clash/views/config/dns.dart';
import 'package:fl_clash/views/config/general.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart'
    as windows_webview;

enum AccountInitialAction { none, invites, customerService }

class InvitationPage extends StatefulWidget {
  const InvitationPage({super.key});

  @override
  State<InvitationPage> createState() => _InvitationPageState();
}

class _InvitationPageState extends State<InvitationPage> {
  late Future<Map<String, dynamic>> _future = _load();
  bool _generating = false;

  Future<Map<String, dynamic>> _load({bool forceRefresh = false}) async {
    final values = await Future.wait([
      salmonService.fetchInvites(forceRefresh: forceRefresh),
      salmonService.fetchUserInfo(forceRefresh: forceRefresh),
      salmonService.fetchCommissionConfig(forceRefresh: forceRefresh),
    ]);
    return {'invite': values[0], 'user': values[1], 'commission': values[2]};
  }

  num _value(List<Map<String, dynamic>> sources, List<String> keys) {
    for (final source in sources) {
      for (final key in keys) {
        final parsed = num.tryParse('${source[key] ?? ''}');
        if (parsed != null) return parsed;
      }
    }
    return 0;
  }

  String _money(num cents) => '¥${(cents / 100).toStringAsFixed(2)}';

  Future<void> _generate() async {
    if (_generating) return;
    setState(() => _generating = true);
    try {
      await salmonService.generateInvite();
      setState(() => _future = _load(forceRefresh: true));
      await _future;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              salmonFriendlyError(error, fallback: '邀请码生成失败，请检查面板邀请设置'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) => CommonScaffold(
    title: '返利',
    actions: [
      IconButton(
        onPressed: () => setState(() => _future = _load(forceRefresh: true)),
        icon: const Icon(Icons.refresh_rounded),
      ),
    ],
    body: FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: FilledButton.icon(
              onPressed: () =>
                  setState(() => _future = _load(forceRefresh: true)),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新获取'),
            ),
          );
        }
        final bundle = snapshot.data ?? const <String, dynamic>{};
        final data = Map<String, dynamic>.from(
          bundle['invite'] is Map ? bundle['invite'] as Map : const {},
        );
        final user = Map<String, dynamic>.from(
          bundle['user'] is Map ? bundle['user'] as Map : const {},
        );
        final commission = Map<String, dynamic>.from(
          bundle['commission'] is Map ? bundle['commission'] as Map : const {},
        );
        final stat = Map<String, dynamic>.from(
          data['stat'] is Map ? data['stat'] as Map : const {},
        );
        final sources = [stat, data, commission, user];
        final rawRate = _value(sources, [
          'commission_rate',
          'invite_commission',
          'rate',
        ]);
        final parsedRate = rawRate <= 1 ? rawRate * 100 : rawRate;
        final rate = parsedRate > 0 ? parsedRate : 30;
        final registered = _value(sources, [
          'registered_users',
          'invite_count',
          'registered_count',
          'count',
        ]);
        final pending = _value(sources, ['pending_commission', 'pending']);
        final totalCommission = _value(sources, [
          'commission',
          'total_commission',
        ]);
        final balance = _value(sources, [
          'commission_balance',
          'available_commission',
        ]);
        final rawCodes = data['codes'];
        final codes = rawCodes is List
            ? rawCodes.whereType<Map>().toList()
            : <Map>[];
        return ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF245CFF), Color(0xFF755BFF)],
                ),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '邀请好友',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 6),
                        Text(
                          '复制邀请码分享给好友',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _generating ? null : _generate,
                    icon: _generating
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add_rounded),
                    label: const Text('生成邀请链接'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth >= 760
                    ? (constraints.maxWidth - 14) / 2
                    : constraints.maxWidth;
                return Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    _RebateMetric(
                      width: width,
                      icon: Icons.pie_chart_rounded,
                      title: '返佣比例',
                      value: '${rate.toStringAsFixed(rate % 1 == 0 ? 0 : 1)}%',
                    ),
                    _RebateMetric(
                      width: width,
                      icon: Icons.account_balance_wallet_rounded,
                      title: '可用佣金',
                      value: _money(balance),
                    ),
                    _RebateMetric(
                      width: width,
                      icon: Icons.group_add_rounded,
                      title: '已注册用户',
                      value: '${registered.toInt()} 人',
                      subtitle: '确认中佣金 ${_money(pending)}',
                    ),
                    _RebateMetric(
                      width: width,
                      icon: Icons.ios_share_rounded,
                      title: '累计获得佣金',
                      value: _money(totalCommission),
                      subtitle: '邀请码 ${codes.length} 个',
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 20),
            Text(
              '邀请码',
              style: context.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 10),
            if (codes.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 80),
                child: Center(child: Text('暂无邀请码')),
              )
            else
              ...codes.map((item) {
                final code = '${item['code'] ?? ''}';
                final inviteUrl = 'https://dll.swywl.com/register?code=$code';
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 8,
                    ),
                    leading: const CircleAvatar(
                      child: Icon(Icons.qr_code_2_rounded),
                    ),
                    title: SelectableText(
                      code,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    subtitle: Text('已使用 ${item['pv'] ?? 0} 次'),
                    trailing: IconButton.filledTonal(
                      tooltip: '复制邀请码',
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: inviteUrl));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('邀请链接已复制')),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy_rounded),
                    ),
                  ),
                );
              }),
          ],
        );
      },
    ),
  );
}

class _RebateMetric extends StatelessWidget {
  final double width;
  final IconData icon;
  final String title;
  final String value;
  final String? subtitle;

  const _RebateMetric({
    required this.width,
    required this.icon,
    required this.title,
    required this.value,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: context.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 21,
            backgroundColor: const Color(0xFFFFE6EF),
            child: Icon(icon, color: const Color(0xFFE95488)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 5),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: context.colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class AccountView extends StatefulWidget {
  final AccountInitialAction initialAction;

  const AccountView({
    super.key,
    this.initialAction = AccountInitialAction.none,
  });

  @override
  State<AccountView> createState() => _AccountViewState();
}

class _AccountViewState extends State<AccountView> {
  late Future<Map<String, dynamic>> _data = salmonAccountCache == null
      ? _load()
      : Future.value(salmonAccountCache!);

  @override
  void initState() {
    super.initState();
    salmonService.membershipRevision.addListener(_onMembershipChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (widget.initialAction) {
        case AccountInitialAction.invites:
          _invites();
        case AccountInitialAction.customerService:
          _customerService();
        case AccountInitialAction.none:
          break;
      }
    });
  }

  void _onMembershipChanged() {
    if (!mounted) return;
    setState(() {
      _data = salmonAccountCache == null
          ? _load()
          : Future.value(salmonAccountCache!);
    });
  }

  @override
  void dispose() {
    salmonService.membershipRevision.removeListener(_onMembershipChanged);
    super.dispose();
  }

  Future<Map<String, dynamic>> _load({bool forceRefresh = false}) async {
    final values = await Future.wait([
      salmonService.fetchUserInfo(forceRefresh: forceRefresh),
      salmonService.fetchSubscribeInfo(forceRefresh: forceRefresh),
      salmonService.fetchPlans(forceRefresh: forceRefresh),
    ]);
    final user = Map<String, dynamic>.from(values[0] as Map);
    final subscription = Map<String, dynamic>.from(values[1] as Map);
    final plans = values[2] as List<Map<String, dynamic>>;
    final planId = int.tryParse(
      '${subscription['plan_id'] ?? user['plan_id']}',
    );
    final plan = plans.where((e) => int.tryParse('${e['id']}') == planId);
    final userPlan = user['plan'];
    final fallbackPlanName =
        subscription['plan_name']?.toString() ??
        (userPlan is Map ? userPlan['name']?.toString() : null) ??
        user['plan_name']?.toString() ??
        (planId != null && planId > 0 ? '已有套餐' : '暂无套餐');
    final result = <String, dynamic>{
      ...user,
      ...subscription,
      'plan_name': plan.isEmpty ? fallbackPlanName : '${plan.first['name']}',
    };
    if (plan.isNotEmpty) {
      for (final key in [
        'reset_at',
        'reset_time',
        'reset_date',
        'reset_day',
        'reset_traffic_method',
      ]) {
        if (result[key] == null && plan.first[key] != null) {
          result[key] = plan.first[key];
        }
      }
    }
    salmonAccountCache = result;
    salmonAccountCacheAt = DateTime.now();
    return result;
  }

  void _reload({bool forceRefresh = true}) =>
      setState(() => _data = _load(forceRefresh: forceRefresh));
  String _money(dynamic cents) =>
      '¥${((num.tryParse('${cents ?? 0}') ?? 0) / 100).toStringAsFixed(2)}';
  String _gb(num value) =>
      '${(value / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    _reload();
  }

  Future<void> _customerService() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => system.isWindows
            ? const WindowsEmbeddedCustomerServicePage()
            : const EmbeddedCustomerServicePage(),
      ),
    );
    if (mounted) _reload();
  }

  Future<void> _redeem() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('礼品卡兑换'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '请输入礼品卡兑换码',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('立即兑换'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (code == null || code.isEmpty) return;
    try {
      await salmonService.redeemGiftCard(code);
      _reload();
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('兑换成功')));
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(salmonFriendlyError(error))));
    }
  }

  Future<void> _invites() async {
    var data = await salmonService.fetchInvites();
    var user = await salmonService.fetchUserInfo();
    var commission = await salmonService.fetchCommissionConfig();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final raw = data['codes'];
          final codes = raw is List ? raw.whereType<Map>().toList() : <Map>[];
          final stat = data['stat'] is Map
              ? Map<String, dynamic>.from(data['stat'] as Map)
              : <String, dynamic>{};
          final statList = data['stat'] is List
              ? List<dynamic>.from(data['stat'] as List)
              : const <dynamic>[];
          String commissionRate() {
            final values = [
              commission['commission_rate'],
              commission['invite_commission'],
              data['commission_rate'],
              data['invite_commission'],
              stat['commission_rate'],
              stat['rate'],
              user['commission_rate'],
              user['invite_commission'],
            ];
            for (final raw in values) {
              final parsed = num.tryParse('${raw ?? ''}');
              if (parsed == null || parsed <= 0) continue;
              final percent = parsed <= 1 ? parsed * 100 : parsed;
              return '${percent.toStringAsFixed(percent % 1 == 0 ? 0 : 1)}%';
            }
            return '30%';
          }

          String amount(List<String> keys, {int? index}) {
            for (final key in keys) {
              final raw = stat[key] ?? commission[key] ?? user[key];
              if (raw != null) {
                final value = num.tryParse('$raw') ?? 0;
                return '¥${(value / 100).toStringAsFixed(2)}';
              }
            }
            if (index != null && index < statList.length) {
              final value = num.tryParse('${statList[index]}') ?? 0;
              return '¥${(value / 100).toStringAsFixed(2)}';
            }
            return '¥0.00';
          }

          return SizedBox(
            height: MediaQuery.sizeOf(context).height * .86,
            child: Column(
              children: [
                _SheetHeader(
                  title: '邀请码管理',
                  action: FilledButton.icon(
                    onPressed: () async {
                      await salmonService.generateInvite();
                      data = await salmonService.fetchInvites(
                        forceRefresh: true,
                      );
                      user = await salmonService.fetchUserInfo(
                        forceRefresh: true,
                      );
                      commission = await salmonService.fetchCommissionConfig(
                        forceRefresh: true,
                      );
                      update(() {});
                    },
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('生成'),
                  ),
                ),
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF245CFF), Color(0xFF00BCEB)],
                    ),
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _InviteStat(
                              icon: Icons.account_balance_wallet_rounded,
                              label: '累计佣金',
                              value: amount([
                                'commission',
                                'total_commission',
                              ], index: 0),
                            ),
                          ),
                          Expanded(
                            child: _InviteStat(
                              icon: Icons.more_horiz_rounded,
                              label: '待确认佣金',
                              value: amount([
                                'pending_commission',
                                'pending',
                              ], index: 1),
                            ),
                          ),
                        ],
                      ),
                      const Divider(color: Colors.white38, height: 28),
                      Row(
                        children: [
                          Expanded(
                            child: _InviteStat(
                              icon: Icons.attach_money_rounded,
                              label: '可用佣金',
                              value: amount([
                                'commission_balance',
                                'available_commission',
                              ], index: 2),
                            ),
                          ),
                          Expanded(
                            child: _InviteStat(
                              icon: Icons.hourglass_empty_rounded,
                              label: '待确认',
                              value: amount([
                                'pending_commission',
                                'pending',
                              ], index: 1),
                            ),
                          ),
                          Expanded(
                            child: _InviteStat(
                              icon: Icons.percent_rounded,
                              label: '佣金比例',
                              value: commissionRate(),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: codes.isEmpty
                      ? const Center(child: Text('暂无邀请码'))
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: codes.length,
                          itemBuilder: (_, i) {
                            final code = '${codes[i]['code'] ?? ''}';
                            return Card(
                              child: ListTile(
                                leading: const Icon(Icons.qr_code_2_rounded),
                                title: SelectableText(code),
                                subtitle: Text('已使用 ${codes[i]['pv'] ?? 0} 次'),
                                trailing: IconButton.filledTonal(
                                  tooltip: '复制邀请码',
                                  onPressed: () async {
                                    await Clipboard.setData(
                                      ClipboardData(
                                        text:
                                            'https://dll.swywl.com/register?code=$code',
                                      ),
                                    );
                                    if (context.mounted)
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('邀请链接已复制'),
                                        ),
                                      );
                                  },
                                  icon: const Icon(Icons.copy_rounded),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _logout() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出账号'),
        content: const Text('退出后需要重新输入账号和密码登录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认退出'),
          ),
        ],
      ),
    );
    if (yes == true) {
      await EmbeddedCustomerServicePage.clearRetainedSession();
      await salmonService.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.initialAction != AccountInitialAction.none) {
      final invites = widget.initialAction == AccountInitialAction.invites;
      return CommonScaffold(
        title: invites ? '返利' : '客服',
        body: Center(
          child: Text(
            invites ? '正在获取邀请信息…' : '正在连接客服…',
            style: TextStyle(color: context.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return CommonScaffold(
      title: '我的',
      actions: [
        IconButton(onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
      ],
      body: FutureBuilder<Map<String, dynamic>>(
        future: _data,
        builder: (context, snapshot) {
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          final data = snapshot.data!;
          final total = num.tryParse('${data['transfer_enable'] ?? 0}') ?? 0;
          final used =
              (num.tryParse('${data['u'] ?? 0}') ?? 0) +
              (num.tryParse('${data['d'] ?? 0}') ?? 0);
          final ratio = total <= 0
              ? 0.0
              : (used / total).clamp(0.0, 1.0).toDouble();
          return RefreshIndicator(
            onRefresh: () async {
              _reload();
              await _data;
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
              children: [
                _AccountCard(
                  data: data,
                  used: _gb(used),
                  total: _gb(total),
                  ratio: ratio,
                  money: _money,
                ),
                const SizedBox(height: 18),
                _MenuGroup(
                  children: [
                    _Menu(
                      icon: Icons.receipt_long_rounded,
                      title: '订单记录',
                      subtitle: '查看订单状态、取消订单和继续支付',
                      onTap: () => _open(const OrdersPage()),
                    ),
                    _Menu(
                      icon: Icons.query_stats_rounded,
                      title: '流量记录',
                      subtitle: '查看每日上传、下载和流量趋势',
                      onTap: () => _open(const TrafficRecordsPage()),
                    ),
                    _Menu(
                      icon: Icons.confirmation_number_rounded,
                      title: '工单系统',
                      subtitle: '提交问题、回复工单并查看处理进度',
                      onTap: () => _open(const TicketsPage()),
                    ),
                    _Menu(
                      icon: Icons.support_agent_rounded,
                      title: '在线客服',
                      subtitle: '联系三文鱼在线客服',
                      onTap: _customerService,
                    ),
                    _Menu(
                      icon: Icons.card_giftcard_rounded,
                      title: '礼品卡兑换',
                      subtitle: '兑换流量或时长奖励',
                      onTap: _redeem,
                    ),
                    _Menu(
                      icon: Icons.qr_code_2_rounded,
                      title: '邀请码管理',
                      subtitle: '邀请好友并获取奖励',
                      onTap: _invites,
                    ),
                    _Menu(
                      icon: Icons.settings_rounded,
                      title: '设置',
                      subtitle: '代理端口、DNS 覆写与网络设置',
                      onTap: () => _open(const SalmonSettingsPage()),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _logout,
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('退出当前账号'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: context.colorScheme.error,
                    minimumSize: const Size.fromHeight(52),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class SalmonSettingsPage extends StatefulWidget {
  const SalmonSettingsPage({super.key});

  @override
  State<SalmonSettingsPage> createState() => _SalmonSettingsPageState();
}

class _SalmonSettingsPageState extends State<SalmonSettingsPage> {
  bool _autoStartEnabled = false;
  bool _autoStartLoading = true;

  @override
  void initState() {
    super.initState();
    _loadAutoStartStatus();
  }

  Future<void> _loadAutoStartStatus() async {
    if (!system.isDesktop || autoLaunch == null) {
      if (mounted) {
        setState(() => _autoStartLoading = false);
      }
      return;
    }
    try {
      final enabled = await autoLaunch!.isEnable;
      if (!mounted) return;
      setState(() {
        _autoStartEnabled = enabled;
        _autoStartLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _autoStartLoading = false);
    }
  }

  Future<void> _setAutoStart(bool enabled) async {
    if (_autoStartLoading || autoLaunch == null) return;
    setState(() => _autoStartLoading = true);
    try {
      final success = enabled
          ? await autoLaunch!.enable()
          : await autoLaunch!.disable();
      final actual = await autoLaunch!.isEnable;
      if (!mounted) return;
      setState(() {
        _autoStartEnabled = actual;
        _autoStartLoading = false;
      });
      if (!success || actual != enabled) {
        throw StateError('startup setting was not applied');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _autoStartLoading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('开机自动启动设置失败，请稍后重试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: '设置',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                const PortItem(),
                const Divider(height: 1),
                if (system.isWindows || system.isMacOS) ...[
                  SwitchListTile.adaptive(
                    secondary: const Icon(Icons.power_settings_new_rounded),
                    title: const Text('开机自动启动'),
                    subtitle: Text(
                      system.isWindows
                          ? '登录 Windows 后自动启动三文鱼'
                          : '登录 macOS 后自动启动三文鱼',
                    ),
                    value: _autoStartEnabled,
                    onChanged: _autoStartLoading ? null : _setAutoStart,
                  ),
                  const Divider(height: 1),
                ],
                ListTile(
                  leading: const Icon(Icons.dns_rounded),
                  title: const Text('DNS 覆写'),
                  subtitle: const Text('自定义 DNS 与防污染设置'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const DnsOverridePage(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Windows 与 macOS 默认使用混合代理端口 7890。修改后请断开并重新连接；端口范围为 1024–49151。',
              style: TextStyle(color: Color(0xFF7185A3), height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class OrdersPage extends StatefulWidget {
  const OrdersPage({super.key});
  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  late Future<List<Map<String, dynamic>>> data = salmonService.fetchOrders();

  Future<void> _continuePay(Map<String, dynamic> order) async {
    try {
      final payments = await salmonService.fetchPaymentMethods();
      if (!mounted) return;
      if (payments.isEmpty) throw StateError('暂无可用支付方式');
      final method = await showModalBottomSheet<int>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 2, 18, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '选择支付方式',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 12),
                ...payments.map(
                  (payment) => ListTile(
                    leading: const CircleAvatar(
                      child: Icon(Icons.account_balance_wallet_rounded),
                    ),
                    title: Text(
                      '${payment['name'] ?? payment['payment'] ?? '在线支付'}',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pop(
                      context,
                      int.tryParse('${payment['id']}'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (method == null) return;
      final checkout = await salmonService.checkoutOrder(
        tradeNo: '${order['trade_no']}',
        method: method,
      );
      final type = int.tryParse('${checkout['type'] ?? 1}') ?? 1;
      final value = '${checkout['data'] ?? ''}';
      if (!mounted || value.isEmpty) return;
      if (type == 1) {
        final uri = Uri.parse(value);
        await launchUrl(
          uri,
          mode: uri.scheme == 'http' || uri.scheme == 'https'
              ? LaunchMode.inAppBrowserView
              : LaunchMode.externalApplication,
        );
      } else {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('扫码支付'),
            content: Image.network(
              value,
              width: 230,
              height: 230,
              errorBuilder: (_, _, _) => SelectableText(value),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('完成'),
              ),
            ],
          ),
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('正在确认支付结果…')));
      final completed = await salmonService.waitForOrderCompleted(
        '${order['trade_no']}',
      );
      if (!mounted) return;
      setState(() => data = salmonService.fetchOrders(forceRefresh: true));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(completed ? '支付成功，套餐已更新' : '暂未确认到账，请稍后刷新订单')),
      );
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(salmonFriendlyError(error))));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('订单记录')),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: data,
      builder: (_, snap) {
        if (!snap.hasData)
          return const Center(child: CircularProgressIndicator());
        final list = snap.data!;
        if (list.isEmpty) return const Center(child: Text('暂无订单'));
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: list.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (_, i) {
            final item = list[i];
            final status = int.tryParse('${item['status']}') ?? 0;
            final names = {0: '待支付', 1: '开通中', 2: '已取消', 3: '已完成', 4: '已折抵'};
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${item['trade_no'] ?? '套餐订单'}',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                        Chip(label: Text(names[status] ?? '未知')),
                      ],
                    ),
                    Text(
                      '${item['plan']?['name'] ?? ''} · ${item['cycle'] ?? ''}',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '金额：¥${((num.tryParse('${item['total_amount'] ?? 0}') ?? 0) / 100).toStringAsFixed(2)}',
                    ),
                    if (status == 0) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async {
                                await salmonService.cancelOrder(
                                  '${item['trade_no']}',
                                );
                                setState(
                                  () => data = salmonService.fetchOrders(),
                                );
                              },
                              child: const Text('取消订单'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: () => _continuePay(item),
                              child: const Text('继续支付'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    ),
  );
}

class TrafficRecordsPage extends StatelessWidget {
  const TrafficRecordsPage({super.key});
  String _size(dynamic bytes) =>
      '${((num.tryParse('$bytes') ?? 0) / 1024 / 1024).toStringAsFixed(2)} MB';
  num _total(Map<String, dynamic> item) =>
      (num.tryParse('${item['u'] ?? item['upload'] ?? 0}') ?? 0) +
      (num.tryParse('${item['d'] ?? item['download'] ?? 0}') ?? 0);
  String _date(Map<String, dynamic> item) {
    final raw = item['record_at'] ?? item['created_at'] ?? item['date'];
    final number = int.tryParse('$raw');
    if (number != null) {
      final date = DateTime.fromMillisecondsSinceEpoch(
        number < 100000000000 ? number * 1000 : number,
      );
      return '${date.month}/${date.day}';
    }
    final text = '$raw';
    return text.length > 10 ? text.substring(5, 10).replaceAll('-', '/') : text;
  }

  int _dateOrder(Map<String, dynamic> item) {
    final parts = '${item['date'] ?? _date(item)}'.split('/');
    if (parts.length == 2) {
      return (int.tryParse(parts[0]) ?? 0) * 100 +
          (int.tryParse(parts[1]) ?? 0);
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('流量记录')),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: salmonService.fetchTrafficLog(
        startAt: DateTime(DateTime.now().year, 7, 1),
      ),
      builder: (_, snap) {
        if (!snap.hasData)
          return const Center(child: CircularProgressIndicator());
        final grouped = <String, Map<String, dynamic>>{};
        for (final item in snap.data!) {
          final key = _date(item);
          final current = grouped.putIfAbsent(
            key,
            () => {'date': key, 'u': 0, 'd': 0},
          );
          current['u'] =
              (num.tryParse('${current['u']}') ?? 0) +
              (num.tryParse('${item['u'] ?? item['upload'] ?? 0}') ?? 0);
          current['d'] =
              (num.tryParse('${current['d']}') ?? 0) +
              (num.tryParse('${item['d'] ?? item['download'] ?? 0}') ?? 0);
        }
        final list = grouped.values.toList();
        list.sort((a, b) => _dateOrder(a).compareTo(_dateOrder(b)));
        if (list.isEmpty) return const Center(child: Text('暂无流量记录'));
        final chart = list.length > 7 ? list.sublist(list.length - 7) : list;
        final totals = chart.map(_total).toList();
        final maxValue = totals.reduce((a, b) => a > b ? a : b);
        final minValue = totals.reduce((a, b) => a < b ? a : b);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: context.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .06),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.show_chart_rounded,
                        color: Color(0xFF16A36A),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        '流量统计',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const Spacer(),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            'max: ${_size(maxValue)}',
                            style: const TextStyle(
                              color: Color(0xFF16A36A),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            'min: ${_size(minValue)}',
                            style: const TextStyle(
                              color: Colors.orange,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    height: 210,
                    width: double.infinity,
                    child: CustomPaint(painter: _TrafficChartPainter(totals)),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: chart
                        .map(
                          (e) => Text(
                            _date(e),
                            style: TextStyle(
                              color: context.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              '每日明细',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            ...list.reversed.map((e) {
              final up = e['u'] ?? e['upload'] ?? 0;
              final down = e['d'] ?? e['download'] ?? 0;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                      child: Icon(Icons.query_stats_rounded),
                    ),
                    title: Text(
                      '${e['record_at'] ?? e['created_at'] ?? e['date'] ?? '流量记录'}',
                    ),
                    subtitle: Text('上传 ${_size(up)}   下载 ${_size(down)}'),
                    trailing: Text(
                      _size(
                        (num.tryParse('$up') ?? 0) +
                            (num.tryParse('$down') ?? 0),
                      ),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              );
            }),
          ],
        );
      },
    ),
  );
}

class _TrafficChartPainter extends CustomPainter {
  final List<num> values;
  const _TrafficChartPainter(this.values);
  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxValue = values.reduce((a, b) => a > b ? a : b).toDouble();
    final points = <Offset>[];
    for (var i = 0; i < values.length; i++) {
      final x = values.length == 1
          ? size.width / 2
          : size.width * i / (values.length - 1);
      final ratio = maxValue <= 0 ? 0.0 : values[i].toDouble() / maxValue;
      points.add(Offset(x, size.height - (ratio * (size.height - 18)) - 8));
    }
    final line = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      line.lineTo(point.dx, point.dy);
    }
    final area = Path.from(line)
      ..lineTo(points.last.dx, size.height)
      ..lineTo(points.first.dx, size.height)
      ..close();
    canvas.drawPath(
      area,
      Paint()..color = const Color(0xFF16A36A).withValues(alpha: .20),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = const Color(0xFF16A36A)
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _TrafficChartPainter oldDelegate) =>
      oldDelegate.values != values;
}

class TicketsPage extends StatefulWidget {
  const TicketsPage({super.key});
  @override
  State<TicketsPage> createState() => _TicketsPageState();
}

class _TicketsPageState extends State<TicketsPage> {
  late Future<List<Map<String, dynamic>>> data = salmonService.fetchTickets();
  Future<void> _create() async {
    final subject = TextEditingController(), message = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建工单'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: subject,
              decoration: const InputDecoration(labelText: '问题标题'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: message,
              minLines: 4,
              maxLines: 7,
              decoration: const InputDecoration(
                labelText: '详细描述',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('提交'),
          ),
        ],
      ),
    );
    if (ok == true &&
        subject.text.trim().isNotEmpty &&
        message.text.trim().isNotEmpty) {
      await salmonService.createTicket(
        subject: subject.text.trim(),
        message: message.text.trim(),
      );
      setState(() => data = salmonService.fetchTickets());
    }
    subject.dispose();
    message.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('工单系统'),
      actions: [
        IconButton(
          onPressed: _create,
          icon: const Icon(Icons.add_comment_rounded),
        ),
      ],
    ),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: data,
      builder: (_, snap) {
        if (!snap.hasData)
          return const Center(child: CircularProgressIndicator());
        final list = snap.data!;
        if (list.isEmpty) return const Center(child: Text('暂无工单，点击右上角创建'));
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: list.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (_, i) {
            final t = list[i], id = int.tryParse('${t['id']}') ?? 0;
            final closed = '${t['status']}' == '1';
            return Card(
              child: ListTile(
                leading: Icon(
                  closed
                      ? Icons.check_circle_rounded
                      : Icons.support_agent_rounded,
                ),
                title: Text('${t['subject'] ?? '客服工单'}'),
                subtitle: Text(closed ? '已关闭' : '处理中'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: id == 0
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => TicketDetailPage(id: id),
                        ),
                      ),
              ),
            );
          },
        );
      },
    ),
  );
}

class TicketDetailPage extends StatefulWidget {
  final int id;
  const TicketDetailPage({super.key, required this.id});
  @override
  State<TicketDetailPage> createState() => _TicketDetailPageState();
}

class _TicketDetailPageState extends State<TicketDetailPage> {
  late Future<Map<String, dynamic>> data = salmonService.fetchTicketDetail(
    widget.id,
  );
  Future<void> _reply() async {
    final c = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('回复工单'),
        content: TextField(
          controller: c,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, c.text.trim()),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    c.dispose();
    if (text != null && text.isNotEmpty) {
      try {
        await salmonService.replyTicket(widget.id, text);
        if (!mounted) return;
        setState(() => data = salmonService.fetchTicketDetail(widget.id));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('回复已发送')));
      } catch (error) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('回复失败：${salmonFriendlyError(error)}')),
          );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('工单详情'),
      actions: [
        PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'close') {
              await salmonService.closeTicket(widget.id);
              setState(() => data = salmonService.fetchTicketDetail(widget.id));
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'close', child: Text('关闭工单')),
          ],
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _reply,
      icon: const Icon(Icons.reply_rounded),
      label: const Text('回复'),
    ),
    body: FutureBuilder<Map<String, dynamic>>(
      future: data,
      builder: (_, snap) {
        if (!snap.hasData)
          return const Center(child: CircularProgressIndicator());
        final d = snap.data!;
        final ticket = d['ticket'] is Map
            ? Map<String, dynamic>.from(d['ticket'] as Map)
            : d;
        final raw = d['message'] ?? d['messages'] ?? d['reply'];
        final messages = raw is List ? raw : <dynamic>[];
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF163D82), Color(0xFF245CFF)],
                ),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('工单主题', style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 5),
                  Text(
                    '${ticket['subject'] ?? '客服工单'}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 21,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '工单编号 #${ticket['id'] ?? widget.id}',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (messages.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child: Text('暂无回复'),
                ),
              )
            else
              ...messages.map((e) {
                final m = e is Map ? e : {'message': e};
                final mine =
                    m['is_me'] == true ||
                    '${m['is_me']}' == '1' ||
                    '${m['user_id']}' == '${ticket['user_id']}';
                return Align(
                  alignment: mine
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.sizeOf(context).width * .76,
                    ),
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: mine
                          ? context.colorScheme.primary
                          : context.colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(20),
                        topRight: const Radius.circular(20),
                        bottomLeft: Radius.circular(mine ? 20 : 5),
                        bottomRight: Radius.circular(mine ? 5 : 20),
                      ),
                    ),
                    child: Text(
                      '${m['message'] ?? m['content'] ?? ''}',
                      style: TextStyle(color: mine ? Colors.white : null),
                    ),
                  ),
                );
              }),
          ],
        );
      },
    ),
  );
}

class CustomerCenterPage extends StatelessWidget {
  const CustomerCenterPage({super.key});

  static const _articles = <String>[
    '小火箭 DNS 缓存太慢解决办法',
    '苹果共享 ID',
    '三文鱼客户端使用指南',
    '节点能连通但无法上网？',
    'Clash 客户端常见问题',
    '重置流量是什么意思？',
  ];

  void _showArticle(BuildContext context, String title) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                '如果您仍未解决问题，请返回客服中心点击“开始会话”，客服会在线协助您。',
                style: TextStyle(
                  fontSize: 15,
                  height: 1.7,
                  color: Color(0xFF667085),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF6F8FC),
    appBar: AppBar(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      title: const Text('联系客服', style: TextStyle(fontWeight: FontWeight.w900)),
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: () {},
          icon: const Icon(Icons.refresh_rounded),
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: ListView(
      padding: EdgeInsets.zero,
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 16),
          child: const Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: Color(0xFFEAF8ED),
                child: Icon(Icons.schedule_rounded, color: Color(0xFF16A36A)),
              ),
              SizedBox(width: 14),
              Text('客服工作时间：', style: TextStyle(fontSize: 15)),
              Text(
                '7x24 小时在线',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 38, 24, 8),
          child: Text(
            '尊敬的三文鱼用户，您好！',
            style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            '下面的帮助文章可能已有答案，也可以直接开始会话',
            style: TextStyle(
              fontSize: 16,
              height: 1.5,
              color: Color(0xFF69707D),
            ),
          ),
        ),
        const SizedBox(height: 150),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 18),
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            boxShadow: const [
              BoxShadow(
                color: Color(0x12000000),
                blurRadius: 18,
                offset: Offset(0, 5),
              ),
            ],
          ),
          child: Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '在线',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 5),
                    Text(
                      '通常在几分钟内回复您',
                      style: TextStyle(color: Color(0xFF69707D)),
                    ),
                  ],
                ),
              ),
              const CircleAvatar(
                radius: 24,
                backgroundColor: Colors.black,
                child: Text(
                  'swy',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(36, 12, 36, 24),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const EmbeddedCustomerServicePage(),
              ),
            ),
            icon: const Icon(Icons.chat_bubble_outline_rounded),
            label: const Text(
              '开始会话',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
          ),
        ),
        Container(
          margin: const EdgeInsets.fromLTRB(18, 0, 18, 28),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Text(
                  '最受欢迎文章',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
              ),
              for (final article in _articles)
                ListTile(
                  title: Text(
                    article,
                    style: const TextStyle(color: Color(0xFF606775)),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _showArticle(context, article),
                ),
              TextButton(
                onPressed: () {},
                child: const Padding(
                  padding: EdgeInsets.fromLTRB(10, 0, 10, 14),
                  child: Text('查看所有文章'),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class EmbeddedCustomerServicePage extends StatefulWidget {
  const EmbeddedCustomerServicePage({super.key});

  static WebViewController? _retainedController;
  static int? _retainedSessionRevision;

  static Future<void> clearRetainedSession() async {
    final controller = _retainedController;
    _retainedController = null;
    _retainedSessionRevision = null;
    try {
      await controller?.clearLocalStorage();
    } catch (_) {
      // A closed WebView should not block account logout.
    }
    try {
      await WebViewCookieManager().clearCookies();
    } catch (_) {
      // The account is still cleared if WebView data is unavailable.
    }
  }

  @override
  State<EmbeddedCustomerServicePage> createState() =>
      _EmbeddedCustomerServicePageState();
}

class _EmbeddedCustomerServicePageState
    extends State<EmbeddedCustomerServicePage> {
  static const _chatHtml = r'''<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
  <style>
    html,body { width:100%; height:100%; margin:0; background:#f8faff; overflow:hidden; }
    .woot-widget-bubble { display:none !important; }
    .woot-widget-holder {
      inset:0 !important; width:100% !important; height:100% !important;
      max-height:none !important; border-radius:0 !important;
    }
  </style>
</head>
<body>
<script>
  window.chatwootSettings = {
    hideMessageBubble: true,
    position: 'right',
    locale: 'zh_CN',
    type: 'expanded_bubble'
  };
  (function(d,t) {
    var BASE_URL='https://chat.swywl.com';
    var g=d.createElement(t),s=d.getElementsByTagName(t)[0];
    g.src=BASE_URL+'/packs/js/sdk.js';
    g.async=true;
    s.parentNode.insertBefore(g,s);
    g.onload=function(){
      window.chatwootSDK.run({
        websiteToken:'8SpSTtNMSfp64U8wevUS7wZ7',
        baseUrl:BASE_URL
      });
    };
  })(document,'script');
  window.addEventListener('chatwoot:ready', function() {
    window.$chatwoot.toggle('open');
    ChatwootReady.postMessage('ready');
  });
</script>
</body>
</html>''';

  late final WebViewController controller;
  int progress = 0;
  bool chatReady = false;
  bool usingDirectWidget = false;
  bool failed = false;
  Timer? readyTimer;
  int retryCount = 0;
  bool retryScheduled = false;

  Future<void> _loadDirectWidget() async {
    usingDirectWidget = true;
    if (mounted) {
      setState(() {
        progress = 0;
        failed = false;
        chatReady = false;
      });
    }
    readyTimer?.cancel();
    readyTimer = Timer(const Duration(seconds: 40), () {
      if (mounted && !chatReady) setState(() => failed = true);
    });
    await controller.loadRequest(
      Uri.parse(
        'https://chat.swywl.com/widget?website_token=8SpSTtNMSfp64U8wevUS7wZ7#/',
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    final revision = salmonService.sessionRevision.value;
    final retained =
        EmbeddedCustomerServicePage._retainedSessionRevision == revision
        ? EmbeddedCustomerServicePage._retainedController
        : null;
    controller = retained ?? WebViewController();
    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFF8FAFE))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (value) {
            if (mounted) setState(() => progress = value);
          },
          onPageFinished: (_) {
            if (mounted && usingDirectWidget) {
              readyTimer?.cancel();
              retryCount = 0;
              retryScheduled = false;
              setState(() {
                chatReady = true;
                failed = false;
                progress = 100;
              });
            }
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true && mounted) {
              if (retryCount < 2 && !retryScheduled) {
                retryScheduled = true;
                retryCount++;
                Future<void>.delayed(const Duration(seconds: 2), () async {
                  if (!mounted) return;
                  retryScheduled = false;
                  await _loadDirectWidget();
                });
              } else if (retryCount >= 2) {
                setState(() => failed = true);
              }
            }
          },
        ),
      );
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      final cookieManager = WebViewCookieManager();
      final androidCookieManager = cookieManager.platform;
      if (androidCookieManager is AndroidWebViewCookieManager) {
        unawaited(
          androidCookieManager.setAcceptThirdPartyCookies(platform, true),
        );
      }
      platform.setOnShowFileSelector((_) async {
        final image = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          imageQuality: 88,
        );
        if (image == null) return const [];
        return [Uri.file(image.path).toString()];
      });
    }
    if (retained == null) {
      EmbeddedCustomerServicePage._retainedController = controller;
      EmbeddedCustomerServicePage._retainedSessionRevision = revision;
      _loadDirectWidget();
    } else {
      chatReady = true;
      progress = 100;
    }
  }

  @override
  void dispose() {
    readyTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Stack(
        children: [
          Positioned.fill(child: WebViewWidget(controller: controller)),
          if (!chatReady && !failed)
            Positioned(
              left: 18,
              right: 18,
              top: 14,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  minHeight: 5,
                  value: progress == 0 ? null : progress / 100,
                ),
              ),
            ),
          if (failed)
            Center(
              child: Container(
                margin: const EdgeInsets.all(28),
                padding: const EdgeInsets.all(26),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFE8F0FF), Color(0xFFEDF1FF)],
                  ),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.support_agent_rounded,
                      size: 56,
                      color: Color(0xFF245CFF),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      '客服连接暂时走丢了',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 7),
                    const Text(
                      '请检查网络后重新连接',
                      style: TextStyle(color: Color(0xFF7185A3)),
                    ),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: _loadDirectWidget,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重新连接'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class WindowsEmbeddedCustomerServicePage extends StatefulWidget {
  const WindowsEmbeddedCustomerServicePage({super.key});

  @override
  State<WindowsEmbeddedCustomerServicePage> createState() =>
      _WindowsEmbeddedCustomerServicePageState();
}

class _WindowsEmbeddedCustomerServicePageState
    extends State<WindowsEmbeddedCustomerServicePage> {
  final controller = windows_webview.WebviewController();
  Object? error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final version =
          await windows_webview.WebviewController.getWebViewVersion();
      if (version == null) {
        throw StateError('缺少 Microsoft Edge WebView2 Runtime');
      }
      await controller.initialize();
      await controller.setPopupWindowPolicy(
        windows_webview.WebviewPopupWindowPolicy.deny,
      );
      await controller.loadUrl(salmonSupportUrl);
      if (mounted) setState(() {});
    } catch (value) {
      if (mounted) setState(() => error = value);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('在线客服'),
      actions: [
        IconButton(
          tooltip: '重新加载',
          onPressed: controller.value.isInitialized
              ? () => controller.reload()
              : _initialize,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    body: error != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off_rounded, size: 52),
                  const SizedBox(height: 14),
                  const Text(
                    '客服页面加载失败',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Text('$error', textAlign: TextAlign.center),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: () {
                      setState(() => error = null);
                      _initialize();
                    },
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重新连接'),
                  ),
                ],
              ),
            ),
          )
        : controller.value.isInitialized
        ? windows_webview.Webview(
            controller,
            permissionRequested: (_, _, _) async =>
                windows_webview.WebviewPermissionDecision.allow,
          )
        : const Center(child: CircularProgressIndicator()),
  );
}

class ChatwootPage extends StatefulWidget {
  const ChatwootPage({super.key});
  @override
  State<ChatwootPage> createState() => _ChatwootPageState();
}

class _ChatwootPageState extends State<ChatwootPage> {
  final input = TextEditingController();
  final scroll = ScrollController();
  Timer? refreshTimer;
  String? sourceId;
  int? conversationId;
  List<Map<String, dynamic>> messages = const [];
  String? error;
  bool loading = true;
  bool sending = false;
  bool rebuildingSession = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect({bool rebuild = false}) async {
    if (mounted)
      setState(() {
        loading = true;
        error = null;
      });
    try {
      if (rebuild) await salmonService.clearChatwootSession();
      final user = await salmonService.fetchUserInfo();
      final session = await salmonService.prepareChatwoot(
        '${user['email'] ?? ''}',
      );
      sourceId = '${session['source_id']}';
      conversationId = session['conversation_id'] as int;
      await Future<void>.delayed(const Duration(milliseconds: 450));
      await _refresh(rethrowOnError: true);
      refreshTimer?.cancel();
      refreshTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _refresh(silent: true),
      );
    } catch (e) {
      final message = e.toString();
      if ((message.contains('404') || message.contains('401')) &&
          !rebuild &&
          !rebuildingSession) {
        rebuildingSession = true;
        await _connect(rebuild: true);
        rebuildingSession = false;
        return;
      }
      if (mounted)
        setState(() {
          error = '客服连接失败，请检查网络后重试';
          loading = false;
        });
    }
  }

  Future<void> _refresh({
    bool silent = false,
    bool rethrowOnError = false,
  }) async {
    if (sourceId == null || conversationId == null) return;
    try {
      final value = await salmonService.fetchChatwootMessages(
        sourceId!,
        conversationId!,
      );
      if (!mounted) return;
      setState(() {
        messages = value;
        loading = false;
        error = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scroll.hasClients)
          scroll.animateTo(
            scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOut,
          );
      });
    } catch (e) {
      if (rethrowOnError) rethrow;
      if (!silent && mounted)
        setState(() {
          error = e.toString();
          loading = false;
        });
    }
  }

  Future<void> _send() async {
    final text = input.text.trim();
    if (text.isEmpty || sending) return;
    setState(() => sending = true);
    try {
      if (sourceId == null || conversationId == null) return;
      await salmonService.sendChatwootMessage(sourceId!, conversationId!, text);
      input.clear();
      await _refresh();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('发送失败：$e')));
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      automaticallyImplyLeading: false,
      title: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('在线客服', style: TextStyle(fontWeight: FontWeight.w900)),
          Text('三文鱼客服团队', style: TextStyle(fontSize: 12)),
        ],
      ),
      actions: [
        IconButton(
          onPressed: _connect,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : error != null
        ? Center(
            child: Container(
              margin: const EdgeInsets.all(28),
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFE8F0FF), Color(0xFFEDF1FF)],
                ),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: const Color(0xFFCCD9F6)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.support_agent_rounded,
                    size: 58,
                    color: Color(0xFF617DE2),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF243B63),
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: _connect,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重新连接'),
                  ),
                ],
              ),
            ),
          )
        : Column(
            children: [
              Expanded(
                child: messages.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.waving_hand_rounded,
                              color: Color(0xFF245CFF),
                              size: 48,
                            ),
                            const SizedBox(height: 12),
                            const Text('你好呀，有什么可以帮你？'),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: scroll,
                        padding: const EdgeInsets.all(16),
                        itemCount: messages.length,
                        itemBuilder: (_, index) {
                          final message = messages[index];
                          final mine =
                              int.tryParse('${message['message_type']}') == 0;
                          return Align(
                            alignment: mine
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.sizeOf(context).width * .76,
                              ),
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 15,
                                vertical: 11,
                              ),
                              decoration: BoxDecoration(
                                color: mine
                                    ? const Color(0xFF245CFF)
                                    : context.colorScheme.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Text(
                                '${message['content'] ?? ''}',
                                style: TextStyle(
                                  color: mine ? Colors.white : null,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: input,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.newline,
                          decoration: InputDecoration(
                            hintText: '输入消息…',
                            filled: true,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(22),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        onPressed: sending ? null : _send,
                        icon: sending
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.send_rounded),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
  );
}

class ChainProxyPage extends ConsumerStatefulWidget {
  const ChainProxyPage({super.key});
  @override
  ConsumerState<ChainProxyPage> createState() => _ChainProxyPageState();
}

class _ChainProxyPageState extends ConsumerState<ChainProxyPage> {
  String? entry;
  String? exit;

  bool _real(Proxy proxy) => !const {
    'Selector',
    'URLTest',
    'Fallback',
    'LoadBalance',
    'Direct',
    'Reject',
    'Compatible',
  }.contains(proxy.type);

  Future<void> _save(List<String> nodes) async {
    if (entry == null || exit == null || entry == exit) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请选择两个不同的节点')));
      return;
    }
    final profileId = ref.read(currentProfileIdProvider);
    if (profileId == null) return;
    final relay = ProxyGroup(
      id: snowflake.id,
      name: '链式代理',
      type: GroupType.Relay,
      proxies: [entry!, exit!],
    );
    ref.read(proxyGroupsProvider(profileId).notifier).put(relay);
    ref
        .read(profilesProvider.notifier)
        .updateProfile(
          profileId,
          (profile) => profile.copyWith(overwriteType: OverwriteType.custom),
        );
    ref
        .read(setupActionProvider.notifier)
        .applyProfileDebounce(force: true, silence: true);
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('链式代理已创建，请在节点页选择“链式代理”')));
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(currentGroupsStateProvider).value;
    final nodes = groups
        .expand((g) => g.all)
        .where(_real)
        .map((e) => e.name)
        .toSet()
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('链式代理')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFFEAF2FF),
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Text(
              '流量路径：设备 → 入口节点 → 出口节点 → 目标网站\n\n链式代理会增加延迟，建议入口和出口选择不同地区。',
            ),
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<String>(
            initialValue: entry,
            decoration: const InputDecoration(
              labelText: '入口节点',
              prefixIcon: Icon(Icons.login_rounded),
              border: OutlineInputBorder(),
            ),
            items: nodes
                .map(
                  (e) => DropdownMenuItem(
                    value: e,
                    child: Text(e, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: (v) => setState(() => entry = v),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: exit,
            decoration: const InputDecoration(
              labelText: '出口节点',
              prefixIcon: Icon(Icons.logout_rounded),
              border: OutlineInputBorder(),
            ),
            items: nodes
                .map(
                  (e) => DropdownMenuItem(
                    value: e,
                    child: Text(e, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: (v) => setState(() => exit = v),
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: () => _save(nodes),
            icon: const Icon(Icons.account_tree_rounded),
            label: const Text('创建链式代理'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
          ),
        ],
      ),
    );
  }
}

class DnsOverridePage extends ConsumerWidget {
  const DnsOverridePage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(overrideDnsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('DNS 覆改')),
      body: Column(
        children: [
          SwitchListTile(
            value: enabled,
            onChanged: (value) {
              ref.read(overrideDnsProvider.notifier).value = value;
              ref
                  .read(setupActionProvider.notifier)
                  .applyProfileDebounce(force: true, silence: true);
            },
            secondary: const Icon(Icons.dns_rounded),
            title: const Text(
              '启用 DNS 覆改',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
            subtitle: const Text('开启后使用下面的 DNS 设置覆盖订阅配置'),
          ),
          const Divider(height: 1),
          const Expanded(child: DnsListView()),
        ],
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final String used, total;
  final double ratio;
  final String Function(dynamic) money;
  const _AccountCard({
    required this.data,
    required this.used,
    required this.total,
    required this.ratio,
    required this.money,
  });

  String _planStatus() {
    final planName = '${data['plan_name'] ?? ''}';
    if (planName.isEmpty || planName == '暂无套餐') return '套餐已过期';
    final raw = int.tryParse('${data['expired_at'] ?? data['expire'] ?? ''}');
    if (raw == null || raw <= 0) return '$planName · 长期有效';
    final expiry = DateTime.fromMillisecondsSinceEpoch(
      raw < 100000000000 ? raw * 1000 : raw,
    );
    final remaining = expiry.difference(DateTime.now());
    if (remaining.inSeconds <= 0) return '套餐已过期';
    final days = (remaining.inHours / 24).ceil();
    return '$planName · 剩余 $days 天';
  }

  String _resetTrafficTime() {
    final date = salmonTrafficResetDate(data);
    if (date == null) return '流量重置：${salmonTrafficResetSummary(data)}';
    return '流量重置：${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF245CFF), Color(0xFF526FEF), Color(0xFF755BFF)],
      ),
      borderRadius: BorderRadius.circular(34),
      boxShadow: [
        BoxShadow(
          color: const Color(0xFF245CFF).withValues(alpha: .22),
          blurRadius: 28,
          offset: const Offset(0, 13),
        ),
      ],
    ),
    child: Column(
      children: [
        Row(
          children: [
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .22),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white38),
              ),
              child: const Icon(
                Icons.set_meal_rounded,
                color: Colors.white,
                size: 36,
              ),
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${data['email'] ?? '三文鱼用户'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    _planStatus(),
                    style: const TextStyle(color: Colors.white70),
                  ),
                  Text(
                    _resetTrafficTime(),
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: _Value(label: '账户余额', value: money(data['balance'])),
            ),
            Expanded(
              child: _Value(
                label: '佣金余额',
                value: money(data['commission_balance']),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Text('流量使用', style: TextStyle(color: Colors.white70)),
            const Spacer(),
            Text(
              '$used / $total',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 8,
            backgroundColor: Colors.white24,
            color: const Color(0xFF9CC4FF),
          ),
        ),
      ],
    ),
  );
}

class _Value extends StatelessWidget {
  final String label, value;
  const _Value({required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: Colors.white60)),
      Text(
        value,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w900,
        ),
      ),
    ],
  );
}

class _InviteStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InviteStat({
    required this.icon,
    required this.label,
    required this.value,
  });
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Icon(icon, color: Colors.white, size: 27),
      const SizedBox(height: 6),
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      const SizedBox(height: 3),
      Text(
        value,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: 17,
        ),
      ),
    ],
  );
}

class _MenuGroup extends StatelessWidget {
  final List<Widget> children;
  const _MenuGroup({required this.children});
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFFFFFF), Color(0xFFF3F6FC)],
      ),
      borderRadius: BorderRadius.circular(30),
      border: Border.all(
        color: context.colorScheme.outlineVariant.withValues(alpha: .4),
      ),
      boxShadow: [
        BoxShadow(
          color: const Color(0xFF7A91B8).withValues(alpha: .08),
          blurRadius: 22,
          offset: const Offset(0, 9),
        ),
      ],
    ),
    child: Column(children: children),
  );
}

class _Menu extends StatefulWidget {
  final IconData icon;
  final String title, subtitle;
  final FutureOr<void> Function() onTap;
  const _Menu({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  State<_Menu> createState() => _MenuState();
}

class _MenuState extends State<_Menu> {
  bool locked = false;

  Future<void> _handleTap() async {
    if (locked) return;
    setState(() => locked = true);
    try {
      await Future<void>.sync(widget.onTap);
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (mounted) setState(() => locked = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const palette = [
      (Color(0xFFDCEBFF), Color(0xFF568ED6)),
      (Color(0xFFE2F8FF), Color(0xFFE36F9B)),
      (Color(0xFFE8EDFF), Color(0xFF7E6ED8)),
      (Color(0xFFDFF7EE), Color(0xFF16A36A)),
    ];
    final colors =
        palette[widget.title.codeUnits.fold<int>(
              0,
              (sum, value) => sum + value,
            ) %
            palette.length];
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      leading: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(color: colors.$1, shape: BoxShape.circle),
        child: Icon(widget.icon, color: colors.$2),
      ),
      title: Text(
        widget.title,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Text(widget.subtitle),
      trailing: locked
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.chevron_right_rounded),
      onTap: locked ? null : _handleTap,
    );
  }
}

class _SheetHeader extends StatelessWidget {
  final String title;
  final Widget? action;
  const _SheetHeader({required this.title, this.action});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 14, 12),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: context.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        if (action != null) action!,
      ],
    ),
  );
}
