import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/services/salmon_analytics.dart';
import 'package:flutter/material.dart';

class SalmonAnalyticsSetting extends StatefulWidget {
  final SalmonAnalytics? analytics;

  const SalmonAnalyticsSetting({super.key, this.analytics});

  @override
  State<SalmonAnalyticsSetting> createState() => _SalmonAnalyticsSettingState();
}

class _SalmonAnalyticsSettingState extends State<SalmonAnalyticsSetting> {
  bool _loading = true;

  SalmonAnalytics get _analytics => widget.analytics ?? salmonAnalytics;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await _analytics.initialize();
    } catch (_) {
      return;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setEnabled(bool enabled) async {
    setState(() => _loading = true);
    try {
      await _analytics.setEnabled(enabled);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.appLocalizations.salmonAnalyticsSaveFailed),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _analytics.enabled,
      builder: (_, enabled, _) => SwitchListTile.adaptive(
        secondary: const Icon(Icons.insights_rounded),
        title: Text(context.appLocalizations.salmonAnalyticsTitle),
        subtitle: Text(context.appLocalizations.salmonAnalyticsDescription),
        value: enabled,
        onChanged: _loading ? null : _setEnabled,
      ),
    );
  }
}
