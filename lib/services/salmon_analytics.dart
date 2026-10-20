import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:fl_clash/services/salmon_dns.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Data only: GitCode must never supply executable tracking scripts.
class SalmonAnalyticsConfig {
  final Uri endpoint;
  final int siteId;

  const SalmonAnalyticsConfig({required this.endpoint, required this.siteId});

  static SalmonAnalyticsConfig? fromJson(dynamic value) {
    if (value is! Map ||
        value['enabled'] != true ||
        value['provider'] != 'matomo') {
      return null;
    }
    final url = value['url'];
    final endpoint = url is String ? Uri.tryParse(url.trim()) : null;
    final siteId = int.tryParse('${value['siteId']}');
    if (endpoint == null ||
        endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        !endpoint.path.endsWith('/matomo.php') ||
        siteId == null ||
        siteId <= 0) {
      return null;
    }
    return SalmonAnalyticsConfig(endpoint: endpoint, siteId: siteId);
  }
}

enum SalmonAnalyticsScreen {
  login('登录'),
  home('首页'),
  nodes('节点'),
  plans('套餐购买'),
  account('我的'),
  invitations('邀请'),
  support('客服');

  final String title;
  const SalmonAnalyticsScreen(this.title);
}

class SalmonAnalytics {
  static const _enabledKey = 'salmon_analytics_enabled';
  static const _visitorKey = 'salmon_analytics_visitor_id';
  final Dio _dio;
  final Duration requestTimeout;
  final enabled = ValueNotifier<bool>(true);
  final _pending = <CancelToken>{};
  final _random = Random.secure();
  Future<void>? _initialization;
  Future<String>? _visitorInitialization;
  SharedPreferences? _preferences;
  SalmonAnalyticsConfig? _config;
  String? _visitorId;
  bool _started = false;
  SalmonAnalyticsScreen? _lastScreen;
  SalmonAnalyticsScreen? _currentScreen;

  SalmonAnalytics({Dio? dio, this.requestTimeout = const Duration(seconds: 3)})
    : _dio = dio ?? Dio() {
    // Analytics has its own adapter: no account Authorization headers, cookies
    // or API failover interceptors are shared with login/payment requests.
    if (dio == null) installSalmonDnsFallback(_dio);
  }

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    _preferences = await SharedPreferences.getInstance();
    enabled.value = _preferences!.getBool(_enabledKey) ?? true;
  }

  void configure(SalmonAnalyticsConfig? config) {
    if (_config?.endpoint == config?.endpoint &&
        _config?.siteId == config?.siteId) {
      return;
    }
    _cancelPending();
    _config = config;
    _started = false;
    _lastScreen = null;
    if (config != null && _currentScreen != null) {
      unawaited(trackScreen(_currentScreen!));
    }
  }

  Future<void> setEnabled(bool value) async {
    await initialize();
    enabled.value = value;
    if (!value) {
      _cancelPending();
      _visitorId = null;
      await _visitorInitialization;
      _started = false;
      _lastScreen = null;
      await _preferences!.remove(_visitorKey);
    }
    await _preferences!.setBool(_enabledKey, value);
  }

  Future<String> _getVisitorId() async {
    final cached = _visitorId;
    if (cached != null) return cached;
    final inFlight = _visitorInitialization;
    if (inFlight != null) return inFlight;
    final future = _createVisitorId();
    _visitorInitialization = future;
    try {
      return await future;
    } finally {
      if (identical(_visitorInitialization, future)) {
        _visitorInitialization = null;
      }
    }
  }

  Future<String> _createVisitorId() async {
    var visitorId = _preferences!.getString(_visitorKey);
    if (visitorId == null || !RegExp(r'^[0-9a-f]{16}$').hasMatch(visitorId)) {
      visitorId = List.generate(
        8,
        (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await _preferences!.setString(_visitorKey, visitorId);
    }
    if (enabled.value) _visitorId = visitorId;
    return visitorId;
  }

  void _cancelPending() {
    for (final token in _pending) {
      token.cancel('Analytics configuration changed');
    }
    _pending.clear();
  }

  Future<void> trackScreen(SalmonAnalyticsScreen screen) async {
    _currentScreen = screen;
    try {
      await initialize();
      final config = _config;
      if (config == null || !enabled.value || _pending.length >= 3) return;
      if (_lastScreen == screen) return;
      final visitorId = await _getVisitorId();
      if (!enabled.value ||
          !identical(config, _config) ||
          _lastScreen == screen ||
          _pending.length >= 3) {
        return;
      }
      final first = !_started;
      _started = true;
      _lastScreen = screen;
      final token = CancelToken();
      _pending.add(token);
      try {
        await _dio
            .post<void>(
              config.endpoint.toString(),
              cancelToken: token,
              data: {
                'idsite': config.siteId,
                'rec': 1,
                'apiv': 1,
                '_id': visitorId,
                'rand': _random.nextInt(1 << 30),
                'send_image': 0,
                // Fixed synthetic URLs: never upload the API/subscription/payment
                // URL, node, account identifier, credential or browsing traffic.
                'url':
                    'https://salmon.app/${defaultTargetPlatform.name}/${screen.name}',
                'action_name': '客户端 / ${screen.title}',
                if (first) 'new_visit': 1,
              },
              options: Options(
                contentType: Headers.formUrlEncodedContentType,
                followRedirects: false,
                connectTimeout: requestTimeout,
                sendTimeout: requestTimeout,
                receiveTimeout: requestTimeout,
              ),
            )
            .timeout(
              requestTimeout,
              onTimeout: () {
                token.cancel('Analytics deadline exceeded');
                throw TimeoutException('Analytics deadline exceeded');
              },
            );
      } finally {
        _pending.remove(token);
      }
    } catch (_) {
      // Best effort only. Never delay or surface errors in the app workflow.
    }
  }
}

final salmonAnalytics = SalmonAnalytics();
