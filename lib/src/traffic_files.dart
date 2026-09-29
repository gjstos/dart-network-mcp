import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

String sha256Hex(String value) => sha256.convert(utf8.encode(value)).toString();

class WrittenTraffic {
  const WrittenTraffic({
    required this.headersPath,
    required this.requestBodyPath,
    required this.responseBodyPath,
    required this.requestBodySize,
    required this.responseBodySize,
  });

  final String headersPath;
  final String? requestBodyPath;
  final String? responseBodyPath;
  final int requestBodySize;
  final int responseBodySize;
}

class HeaderMaps {
  const HeaderMaps({
    required this.requestHeaders,
    required this.responseHeaders,
  });

  final Map<String, String> requestHeaders;
  final Map<String, String> responseHeaders;
}

abstract interface class TrafficFileStore {
  WrittenTraffic write({
    required String vmUri,
    required String requestId,
    required int startTime,
    required Map<String, String> requestHeaders,
    required Map<String, String> responseHeaders,
    Uint8List? requestBody,
    Uint8List? responseBody,
  });

  Uint8List? readBytes(String path);
  HeaderMaps readHeaders(String path);
  void deleteSessionFiles(String vmUri);
  void deleteExportFiles(String vmUri);
  String sessionDirectory(String vmUri);
  String exportHash8(String vmUri);
}

class TrafficFiles implements TrafficFileStore {
  TrafficFiles(this.dataDirectory);

  final String dataDirectory;

  @override
  String sessionDirectory(String vmUri) =>
      p.join(dataDirectory, 'bodies', sha256Hex(vmUri));

  @override
  String exportHash8(String vmUri) =>
      sha1.convert(utf8.encode(vmUri)).toString().substring(0, 8);

  String _stem(String vmUri, String requestId, int startTime) => p.join(
        sessionDirectory(vmUri),
        '${startTime}_${sha256Hex(requestId)}',
      );

  @override
  WrittenTraffic write({
    required String vmUri,
    required String requestId,
    required int startTime,
    required Map<String, String> requestHeaders,
    required Map<String, String> responseHeaders,
    Uint8List? requestBody,
    Uint8List? responseBody,
  }) {
    final dir = Directory(sessionDirectory(vmUri));
    dir.createSync(recursive: true);
    final stem = _stem(vmUri, requestId, startTime);
    final headersPath = '$stem.headers.json';
    File(headersPath).writeAsStringSync(
      jsonEncode({
        'requestHeaders': requestHeaders,
        'responseHeaders': responseHeaders,
      }),
    );
    String? requestBodyPath;
    String? responseBodyPath;
    if (requestBody != null) {
      requestBodyPath = '$stem.request.body';
      File(requestBodyPath).writeAsBytesSync(requestBody);
    }
    if (responseBody != null) {
      responseBodyPath = '$stem.response.body';
      File(responseBodyPath).writeAsBytesSync(responseBody);
    }
    return WrittenTraffic(
      headersPath: headersPath,
      requestBodyPath: requestBodyPath,
      responseBodyPath: responseBodyPath,
      requestBodySize: requestBody?.length ?? 0,
      responseBodySize: responseBody?.length ?? 0,
    );
  }

  @override
  Uint8List? readBytes(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    return file.readAsBytesSync();
  }

  @override
  HeaderMaps readHeaders(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) {
        return const HeaderMaps(requestHeaders: {}, responseHeaders: {});
      }
      final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      Map<String, String> mapOf(String key) {
        final raw = decoded[key] as Map<String, dynamic>? ?? {};
        return raw.map((k, v) => MapEntry(k, v as String));
      }
      return HeaderMaps(
        requestHeaders: mapOf('requestHeaders'),
        responseHeaders: mapOf('responseHeaders'),
      );
    } catch (_) {
      return const HeaderMaps(requestHeaders: {}, responseHeaders: {});
    }
  }

  @override
  void deleteSessionFiles(String vmUri) {
    final dir = Directory(sessionDirectory(vmUri));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  @override
  void deleteExportFiles(String vmUri) {
    final dir = Directory(p.join(dataDirectory, 'exports'));
    if (!dir.existsSync()) return;
    final hash8 = exportHash8(vmUri);
    for (final entity in dir.listSync()) {
      final name = p.basename(entity.path);
      final match = name.startsWith('dart_network_mcp_') &&
          (name.endsWith('_$hash8.har') || name.endsWith('_$hash8.json'));
      if (match) entity.deleteSync();
    }
  }
}
