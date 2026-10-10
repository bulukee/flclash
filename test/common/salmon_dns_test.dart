import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/services/salmon_dns.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  test('uses system DNS first without querying DoH', () async {
    final resolver = SalmonDnsResolver(
      systemLookup: (_) async => [InternetAddress('192.0.2.1')],
      encryptedLookup: (_) async => throw StateError('Unexpected DoH lookup'),
    );
    expect((await resolver.resolve('example.com')).single.address, '192.0.2.1');
  });

  test('falls back to DoH on system DNS failure', () async {
    final resolver = SalmonDnsResolver(
      systemLookup: (_) async => throw const SocketException('DNS failed'),
      encryptedLookup: (_) async => [InternetAddress('192.0.2.2')],
    );
    expect((await resolver.resolve('example.com')).single.address, '192.0.2.2');
  });

  test('falls back on an empty system answer', () async {
    final resolver = SalmonDnsResolver(
      systemLookup: (_) async => [],
      encryptedLookup: (_) async => [InternetAddress('192.0.2.3')],
    );
    expect((await resolver.resolve('example.com')).single.address, '192.0.2.3');
  });

  test('IP literals never trigger DNS', () async {
    final resolver = SalmonDnsResolver(
      systemLookup: (_) async => throw StateError('Unexpected system lookup'),
      encryptedLookup: (_) async => throw StateError('Unexpected DoH lookup'),
    );
    expect((await resolver.resolve('127.0.0.1')).single.address, '127.0.0.1');
    expect((await resolver.resolve('::1')).single.address, '::1');
  });

  test('reports failure if all DNS sources fail', () async {
    final resolver = SalmonDnsResolver(
      systemLookup: (_) async => [],
      encryptedLookup: (_) async => [],
    );
    await expectLater(
      resolver.resolve('example.com'),
      throwsA(isA<SocketException>()),
    );
  });

  Uint8List answer() {
    final query = buildSalmonDnsQuery('example.com', 123);
    query[2] = 0x81;
    query[3] = 0x80;
    query[7] = 1;
    return Uint8List.fromList([
      ...query,
      0xc0,
      0x0c,
      0,
      1,
      0,
      1,
      0,
      0,
      0,
      60,
      0,
      4,
      192,
      0,
      2,
      4,
    ]);
  }

  test('parses a compressed DNS A record', () {
    expect(parseSalmonDnsAnswer(answer(), 123).single.address, '192.0.2.4');
  });

  test('rejects mismatched IDs and truncated DNS packets', () {
    expect(() => parseSalmonDnsAnswer(answer(), 124), throwsFormatException);
    final packet = answer();
    expect(
      () => parseSalmonDnsAnswer(
        Uint8List.sublistView(packet, 0, packet.length - 1),
        123,
      ),
      throwsFormatException,
    );
    expect(
      () => parseSalmonDnsAnswer(Uint8List(3), 123),
      throwsFormatException,
    );
  });

  test('rejects DNS errors and invalid names', () {
    final packet = answer();
    packet[3] = 0x83;
    expect(() => parseSalmonDnsAnswer(packet, 123), throwsFormatException);
    expect(
      () => buildSalmonDnsQuery('example..com', 123),
      throwsFormatException,
    );
    expect(
      () => buildSalmonDnsQuery('${List.filled(64, 'a').join()}.com', 123),
      throwsFormatException,
    );
  });

  test('connects to the resolved IP while keeping the original Host', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final resolver = SalmonDnsResolver(
      systemLookup: (_) async => [InternetAddress.loopbackIPv4],
    );
    final client = HttpOverrides.runWithHttpOverrides(
      () => createSalmonHttpClient(resolver),
      _RealHttpOverrides(),
    );
    client.findProxy = (_) => 'DIRECT';
    final served = Completer<String?>();
    final subscription = server.listen(
      (request) async {
        final host = request.headers.value(HttpHeaders.hostHeader);
        request.response.write('ok');
        try {
          await request.response.close();
          if (!served.isCompleted) served.complete(host);
        } catch (error, stackTrace) {
          if (!served.isCompleted) served.completeError(error, stackTrace);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!served.isCompleted) served.completeError(error, stackTrace);
      },
    );
    addTearDown(() async {
      client.close(force: true);
      await subscription.cancel();
      await server.close(force: true);
    });
    final request = await client.getUrl(
      Uri.parse('http://test.example:${server.port}/'),
    );
    final response = await request.close().timeout(const Duration(seconds: 5));
    expect(response.statusCode, HttpStatus.ok);
    await response.drain<void>();
    expect(
      await served.future.timeout(const Duration(seconds: 5)),
      'test.example:${server.port}',
    );
  });

  test(
    'rejects an untrusted HTTPS certificate after custom resolution',
    () async {
      final context = SecurityContext()
        ..useCertificateChainBytes(
          utf8.encode(
            File('test/fixtures/salmon_dns/test-cert.pem').readAsStringSync(),
          ),
        )
        ..usePrivateKeyBytes(
          utf8.encode(
            File('test/fixtures/salmon_dns/test-key.pem').readAsStringSync(),
          ),
        );
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      var receivedRequest = false;
      final errors = <Object>[];
      final subscription = server.listen((request) async {
        receivedRequest = true;
        await request.response.close();
      }, onError: errors.add);
      final client = HttpOverrides.runWithHttpOverrides(
        () => createSalmonHttpClient(
          SalmonDnsResolver(
            systemLookup: (_) async => [InternetAddress.loopbackIPv4],
          ),
        ),
        _RealHttpOverrides(),
      );
      client.findProxy = (_) => 'DIRECT';
      addTearDown(() async {
        client.close(force: true);
        await subscription.cancel();
        await server.close(force: true);
      });
      await expectLater(
        client
            .getUrl(Uri.parse('https://test.example:${server.port}/'))
            .timeout(const Duration(seconds: 5)),
        throwsA(isA<HandshakeException>()),
      );
      expect(receivedRequest, isFalse);
    },
  );
}
