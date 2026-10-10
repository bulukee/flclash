import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/services/salmon_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> refreshSalmonProfile(WidgetRef ref) async {
  final subscription = await salmonService.fetchSubscribeInfo(
    forceRefresh: true,
  );
  final rawUrl = subscription['subscribe_url']?.toString().trim() ?? '';
  if (rawUrl.isEmpty) {
    throw StateError('服务器未返回订阅地址，请检查账号订阅状态');
  }
  final baseUrl = await salmonService.savedBaseUrl();
  final uri = Uri.parse(rawUrl);
  final url = uri.hasScheme
      ? rawUrl
      : baseUrl == null
      ? throw StateError('登录状态无效，请重新登录')
      : Uri.parse(baseUrl).resolve(rawUrl).toString();
  await syncSalmonProfile(ref, url);
}

/// Replaces the single managed Salmon profile with the subscription returned
/// for the currently authenticated V2Board account.
Future<void> syncSalmonProfile(WidgetRef ref, String subscribeUrl) async {
  if (subscribeUrl.trim().isEmpty) return;
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
      ) ??
      Profile.normal(label: salmonProfileLabel, url: subscribeUrl);
  final updated = await profile.update();
  ref.read(profilesActionProvider.notifier).putProfile(updated);
  ref.read(currentProfileIdProvider.notifier).value = updated.id;
  ref
      .read(setupActionProvider.notifier)
      .applyProfileDebounce(force: true, silence: true);
}
