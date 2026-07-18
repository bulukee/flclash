import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/manager/window_manager.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/services/salmon_service.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

class AppStateManager extends ConsumerStatefulWidget {
  final Widget child;

  const AppStateManager({super.key, required this.child});

  @override
  ConsumerState<AppStateManager> createState() => _AppStateManagerState();
}

class _AppStateManagerState extends ConsumerState<AppStateManager>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.listenManual(checkIpProvider, (prev, next) {
      if (prev != next && next.a && next.c) {
        ref.read(networkDetectionProvider.notifier).startCheck();
      }
    });
    ref.listenManual(configProvider, (prev, next) {
      if (prev != next) {
        globalState.container
            .read(storeActionProvider.notifier)
            .savePreferencesDebounce();
      }
    });
    ref.listenManual(needUpdateGroupsProvider, (prev, next) {
      if (prev != next) {
        globalState.container
            .read(proxiesActionProvider.notifier)
            .updateGroupsDebounce();
      }
    });
    ref.listenManual(suspendProvider, (prev, next) {
      final isStart = ref.read(isStartProvider);
      if (prev != next && isStart) {
        debouncer.call(FunctionTag.suspend, () async {
          if (next == true) {
            await coreController.stopListener();
          } else {
            await coreController.startListener();
          }
          ref.read(checkIpNumProvider.notifier).add();
        });
      }
    });
    if (system.isMacOS) {
      ref.listenManual(autoSetSystemDnsStateProvider, (prev, next) async {
        if (prev == next) {
          return;
        }
        if (next.a == true && next.b == true) {
          macOS?.updateDns(false);
        } else {
          macOS?.updateDns(true);
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    commonPrint.log('$state');
    if (state == AppLifecycleState.resumed) {
      permissions.check();
      render?.resume();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ref = globalState.container;
        ref.read(setupActionProvider.notifier).tryCheckIp();
        if (system.isAndroid) {
          ref.read(coreActionProvider.notifier).tryStartCore();
        }
      });
    }
  }

  @override
  void didChangePlatformBrightness() {
    globalState.container.read(themeActionProvider.notifier).updateBrightness();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerHover: (_) {
        render?.resume();
      },
      child: widget.child,
    );
  }
}

class AppEnvManager extends StatelessWidget {
  final Widget child;

  const AppEnvManager({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (kDebugMode) {
      if (globalState.isPre) {
        return Banner(
          message: 'DEBUG',
          location: BannerLocation.topEnd,
          child: child,
        );
      }
    }
    if (globalState.isPre) {
      return Banner(
        message: 'PRE',
        location: BannerLocation.topEnd,
        child: child,
      );
    }
    return child;
  }
}

class AppSidebarContainer extends ConsumerWidget {
  final Widget child;

  const AppSidebarContainer({super.key, required this.child});

  // Widget _buildLoading() {
  //   return Consumer(
  //     builder: (_, ref, _) {
  //       final loading = ref.watch(loadingProvider);
  //       final isMobileView = ref.watch(isMobileViewProvider);
  //       return loading && !isMobileView
  //           ? RotatedBox(
  //               quarterTurns: 1,
  //               child: const LinearProgressIndicator(),
  //             )
  //           : Container();
  //     },
  //   );
  // }

  Widget _buildBackground({
    required BuildContext context,
    required Widget child,
  }) {
    return Material(color: context.colorScheme.surfaceContainer, child: child);
    // if (!system.isMacOS) {
    //   return Material(
    //     color: context.colorScheme.surfaceContainer,
    //     child: child,
    //   );
    // }
    // return child;
    // return TransparentMacOSSidebar(
    //   child: Material(color: Colors.transparent, child: child),
    // );
  }

  void _updateSideBarWidth(WidgetRef ref, double contentWidth) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(sideWidthProvider.notifier).value =
          ref.read(viewSizeProvider.select((state) => state.width)) -
          contentWidth;
    });
  }

  void _handleToPage(PageLabel pageLabel) {
    globalState.container
        .read(currentPageLabelProvider.notifier)
        .toPage(pageLabel);
  }

  String _navigationLabel(PageLabel label) => switch (label) {
    PageLabel.dashboard => '加速',
    PageLabel.profiles => '线路',
    PageLabel.proxies => '商店',
    PageLabel.invites => '返利',
    PageLabel.customerService => '客服',
    PageLabel.tools => '我的',
    _ => Intl.message(label.name),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navigationState = ref.watch(navigationStateProvider);
    final navigationItems = navigationState.navigationItems;
    final isMobileView = navigationState.viewMode == ViewMode.mobile;
    if (isMobileView) {
      return child;
    }
    final currentIndex = navigationState.currentIndex;
    final showLabel = ref.watch(appSettingProvider).showLabel;
    return Row(
      children: [
        _buildBackground(
          context: context,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (system.isMacOS) const SizedBox(height: 22),
                const SizedBox(height: 10),
                if (!system.isMacOS) ...[
                  const ClipRect(child: AppIcon()),
                  const SizedBox(height: 12),
                ],
                Expanded(
                  child: ScrollConfiguration(
                    behavior: HiddenBarScrollBehavior(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: NavigationRail(
                            scrollable: true,
                            minExtendedWidth: 260,
                            backgroundColor: Colors.transparent,
                            selectedLabelTextStyle: context
                                .textTheme
                                .titleSmall!
                                .copyWith(color: context.colorScheme.onSurface),
                            unselectedLabelTextStyle: context
                                .textTheme
                                .titleSmall!
                                .copyWith(color: context.colorScheme.onSurface),
                            destinations: navigationItems
                                .map(
                                  (e) => NavigationRailDestination(
                                    icon: e.icon,
                                    label: Text(_navigationLabel(e.label)),
                                  ),
                                )
                                .toList(),
                            onDestinationSelected: (index) {
                              _handleToPage(navigationItems[index].label);
                            },
                            extended: system.isWindows || showLabel,
                            selectedIndex: currentIndex,
                            labelType: NavigationRailLabelType.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (system.isWindows) const _DesktopSidebarStatus(),
                if (!system.isWindows) ...[
                  const SizedBox(height: 12),
                  IconButton(
                    onPressed: () {
                      ref
                          .read(appSettingProvider.notifier)
                          .update(
                            (state) =>
                                state.copyWith(showLabel: !state.showLabel),
                          );
                    },
                    icon: Icon(
                      Icons.menu,
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
        Expanded(
          flex: 1,
          child: ClipRect(
            child: LayoutBuilder(
              builder: (_, constraints) {
                _updateSideBarWidth(ref, constraints.maxWidth);
                return child;
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _DesktopSidebarStatus extends ConsumerStatefulWidget {
  const _DesktopSidebarStatus();

  @override
  ConsumerState<_DesktopSidebarStatus> createState() =>
      _DesktopSidebarStatusState();
}

class _DesktopSidebarStatusState extends ConsumerState<_DesktopSidebarStatus> {
  late final Future<Map<String, dynamic>> _account = _loadAccount();

  Future<Map<String, dynamic>> _loadAccount() async {
    try {
      final values = await Future.wait([
        salmonService.fetchUserInfo(),
        salmonService.fetchSubscribeInfo(),
        salmonService.fetchPlans(),
      ]);
      final user = Map<String, dynamic>.from(values[0] as Map);
      final subscription = Map<String, dynamic>.from(values[1] as Map);
      final plans = values[2] as List<Map<String, dynamic>>;
      final planId = int.tryParse(
        '${subscription['plan_id'] ?? user['plan_id'] ?? ''}',
      );
      final selected = plans.where(
        (plan) => int.tryParse('${plan['id']}') == planId,
      );
      final userPlan = user['plan'];
      final fallbackPlanName =
          subscription['plan_name']?.toString() ??
          (userPlan is Map ? userPlan['name']?.toString() : null) ??
          user['plan_name']?.toString() ??
          (planId != null && planId > 0 ? '已有套餐' : '未开通套餐');
      final result = <String, dynamic>{
        ...user,
        ...subscription,
        'plan_name': selected.isEmpty
            ? fallbackPlanName
            : '${selected.first['name']}',
      };
      salmonAccountCache = result;
      salmonAccountCacheAt = DateTime.now();
      return result;
    } catch (_) {
      return salmonAccountCache ?? const <String, dynamic>{};
    }
  }

  String _speed(num value) {
    if (value >= 1048576) return '${(value / 1048576).toStringAsFixed(1)} MB/s';
    if (value >= 1024) return '${(value / 1024).toStringAsFixed(0)} KB/s';
    return '$value B/s';
  }

  String _traffic(num value) =>
      value <= 0 ? '0 GB' : '${(value / 1073741824).toStringAsFixed(1)} GB';

  String _expiryLabel(Map<String, dynamic> account, bool noPlan) {
    if (noPlan) return '尚未开通套餐';
    final raw = account['expired_at'] ?? account['expire'];
    final epoch = int.tryParse('${raw ?? ''}');
    if (epoch != null && epoch > 0) {
      final date = DateTime.fromMillisecondsSinceEpoch(
        epoch < 100000000000 ? epoch * 1000 : epoch,
      );
      if (date.isBefore(DateTime.now())) return '套餐已过期';
      return '到期 ${DateFormat('yyyy-MM-dd').format(date)}';
    }
    final parsed = DateTime.tryParse('${raw ?? ''}');
    if (parsed != null) {
      if (parsed.isBefore(DateTime.now())) return '套餐已过期';
      return '到期 ${DateFormat('yyyy-MM-dd').format(parsed)}';
    }
    return '长期有效';
  }

  @override
  Widget build(BuildContext context) {
    final traffic = ref.watch(
      trafficsProvider.select((state) => state.list.safeLast(const Traffic())),
    );
    return FutureBuilder<Map<String, dynamic>>(
      future: _account,
      builder: (context, snapshot) => _buildCard(
        context,
        traffic,
        snapshot.data ?? salmonAccountCache ?? const <String, dynamic>{},
      ),
    );
  }

  Widget _buildCard(
    BuildContext context,
    Traffic traffic,
    Map<String, dynamic> account,
  ) {
    final total = num.tryParse('${account['transfer_enable'] ?? 0}') ?? 0;
    final used =
        (num.tryParse('${account['u'] ?? 0}') ?? 0) +
        (num.tryParse('${account['d'] ?? 0}') ?? 0);
    final rawPlan = '${account['plan_name'] ?? ''}'.trim();
    final noPlan = rawPlan.isEmpty || rawPlan == '暂无套餐' || rawPlan == '未开通套餐';
    final planName = noPlan ? '未开通套餐' : rawPlan;
    final remaining = noPlan ? 0 : (total - used).clamp(0, total);
    final progress = total <= 0 ? 0.0 : (used / total).clamp(0, 1).toDouble();
    return Container(
      width: 220,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF7FAFF), Color(0xFFF2EFFF)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFD6E2F7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.workspace_premium_rounded,
                size: 15,
                color: Color(0xFF755BFF),
              ),
              const SizedBox(width: 6),
              Text(
                planName,
                style: context.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            _expiryLabel(account, noPlan),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFF405E86),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            '剩余 ${_traffic(remaining)}',
            style: context.textTheme.titleMedium?.copyWith(
              color: const Color(0xFF245CFF),
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: noPlan ? 0 : progress,
              minHeight: 6,
              backgroundColor: const Color(0xFFDDE7F8),
              color: const Color(0xFF3C72FF),
            ),
          ),
          const Divider(height: 16),
          Row(
            children: [
              const Icon(
                Icons.speed_rounded,
                size: 13,
                color: Color(0xFF245CFF),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '↑ ${_speed(traffic.up)}  ↓ ${_speed(traffic.down)}',
                  maxLines: 1,
                  style: context.textTheme.labelMedium?.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
