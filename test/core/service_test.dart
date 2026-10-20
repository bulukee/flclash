import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/core/service.dart';
import 'package:fl_clash/core/transport.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport extends IPCCoreTransport {
  _Transport() : super(address: 'test');

  final frames = StreamController<Uint8List>();
  final connection = Completer<void>()..complete();
  final messages = <Map<String, dynamic>>[];
  bool failSend = false;

  @override
  Completer<void> get connectionCompleter => connection;

  @override
  Stream<Uint8List> get dataStream => frames.stream;

  @override
  Future<void> init() async {}

  @override
  Future<void> send(String message) async {
    if (failSend) throw StateError('IPC send failed');
    messages.add(jsonDecode(message) as Map<String, dynamic>);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Transport transport;
  late CoreService service;

  setUp(() async {
    transport = _Transport();
    service = CoreService.test(transport);
    await Future<void>.delayed(Duration.zero);
    addTearDown(transport.frames.close);
  });

  test('an IPC send failure completes the request immediately', () async {
    transport.failSend = true;
    await expectLater(
      service.invoke<bool>(method: ActionMethod.getIsInit),
      throwsStateError,
    );
  });

  test('disconnect releases every outstanding request', () async {
    final first = service.invoke<bool>(method: ActionMethod.getIsInit);
    final second = service.invoke<bool>(method: ActionMethod.getIsInit);
    transport.onDisconnect!();
    expect(await first, isNull);
    expect(await second, isNull);
  });

  test('late replies after timeout do not affect the next request', () async {
    expect(
      await service.invoke<bool>(
        method: ActionMethod.getIsInit,
        timeout: const Duration(milliseconds: 10),
      ),
      isNull,
    );
    final expiredId = transport.messages.single['id'] as String;
    final next = service.invoke<bool>(method: ActionMethod.getIsInit);
    await service.handleResult(
      ActionResult(id: expiredId, method: ActionMethod.getIsInit, data: false),
    );
    await service.handleResult(
      ActionResult(
        id: transport.messages.last['id'] as String,
        method: ActionMethod.getIsInit,
        data: true,
      ),
    );
    expect(await next, isTrue);
  });

  test('preloading an already connected core does not restart it', () async {
    expect(await service.preload(), isEmpty);
    expect(await service.preload(), isEmpty);
  });
}
