import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/services/salmon_profile_sync.dart';
import 'package:fl_clash/services/salmon_service.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

class PurchaseView extends ConsumerStatefulWidget {
  const PurchaseView({super.key});

  @override
  ConsumerState<PurchaseView> createState() => _PurchaseViewState();
}

class _PurchaseViewState extends ConsumerState<PurchaseView> {
  late Future<List<Map<String, dynamic>>> _plans;
  late Future<List<Map<String, dynamic>>> _payments;
  bool _processing = false;

  static const _cycles = <String, String>{
    'month_price': '月付',
    'quarter_price': '季付',
    'half_year_price': '半年',
    'year_price': '年付',
    'two_year_price': '两年',
    'three_year_price': '三年',
    'onetime_price': '一次性',
  };

  @override
  void initState() {
    super.initState();
    final cacheFresh =
        salmonStoreCacheAt != null &&
        DateTime.now().difference(salmonStoreCacheAt!) <
            const Duration(minutes: 5);
    _plans = cacheFresh && salmonPlansCache != null
        ? Future.value(salmonPlansCache!)
        : _loadPlans();
    _payments = cacheFresh && salmonPaymentsCache != null
        ? Future.value(salmonPaymentsCache!)
        : _loadPayments();
  }

  Future<List<Map<String, dynamic>>> _loadPlans({
    bool forceRefresh = false,
  }) async {
    final value = await salmonService.fetchPlans(forceRefresh: forceRefresh);
    salmonPlansCache = value;
    salmonStoreCacheAt = DateTime.now();
    return value;
  }

  Future<List<Map<String, dynamic>>> _loadPayments({
    bool forceRefresh = false,
  }) async {
    final value = await salmonService.fetchPaymentMethods(
      forceRefresh: forceRefresh,
    );
    salmonPaymentsCache = value;
    salmonStoreCacheAt = DateTime.now();
    return value;
  }

  String _money(dynamic value) {
    final cents = num.tryParse('${value ?? ''}');
    if (cents == null) return '--';
    final price = (cents / 100)
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
    return '¥$price';
  }

  List<MapEntry<String, String>> _availableCycles(Map<String, dynamic> plan) {
    return _cycles.entries.where((entry) {
      final price = num.tryParse('${plan[entry.key] ?? ''}');
      return price != null && price > 0;
    }).toList();
  }

  String _plainText(dynamic source) {
    final raw = '${source ?? ''}'.trim();
    if (raw.startsWith('[') || raw.startsWith('{')) {
      try {
        final decoded = jsonDecode(raw);
        final items = decoded is List ? decoded : [decoded];
        final features = <String>[];
        for (final item in items.whereType<Map>()) {
          final feature = item['feature']?.toString().trim();
          if (feature != null && feature.isNotEmpty) features.add(feature);
        }
        if (features.isNotEmpty) return features.join(' · ');
      } catch (_) {
        // Fall back to stripping markup below.
      }
    }
    return raw
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'&nbsp;'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Future<void> _selectPayment(Map<String, dynamic> plan, String cycle) async {
    List<Map<String, dynamic>> payments;
    try {
      payments = await _payments;
    } catch (_) {
      _payments = salmonService.fetchPaymentMethods(forceRefresh: true);
      payments = await _payments;
    }
    if (!mounted) return;
    if (payments.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂无可用支付方式')));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 2, 18, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '支付方式',
                style: context.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 14),
              ...payments.map(
                (payment) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    tileColor: context.colorScheme.surfaceContainerLow,
                    leading: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: context.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        Icons.account_balance_wallet_rounded,
                        color: context.colorScheme.primary,
                      ),
                    ),
                    title: Text(
                      '${payment['name'] ?? payment['payment'] ?? '在线支付'}',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _checkout(
                        planId: (plan['id'] as num).toInt(),
                        cycle: cycle,
                        method: (payment['id'] as num).toInt(),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _checkout({
    required int planId,
    required String cycle,
    required int method,
  }) async {
    if (_processing) return;
    setState(() => _processing = true);
    try {
      final tradeNo = await salmonService.createOrder(
        planId: planId,
        cycle: cycle,
      );
      final checkout = await salmonService.checkoutOrder(
        tradeNo: tradeNo,
        method: method,
      );
      final type = int.tryParse('${checkout['type'] ?? 1}') ?? 1;
      final data = '${checkout['data'] ?? ''}';
      if (!mounted || data.isEmpty) return;
      if (type == 1) {
        final uri = Uri.parse(data);
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
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.network(
                    data,
                    width: 230,
                    height: 230,
                    errorBuilder: (_, _, _) => SelectableText(data),
                  ),
                ),
                const SizedBox(height: 14),
                const Text('支付完成后返回 App 即可'),
              ],
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
      final completed = await salmonService.waitForOrderCompleted(tradeNo);
      if (!mounted) return;
      if (completed) {
        final session = await salmonService.restore();
        if (session != null && session.subscribeUrl.isNotEmpty) {
          await syncSalmonProfile(ref, session.subscribeUrl);
        }
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('支付成功，套餐已更新')));
        setState(() {
          _plans = _loadPlans(forceRefresh: true);
          _payments = _loadPayments(forceRefresh: true);
        });
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂未确认到账，可稍后在订单记录中查看')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(salmonFriendlyError(error, fallback: '下单失败，请稍后重试')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: context.appLocalizations.salmonPlans,
      body: Stack(
        children: [
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _plans,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const _StoreLoading();
              }
              final plans = snapshot.data ?? const [];
              return RefreshIndicator(
                onRefresh: () async {
                  setState(() {
                    _plans = _loadPlans(forceRefresh: true);
                    _payments = _loadPayments(forceRefresh: true);
                  });
                  await _plans;
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
                  children: [
                    Container(
                      margin: const EdgeInsets.only(bottom: 20),
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFDCE7FA), Color(0xFFE8EDFF)],
                        ),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: const Color(0xFFDDE7F6)),
                      ),
                      child: const Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '挑选你的专属套餐',
                                  style: TextStyle(
                                    color: Color(0xFF29496F),
                                    fontSize: 20,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                SizedBox(height: 7),
                                Text(
                                  '灵活周期 · 安心续费 · 即买即用',
                                  style: TextStyle(color: Color(0xFF7185A3)),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.auto_awesome_rounded,
                            size: 46,
                            color: Color(0xFF755BFF),
                          ),
                        ],
                      ),
                    ),
                    if (plans.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 60),
                        child: Center(child: Text('暂时没有可购买的套餐')),
                      )
                    else
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final columns = constraints.maxWidth >= 1120
                              ? 3
                              : constraints.maxWidth >= 720
                              ? 2
                              : 1;
                          const gap = 16.0;
                          final width =
                              (constraints.maxWidth - gap * (columns - 1)) /
                              columns;
                          return Wrap(
                            spacing: gap,
                            runSpacing: gap,
                            children: plans.asMap().entries.map((entry) {
                              return SizedBox(
                                width: width,
                                child: _PlanCard(
                                  plan: entry.value,
                                  featured: entry.key == 1 || plans.length == 1,
                                  cycles: _availableCycles(entry.value),
                                  description: _plainText(
                                    entry.value['content'],
                                  ),
                                  money: _money,
                                  onBuy: (period) =>
                                      _selectPayment(entry.value, period),
                                ),
                              );
                            }).toList(),
                          );
                        },
                      ),
                  ],
                ),
              );
            },
          ),
          if (_processing)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.28),
                child: const Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatefulWidget {
  final Map<String, dynamic> plan;
  final bool featured;
  final List<MapEntry<String, String>> cycles;
  final String description;
  final String Function(dynamic value) money;
  final ValueChanged<String> onBuy;

  const _PlanCard({
    required this.plan,
    required this.featured,
    required this.cycles,
    required this.description,
    required this.money,
    required this.onBuy,
  });

  @override
  State<_PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<_PlanCard> {
  late String _period;

  @override
  void initState() {
    super.initState();
    _period = widget.cycles.isEmpty ? '' : widget.cycles.first.key;
  }

  bool get _onetimeOnly =>
      widget.cycles.length == 1 && widget.cycles.first.key == 'onetime_price';

  List<String> get _features {
    final result = <String>[];
    final seen = <String>{};
    final quota = '${widget.plan['transfer_enable'] ?? ''}'.trim();
    for (final source in widget.description.split(RegExp(r'\s*[·|]\s*'))) {
      final value = source.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (value.isEmpty || value == 'true' || value == 'false') continue;
      if (RegExp(
        r'(月付|季付|半年|年付|两年|三年)\s*\d',
        caseSensitive: false,
      ).hasMatch(value)) {
        continue;
      }
      if (quota.isNotEmpty &&
          value.contains('${quota}GB') &&
          value.contains('流量')) {
        continue;
      }
      final key = value.toLowerCase().replaceAll(' ', '');
      if (seen.add(key)) result.add(value);
      if (result.length == 6) break;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final featured = widget.featured;
    final selectedCycle = widget.cycles
        .where((e) => e.key == _period)
        .firstOrNull;
    final price = widget.money(_period.isEmpty ? null : plan[_period]);
    const accent = Color(0xFF245CFF);
    final cardColor = featured
        ? const Color(0xFFEAF1FF)
        : context.colorScheme.surfaceContainerLow;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: featured ? accent : context.colorScheme.outlineVariant,
          width: featured ? 2 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: (featured ? accent : Colors.black).withValues(alpha: 0.12),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${plan['name'] ?? '网络套餐'}',
                    style: context.textTheme.titleLarge?.copyWith(
                      color: const Color(0xFF29496F),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                if (featured)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      '推荐套餐',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  price,
                  style: const TextStyle(
                    color: Color(0xFF29496F),
                    fontSize: 31,
                    height: 1,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    selectedCycle == null ? '' : '/ ${selectedCycle.value}',
                    style: TextStyle(
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            if (!_onetimeOnly && widget.cycles.length > 1) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: widget.cycles
                    .where((cycle) => cycle.key != 'onetime_price')
                    .map((cycle) {
                      final active = cycle.key == _period;
                      return ChoiceChip(
                        selected: active,
                        showCheckmark: true,
                        label: Text(cycle.value),
                        selectedColor: accent,
                        labelStyle: TextStyle(
                          color: active ? Colors.white : accent,
                          fontWeight: FontWeight.w800,
                        ),
                        side: BorderSide.none,
                        backgroundColor: accent.withValues(alpha: 0.09),
                        onSelected: (_) => setState(() => _period = cycle.key),
                      );
                    })
                    .toList(),
              ),
            ],
            const SizedBox(height: 16),
            _FeatureLine(text: '${plan['transfer_enable'] ?? '--'} GB 高速流量'),
            for (final feature in _features) _FeatureLine(text: feature),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: _period.isEmpty ? null : () => widget.onBuy(_period),
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.shopping_cart_checkout_rounded),
                    SizedBox(width: 8),
                    Text('立即购买', style: TextStyle(fontWeight: FontWeight.w900)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeatureLine extends StatelessWidget {
  final String text;

  const _FeatureLine({required this.text});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 9),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: const Color(0xFF245CFF).withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.check_rounded,
            size: 17,
            color: Color(0xFF245CFF),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: context.textTheme.bodyMedium)),
      ],
    ),
  );
}

class _StoreLoading extends StatelessWidget {
  const _StoreLoading();

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
    children: [
      Container(
        height: 118,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFE1EAF8), Color(0xFFECE8FA)],
          ),
          borderRadius: BorderRadius.circular(28),
        ),
      ),
      const SizedBox(height: 20),
      for (var index = 0; index < 2; index++) ...[
        Container(
          height: 310,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: const Color(0xFFDCE5F2)),
          ),
          child: const Center(
            child: SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
          ),
        ),
        const SizedBox(height: 18),
      ],
    ],
  );
}
