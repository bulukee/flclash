import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/services/salmon_service.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SalmonAppUpdate {
  final String version;
  final int versionCode;
  final String url;
  final String sha256Value;
  final bool force;
  final List<String> notes;

  const SalmonAppUpdate({
    required this.version,
    required this.versionCode,
    required this.url,
    required this.sha256Value,
    required this.force,
    required this.notes,
  });

  factory SalmonAppUpdate.fromJson(Map<String, dynamic> json) {
    var url = (json['url'] ?? '').toString().trim();
    final encoded = (json['urlBase64'] ?? '').toString().trim();
    if (url.isEmpty && encoded.isNotEmpty)
      url = utf8.decode(base64Decode(base64.normalize(encoded)));
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty)
      throw const FormatException('更新下载地址必须是 HTTPS');
    final rawNotes = json['notes'];
    return SalmonAppUpdate(
      // versionName is the public field used by the remote OSS config.
      // Prefer it when both legacy `version` and `versionName` exist.
      version: (json['versionName'] ?? json['version'] ?? '').toString().trim(),
      versionCode: int.tryParse('${json['versionCode'] ?? 0}') ?? 0,
      url: url,
      sha256Value: (json['sha256'] ?? '').toString().trim().toLowerCase(),
      force: json['force'] == true,
      notes: rawNotes is List
          ? rawNotes.map((item) => item.toString()).toList()
          : [rawNotes?.toString() ?? '性能与稳定性优化'],
    );
  }
}

class SalmonUpdateService {
  SalmonUpdateService._();
  static bool _checking = false;
  static bool _dialogVisible = false;
  static const _lastPromptedUpdateKey = 'salmon_last_prompted_update';
  static const _updateAvailableKey = 'salmon_update_available';
  static final ValueNotifier<bool> updateAvailable = ValueNotifier<bool>(false);
  static Future<void>? _availabilityRestore;
  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 8),
      headers: const {'Cache-Control': 'no-cache'},
    ),
  );

  static int _compareVersion(String remote, String current) {
    final remoteParts = remote
        .split(RegExp(r'[^0-9]+'))
        .where((part) => part.isNotEmpty)
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
    final currentParts = current
        .split(RegExp(r'[^0-9]+'))
        .where((part) => part.isNotEmpty)
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
    final length = remoteParts.length > currentParts.length
        ? remoteParts.length
        : currentParts.length;
    for (var index = 0; index < length; index++) {
      final remotePart = index < remoteParts.length ? remoteParts[index] : 0;
      final currentPart = index < currentParts.length ? currentParts[index] : 0;
      if (remotePart != currentPart) return remotePart.compareTo(currentPart);
    }
    return 0;
  }

  static Future<SalmonAppUpdate?> check() async {
    await (_availabilityRestore ??= _restoreAvailability());
    Object? lastError;
    SalmonAppUpdate? newestUpdate;
    final info = await PackageInfo.fromPlatform();
    final currentCode = int.tryParse(info.buildNumber) ?? 0;
    for (final configUrl in salmonConfigUrls) {
      try {
        final response = await _dio.get<String>(
          configUrl,
          queryParameters: {'_': DateTime.now().millisecondsSinceEpoch},
          options: Options(responseType: ResponseType.plain),
        );
        final root = decodeSalmonConfigSource(response.data ?? '');
        if (root['updates'] is! Map) {
          continue;
        }
        final updates = root['updates'] as Map;
        final key = Platform.isAndroid
            ? 'android'
            : Platform.isWindows
            ? 'windows'
            : Platform.isMacOS
            ? 'macos'
            : '';
        if (key.isEmpty || updates[key] is! Map) continue;
        final updateJson = Map<String, dynamic>.from(updates[key] as Map);
        if (Platform.isAndroid) {
          const buildAbi = String.fromEnvironment(
            'SALMON_ABI',
            defaultValue: 'arm64-v8a',
          );
          if (buildAbi.contains('x86')) {
            updateJson['url'] ??= updateJson['x64Url'];
            updateJson['urlBase64'] ??= updateJson['x64UrlBase64'];
          } else {
            updateJson['url'] ??= updateJson['arm64Url'];
            updateJson['urlBase64'] ??= updateJson['arm64UrlBase64'];
          }
        }
        updateJson['notes'] ??= root['releaseNotes'];
        final update = SalmonAppUpdate.fromJson(updateJson);
        final buildIsNewer = update.versionCode > currentCode;
        final nameIsNewer = _compareVersion(update.version, info.version) > 0;
        if (!buildIsNewer && !nameIsNewer) continue;

        // Never stop at the first valid source: the first endpoint can still
        // be cached while a backup endpoint already publishes a newer build.
        if (newestUpdate == null ||
            _compareVersion(update.version, newestUpdate.version) > 0 ||
            (_compareVersion(update.version, newestUpdate.version) == 0 &&
                update.versionCode > newestUpdate.versionCode)) {
          newestUpdate = update;
        }
      } catch (error) {
        lastError = error;
      }
    }
    // A backup source may fail even when another source returned a valid
    // response. Only report an error when no source produced a usable result.
    if (newestUpdate == null && lastError != null) throw lastError;
    updateAvailable.value = newestUpdate != null;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_updateAvailableKey, updateAvailable.value);
    if (newestUpdate != null) return newestUpdate;
    return null;
  }

  static Future<void> _restoreAvailability() async {
    final preferences = await SharedPreferences.getInstance();
    updateAvailable.value = preferences.getBool(_updateAvailableKey) ?? false;
  }

  static Future<void> checkAndPrompt(
    BuildContext context, {
    bool manual = false,
  }) async {
    final supported = Platform.isAndroid || Platform.isWindows;
    if (!supported) {
      if (manual && context.mounted) context.showNotifier('当前平台暂不支持客户端内更新');
      return;
    }
    if (_checking || _dialogVisible) return;
    _checking = true;
    try {
      final update = await check();
      if (!context.mounted) return;
      if (update == null) {
        if (manual)
          context.showNotifier(context.appLocalizations.checkUpdateError);
        return;
      }
      if (!manual) {
        final preferences = await SharedPreferences.getInstance();
        final updateKey = '${update.version}:${update.versionCode}';
        if (preferences.getString(_lastPromptedUpdateKey) == updateKey) return;
        await preferences.setString(_lastPromptedUpdateKey, updateKey);
        if (!context.mounted) return;
      }
      _dialogVisible = true;
      await showDialog<void>(
        context: context,
        barrierDismissible: !update.force,
        builder: (_) => PopScope(
          canPop: !update.force,
          child: _UpdateDialog(update: update, autoInstall: manual),
        ),
      );
    } catch (_) {
      if (manual && context.mounted) context.showNotifier('检查客户端更新失败，请检查网络后重试');
    } finally {
      _checking = false;
      _dialogVisible = false;
    }
  }

  static Future<String> download(
    SalmonAppUpdate update,
    ValueChanged<double> onProgress,
  ) async {
    final cache = await getTemporaryDirectory();
    final extension = Platform.isWindows ? 'exe' : 'apk';
    final file = File(
      '${cache.path}${Platform.pathSeparator}salmon-update.$extension',
    );
    if (await file.exists()) await file.delete();
    await _dio.download(
      update.url,
      file.path,
      deleteOnError: true,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress(received / total);
      },
    );
    if (update.sha256Value.isNotEmpty) {
      final digest = sha256.convert(await file.readAsBytes()).toString();
      if (digest != update.sha256Value) {
        await file.delete();
        throw const FormatException('安装包校验失败，请重新下载');
      }
    }
    return file.path;
  }

  static Future<bool> launchInstaller(String path) async {
    if (Platform.isAndroid) return App().installApk(path);
    if (Platform.isWindows) {
      await Process.start(path, const [], runInShell: true);
      return true;
    }
    return false;
  }
}

class _UpdateDialog extends StatefulWidget {
  final SalmonAppUpdate update;
  final bool autoInstall;
  const _UpdateDialog({required this.update, this.autoInstall = false});
  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.autoInstall) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _install();
      });
    }
  }

  Future<void> _install() async {
    if (_progress != null) return;
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      final path = await SalmonUpdateService.download(widget.update, (value) {
        if (mounted) setState(() => _progress = value);
      });
      if (!await SalmonUpdateService.launchInstaller(path)) {
        throw Exception('无法调起系统安装程序');
      }
    } catch (error) {
      if (mounted)
        setState(() {
          _progress = null;
          _error = error.toString().replaceFirst('Exception: ', '');
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final downloading = _progress != null;
    return AlertDialog(
      icon: Container(
        width: 64,
        height: 64,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [Color(0xFF00CFFF), Color(0xFF245CFF), Color(0xFF755BFF)],
          ),
        ),
        child: const Icon(Icons.rocket_launch_rounded, color: Colors.white),
      ),
      title: Text('发现新版本 ${widget.update.version}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final note in widget.update.notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('• $note'),
            ),
          if (downloading) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 8),
            Text('正在下载 ${((_progress ?? 0) * 100).toStringAsFixed(0)}%'),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        if (!widget.update.force && !downloading)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('稍后更新'),
          ),
        FilledButton.icon(
          onPressed: downloading ? null : _install,
          icon: const Icon(Icons.download_rounded),
          label: Text(downloading ? '下载中' : '立即更新'),
        ),
      ],
    );
  }
}
