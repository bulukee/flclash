import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

typedef SalmonDnsLookup = Future<List<InternetAddress>> Function(String host);

class SalmonDnsResolver {
  final SalmonDnsLookup systemLookup;
  final SalmonDnsLookup encryptedLookup;

  SalmonDnsResolver({
    SalmonDnsLookup? systemLookup,
    SalmonDnsLookup? encryptedLookup,
  }) : systemLookup = systemLookup ?? InternetAddress.lookup,
       encryptedLookup = encryptedLookup ?? lookupSalmonDoh;

  Future<List<InternetAddress>> resolve(String host) async {
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return [literal];
    try {
      final addresses = await systemLookup(
        host,
      ).timeout(const Duration(seconds: 2));
      if (addresses.isNotEmpty) return addresses;
    } on SocketException {
      return _resolveEncrypted(host);
    } on TimeoutException {
      return _resolveEncrypted(host);
    }
    return _resolveEncrypted(host);
  }

  Future<List<InternetAddress>> _resolveEncrypted(String host) async {
    final addresses = await encryptedLookup(host);
    if (addresses.isEmpty) {
      throw const SocketException('DNS returned no addresses');
    }
    return addresses;
  }
}

void installSalmonDnsFallback(Dio dio) {
  final resolver = SalmonDnsResolver();
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () => createSalmonHttpClient(resolver),
  );
}

HttpClient createSalmonHttpClient(SalmonDnsResolver resolver) {
  final client = HttpClient();
  client.badCertificateCallback = null;
  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    if (proxyHost != null) return Socket.startConnect(proxyHost, proxyPort!);
    var cancelled = false;
    Socket? connected;
    Future<Socket> connect() async {
      final addresses = await resolver.resolve(uri.host);
      Object? lastError;
      for (final address in addresses) {
        if (cancelled) throw const SocketException('Connection cancelled');
        try {
          var socket = await Socket.connect(
            address,
            uri.port,
            timeout: const Duration(seconds: 4),
          );
          connected = socket;
          if (uri.scheme == 'https') {
            try {
              socket = await SecureSocket.secure(socket, host: uri.host);
              connected = socket;
            } catch (_) {
              socket.destroy();
              rethrow;
            }
          }
          if (cancelled) {
            socket.destroy();
            throw const SocketException('Connection cancelled');
          }
          connected = socket;
          return socket;
        } on SocketException catch (error) {
          lastError = error;
        }
      }
      throw lastError ?? const SocketException('Connection failed');
    }

    return ConnectionTask.fromSocket(connect(), () {
      cancelled = true;
      connected?.destroy();
    });
  };
  return client;
}

Uint8List buildSalmonDnsQuery(String host, int id) {
  final bytes = BytesBuilder()
    ..add([id >> 8, id & 255, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
  for (final label in host.split('.')) {
    final encoded = ascii.encode(label);
    if (encoded.isEmpty || encoded.length > 63) {
      throw const FormatException('Invalid DNS name');
    }
    bytes.add([encoded.length]);
    bytes.add(encoded);
  }
  bytes.add([0, 0, 1, 0, 1]);
  final query = bytes.toBytes();
  if (query.length > 271) throw const FormatException('DNS name too long');
  return query;
}

List<InternetAddress> parseSalmonDnsAnswer(Uint8List bytes, int id) {
  final data = ByteData.sublistView(bytes);
  int read16(int offset) => data.getUint16(offset);
  if (bytes.length < 12 ||
      read16(0) != id ||
      (read16(2) & 0x820f) != 0x8000 ||
      read16(4) != 1) {
    throw const FormatException('Invalid DNS response');
  }
  int skipName(int offset) {
    while (offset < bytes.length) {
      final length = bytes[offset++];
      if (length == 0) return offset;
      if ((length & 0xc0) == 0xc0) {
        if (offset >= bytes.length ||
            (((length & 0x3f) << 8) | bytes[offset]) >= bytes.length) {
          throw const FormatException('Invalid DNS pointer');
        }
        return offset + 1;
      }
      if (length > 63 || offset + length > bytes.length) {
        throw const FormatException('Invalid DNS label');
      }
      offset += length;
    }
    throw const FormatException('Truncated DNS name');
  }

  var offset = skipName(12);
  if (offset + 4 > bytes.length ||
      read16(offset) != 1 ||
      read16(offset + 2) != 1) {
    throw const FormatException('Invalid DNS question');
  }
  offset += 4;
  final addresses = <InternetAddress>[];
  for (var index = 0; index < read16(6); index++) {
    offset = skipName(offset);
    if (offset + 10 > bytes.length) {
      throw const FormatException('Truncated DNS record');
    }
    final type = read16(offset);
    final recordClass = read16(offset + 2);
    final length = read16(offset + 8);
    offset += 10;
    if (offset + length > bytes.length) {
      throw const FormatException('Truncated DNS address');
    }
    if (type == 1 && recordClass == 1 && length == 4) {
      addresses.add(
        InternetAddress.fromRawAddress(
          Uint8List.sublistView(bytes, offset, offset + 4),
        ),
      );
    }
    offset += length;
  }
  return addresses;
}

Future<List<InternetAddress>> lookupSalmonDoh(String host) async {
  final id = Random.secure().nextInt(65536);
  final query = buildSalmonDnsQuery(host, id);
  final providers = {
    'https://doh.pub/dns-query': '1.12.12.12',
    'https://dns.alidns.com/dns-query': '223.5.5.5',
  };
  for (final provider in providers.entries) {
    final client = createSalmonHttpClient(
      SalmonDnsResolver(
        systemLookup: (_) async => [InternetAddress(provider.value)],
      ),
    );
    client.findProxy = (_) => 'DIRECT';
    client.connectionTimeout = const Duration(seconds: 2);
    try {
      final addresses = await (() async {
        final uri = Uri.parse(provider.key).replace(
          queryParameters: {'dns': base64Url.encode(query).replaceAll('=', '')},
        );
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/dns-message',
        );
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw const HttpException('DoH request failed');
        }
        final bytes = BytesBuilder();
        await for (final chunk in response) {
          bytes.add(chunk);
          if (bytes.length > 65535) {
            throw const FormatException('DNS response too large');
          }
        }
        return parseSalmonDnsAnswer(bytes.toBytes(), id);
      })().timeout(const Duration(seconds: 3));
      if (addresses.isNotEmpty) return addresses;
    } on Exception {
      continue;
    } finally {
      client.close(force: true);
    }
  }
  throw const SocketException('System DNS and encrypted DNS failed');
}
