import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/core.dart';
import 'package:flutter/foundation.dart';

import 'interface.dart';
import 'transport.dart';

class CoreService extends CoreHandlerInterface {
  static CoreService? _instance;

  late final IPCCoreTransport _transport;
  late final Future<void> _serverReady;
  Future<void>? _startFuture;

  Completer<bool> _shutdownCompleter = Completer();

  final Map<String, Completer> _callbackCompleterMap = {};

  Process? _process;

  factory CoreService() {
    _instance ??= CoreService._internal();
    return _instance!;
  }

  CoreService._internal() {
    _transport = IPCCoreTransport(
      address: system.isWindows ? windowsPipeName : unixSocketPath,
    );
    _serverReady = _initServer();
    // Keep initialization failures observable by start without an unhandled
    // asynchronous error before the first connection attempt.
    unawaited(_serverReady.catchError((Object _) {}));
  }

  @visibleForTesting
  CoreService.test(this._transport) {
    _serverReady = _initServer();
    unawaited(_serverReady.catchError((Object _) {}));
  }

  Future<void> handleResult(ActionResult result) async {
    final completer = _callbackCompleterMap[result.id];
    dynamic data;
    try {
      data = await parasResult(result);
    } catch (error, stack) {
      if (completer != null && !completer.isCompleted) {
        completer.completeError(error, stack);
      }
      return;
    }
    if (result.id?.isEmpty == true) {
      coreEventManager.sendEvent(CoreEvent.fromJson(result.data));
    }
    if (completer?.isCompleted == true) {
      return;
    }
    completer?.complete(data);
  }

  Future<void> _initServer() async {
    await _transport.init();

    _transport.onDisconnect = () {
      _clearCompleter();
      _handleInvokeCrashEvent();
      if (!_shutdownCompleter.isCompleted) {
        _shutdownCompleter.complete(true);
      }
    };

    _transport.dataStream
        .transform(uint8ListToListIntConverter)
        .transform(utf8.decoder)
        .listen(
          (data) async {
            try {
              final dataJson = await data.trim().commonToJSON<dynamic>();
              await handleResult(ActionResult.fromJson(dataJson));
            } catch (e) {
              commonPrint.log(
                'Failed to parse transport data: $e',
                logLevel: LogLevel.error,
              );
            }
          },
          onError: (error) {
            commonPrint.log(
              'Transport data stream error: $error',
              logLevel: LogLevel.error,
            );
          },
        );
  }

  void _handleInvokeCrashEvent() {
    coreEventManager.sendEvent(
      const CoreEvent(type: CoreEventType.crash, data: 'core done'),
    );
  }

  Future<void> start() async {
    final inFlight = _startFuture;
    if (inFlight != null) return inFlight;
    final future = _start();
    _startFuture = future;
    try {
      await future;
    } finally {
      if (identical(_startFuture, future)) _startFuture = null;
    }
  }

  Future<void> _start() async {
    await _serverReady.timeout(const Duration(seconds: 10));
    if (_transport.connectionCompleter.isCompleted) return;
    if (_process != null) {
      await shutdown(false);
    }
    if (system.isWindows && await system.checkIsAdmin()) {
      final isSuccess = await request.startCoreByHelper(_transport.address);
      if (isSuccess) {
        await _transport.connectionCompleter.future.timeout(
          const Duration(seconds: 15),
        );
        return;
      }
    }
    try {
      _process = await Process.start(appPath.corePath, [_transport.address]);
    } catch (e) {
      commonPrint.log(
        'Failed to start core process: $e',
        logLevel: LogLevel.error,
      );
      rethrow;
    }
    _process?.stdout.listen((_) {});
    _process?.stderr.listen((e) {
      final error = utf8.decode(e);
      if (error.isNotEmpty) {
        commonPrint.log(error, logLevel: LogLevel.warning);
      }
    });
    final process = _process!;
    try {
      await Future.any<void>([
        _transport.connectionCompleter.future,
        process.exitCode.then<void>((code) {
          throw StateError('Core exited before connecting: $code');
        }),
      ]).timeout(const Duration(seconds: 15));
    } catch (_) {
      process.kill();
      if (identical(_process, process)) _process = null;
      rethrow;
    }
  }

  @override
  FutureOr<bool> destroy() async {
    await shutdown(false);
    await _transport.close();
    return true;
  }

  Future<void> sendMessage(String message) async {
    if (!_transport.connectionCompleter.isCompleted) {
      throw StateError('Core is disconnected');
    }
    await _transport.send(message);
  }

  @override
  Future<bool> shutdown(bool isUser) async {
    _shutdownCompleter = Completer();
    if (system.isWindows) {
      await request.stopCoreByHelper();
    }
    _transport.disconnected();
    _process?.kill();
    _process = null;
    _clearCompleter();
    if (isUser) {
      return _shutdownCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
    } else {
      return true;
    }
  }

  void _clearCompleter() {
    for (final completer in _callbackCompleterMap.values) {
      completer.safeCompleter(null);
    }
    _callbackCompleterMap.clear();
  }

  @override
  Future<String> preload() async {
    await start();
    return '';
  }

  @override
  Future<T?> invoke<T>({
    required ActionMethod method,
    dynamic data,
    Duration? timeout,
  }) async {
    final id = '${method.name}#${utils.id}';
    final callback = Completer<T?>();
    _callbackCompleterMap[id] = callback;
    try {
      unawaited(
        sendMessage(
          json.encode(Action(id: id, method: method, data: data)),
        ).catchError((Object error, StackTrace stack) {
          if (!callback.isCompleted) callback.completeError(error, stack);
        }),
      );
      return await callback.future.timeout(
        timeout ?? const Duration(minutes: 3),
        onTimeout: () => null,
      );
    } finally {
      callback.safeCompleter(null);
      _callbackCompleterMap.remove(id);
    }
  }

  @override
  Completer get completer => _transport.connectionCompleter;
}

final coreService = system.isDesktop ? CoreService() : null;
