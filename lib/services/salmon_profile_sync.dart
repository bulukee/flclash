import 'dart:async';

import 'package:fl_clash/common/app_localizations.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/services/salmon_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> _syncTail = Future<void>.value();

Future<void> _serializeSync(Future<void> Function() action) {
  final previous = _syncTail;
  final release = Completer<void>();
  _syncTail = release.future;
  return () async {
    await previous;
    try {
      await action();
    } finally {
      release.complete();
    }
  }();
}

Future<void> refreshSalmonProfile(WidgetRef ref) {
  final generation = salmonService.sessionGeneration;
  return _serializeSync(() => _refreshProfile(ref, generation));
}

void _checkSession(WidgetRef ref, int generation) {
  if (!ref.context.mounted || generation != salmonService.sessionGeneration) {
    throw SalmonSessionExpiredException();
  }
}

Future<void> _refreshProfile(WidgetRef ref, int generation) async {
  _checkSession(ref, generation);
  final subscription = await salmonService.fetchSubscribeInfo(
    forceRefresh: true,
  );
  _checkSession(ref, generation);
  final rawUrl = subscription['subscribe_url']?.toString().trim() ?? '';
  if (rawUrl.isEmpty) {
    throw StateError(currentAppLocalizations.salmonSubscriptionMissing);
  }
  final baseUrl = await salmonService.savedBaseUrl();
  final uri = Uri.parse(rawUrl);
  final url = uri.hasScheme
      ? rawUrl
      : baseUrl == null
      ? throw SalmonSessionExpiredException()
      : Uri.parse(baseUrl).resolve(rawUrl).toString();
  await _syncProfile(ref, url, generation);
}

/// Replaces the single managed Salmon profile with the subscription returned
/// for the currently authenticated V2Board account.
Future<void> syncSalmonProfile(
  WidgetRef ref,
  String subscribeUrl, {
  int? expectedGeneration,
}) {
  final generation = expectedGeneration ?? salmonService.sessionGeneration;
  return _serializeSync(() => _syncProfile(ref, subscribeUrl, generation));
}

Future<void> _syncProfile(
  WidgetRef ref,
  String subscribeUrl,
  int generation,
) async {
  _checkSession(ref, generation);
  if (subscribeUrl.trim().isEmpty) return;
  await ref.read(profilesStreamProvider.future);
  _checkSession(ref, generation);
  Profile? existing;
  for (final profile in ref.read(profilesProvider)) {
    if (profile.label == salmonProfileLabel) {
      existing = profile;
      break;
    }
  }

  final profile =
      existing?.copyWith(
        label: salmonProfileLabel,
        url: subscribeUrl,
        autoUpdate: true,
        selectedMap: existing.url == subscribeUrl ? existing.selectedMap : {},
        currentGroupName: existing.url == subscribeUrl
            ? existing.currentGroupName
            : null,
      ) ??
      Profile.normal(label: salmonProfileLabel, url: subscribeUrl);
  final updated = await profile.update(
    shouldContinue: () =>
        ref.context.mounted && generation == salmonService.sessionGeneration,
  );
  _checkSession(ref, generation);
  await ref.read(profilesProvider.notifier).putAndWait(updated);
  _checkSession(ref, generation);
  ref.read(currentProfileIdProvider.notifier).value = updated.id;
  await ref
      .read(setupActionProvider.notifier)
      .applyProfile(force: true, silence: true, throwOnError: true);
}
