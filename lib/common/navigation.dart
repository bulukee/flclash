import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/views/views.dart';
import 'package:flutter/material.dart';

class Navigation {
  static Navigation? _instance;

  List<NavigationItem> getItems({
    bool openLogs = false,
    bool hasProxies = false,
  }) {
    return [
      NavigationItem(
        keep: false,
        icon: const Icon(Icons.home_rounded),
        label: PageLabel.dashboard,
        builder: (_) =>
            const DashboardView(key: GlobalObjectKey(PageLabel.dashboard)),
      ),
      NavigationItem(
        icon: const Icon(Icons.travel_explore_rounded),
        label: PageLabel.profiles,
        builder: (_) =>
            const ProxiesView(key: GlobalObjectKey(PageLabel.profiles)),
        modes: const [NavigationItemMode.mobile, NavigationItemMode.desktop],
      ),
      NavigationItem(
        icon: const Icon(Icons.shopping_bag_rounded),
        label: PageLabel.proxies,
        builder: (_) =>
            const PurchaseView(key: GlobalObjectKey(PageLabel.proxies)),
        modes: const [NavigationItemMode.mobile, NavigationItemMode.desktop],
      ),
      NavigationItem(
        keep: false,
        icon: const Icon(Icons.card_giftcard_rounded),
        label: PageLabel.invites,
        builder: (_) => const InvitationPage(),
        modes: const [NavigationItemMode.desktop],
      ),
      NavigationItem(
        keep: false,
        icon: const Icon(Icons.support_agent_rounded),
        label: PageLabel.customerService,
        builder: (_) => const AccountView(
          initialAction: AccountInitialAction.customerService,
        ),
        modes: const [NavigationItemMode.desktop],
      ),
      NavigationItem(
        icon: const Icon(Icons.account_circle_rounded),
        label: PageLabel.tools,
        builder: (_) =>
            const AccountView(key: GlobalObjectKey(PageLabel.tools)),
        modes: const [NavigationItemMode.mobile, NavigationItemMode.desktop],
      ),
    ];
  }

  Navigation._internal();

  factory Navigation() {
    _instance ??= Navigation._internal();
    return _instance!;
  }
}

final navigation = Navigation();
