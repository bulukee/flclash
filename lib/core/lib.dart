import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/core.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';

import 'interface.dart';

class CoreLib extends CoreHandlerInterface {
  static CoreLib? _instance;

  Completer<bool> _connectedCompleter = Completer();
  Future<String>? _preloadFuture;
  int _connectionGeneration = 0;

  CoreLib._internal();

  @override
  Future<String> preload() {
    if (_connectedCompleter.isCompleted) {
      return Future.value('');
    }
    final inFlight = _preloadFuture;
    if (inFlight != null) {
      return inFlight;
    }
    final generation = _connectionGeneration;
    final future = _preload(generation);
    _preloadFuture = future;
    future.then<void>(
      (_) {
        if (identical(_preloadFuture, future)) {
          _preloadFuture = null;
        }
      },
      onError: (Object _, StackTrace _) {
        if (identical(_preloadFuture, future)) {
          _preloadFuture = null;
        }
      },
    );
    return future;
  }

  Future<String> _preload(int generation) async {
    final res = await service?.init().timeout(const Duration(seconds: 15));
    if (generation != _connectionGeneration) {
      return 'service connection reset';
    }
    if (res?.isEmpty != true) {
      return res ?? '';
    }
    final syncRes = await service
        ?.syncState(globalState.container.read(sharedStateProvider))
        .timeout(const Duration(seconds: 15));
    if (generation != _connectionGeneration) {
      return 'service connection reset';
    }
    if (syncRes?.isEmpty == true && !_connectedCompleter.isCompleted) {
      _connectedCompleter.complete(true);
    }
    return syncRes ?? '';
  }

  factory CoreLib() {
    _instance ??= CoreLib._internal();
    return _instance!;
  }

  @override
  FutureOr<bool> destroy() async {
    return true;
  }

  @override
  Future<bool> shutdown(_) async {
    resetConnectionState();
    return service?.shutdown() ?? true;
  }

  /// Clears the Dart-side transport state after Android has rebound the
  /// background service. The Go core can be recreated without a user stop.
  void resetConnectionState() {
    _connectionGeneration++;
    _preloadFuture = null;
    _connectedCompleter = Completer();
  }

  @override
  Future<bool> startListener() async {
    await super.startListener();
    await service?.start();
    return true;
  }

  @override
  Future<bool> stopListener() async {
    await super.stopListener();
    await service?.stop();
    return true;
  }

  @override
  Future<T?> invoke<T>({
    required ActionMethod method,
    dynamic data,
    Duration? timeout,
  }) async {
    final id = '${method.name}#${utils.id}';
    final result = await service
        ?.invokeAction(Action(id: id, method: method, data: data))
        .withTimeout(timeout: timeout, onTimeout: () => null);
    if (result == null) {
      return null;
    }
    return parasResult<T>(result);
  }

  @override
  Completer get completer => _connectedCompleter;
}

CoreLib? get coreLib => system.isAndroid ? CoreLib() : null;
