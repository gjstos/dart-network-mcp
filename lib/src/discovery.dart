import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

Directory defaultDartDtdDirectory({
  Map<String, String>? environment,
  String? home,
  String? operatingSystem,
}) {
  final env = environment ?? Platform.environment;
  final override = env['DART_NETWORK_MCP_DTD_DIR'];
  if (override != null && override.isNotEmpty) {
    return Directory(override);
  }

  final resolvedHome = home ?? env['HOME'] ?? env['USERPROFILE'] ?? '';
  final os = operatingSystem ?? Platform.operatingSystem;
  final ctx = os == 'windows' ? p.windows : p.posix;

  if (os == 'macos') {
    return Directory(
      ctx.join(resolvedHome, 'Library', 'Application Support', 'Dart', 'dtd'),
    );
  }
  if (os == 'windows') {
    final local = env['LOCALAPPDATA'];
    if (local != null && local.isNotEmpty) {
      return Directory(ctx.join(local, 'Dart', 'dtd'));
    }
    return Directory(
      ctx.join(resolvedHome, 'AppData', 'Local', 'Dart', 'dtd'),
    );
  }

  final xdg = env['XDG_DATA_HOME'];
  if (xdg != null && xdg.isNotEmpty) {
    return Directory(ctx.join(xdg, 'Dart', 'dtd'));
  }
  return Directory(
    ctx.join(resolvedHome, '.local', 'share', 'Dart', 'dtd'),
  );
}

List<String> discoverDtdUris({
  String? dtdUriEnv,
  Directory? dartDtdDir,
  required Directory dartToolDir,
}) {
  final seen = <String>{};
  final result = <String>[];

  void addIfWs(String? raw) {
    if (raw == null || raw.isEmpty) return;
    final uri = Uri.tryParse(raw);
    if (uri == null) return;
    if (uri.scheme != 'ws' && uri.scheme != 'wss') return;
    if (seen.add(uri.toString())) {
      result.add(uri.toString());
    }
  }

  void addFromJson(Map<String, dynamic> json) {
    addIfWs(_jsonString(json['wsUri']));
    addIfWs(_jsonString(json['uri']));
    addIfWs(_jsonString(json['dtdUri']));
  }

  void scanDir(Directory dir, {required bool requireNameHint}) {
    if (!dir.existsSync()) {
      return;
    }
    final files = dir.listSync(followLinks: false).whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final entity in files) {
      final name = entity.uri.pathSegments.last;
      if (requireNameHint &&
          !name.contains('dtd') &&
          !name.contains('tooling-daemon')) {
        continue;
      }
      Map<String, dynamic> json;
      try {
        json = jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      addFromJson(json);
    }
  }

  addIfWs(dtdUriEnv);
  if (dartDtdDir != null) {
    scanDir(dartDtdDir, requireNameHint: false);
  }
  scanDir(dartToolDir, requireNameHint: true);

  return result;
}

String? _jsonString(Object? value) => value is String ? value : null;

/// DevTools servers (started by IDEs, `flutter run`, agents, ...) listen from
/// 9100 upward and expose the DTD they were launched with over HTTP. This is
/// the only launcher-independent source: `dart tooling-daemon --machine`
/// prints its URI to stdout instead of writing a file under `Dart/dtd`.
const devToolsPorts = [
  9100, 9101, 9102, 9103, 9104, 9105, 9106, 9107, 9108, 9109, //
  9110, 9111, 9112, 9113, 9114, 9115, 9116, 9117, 9118, 9119,
];

Future<List<String>> probeDevToolsDtdUris({
  required String host,
  Iterable<int> ports = devToolsPorts,
}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(milliseconds: 500);
  try {
    final found = await Future.wait(
      ports.map((port) => _devToolsDtdUri(client, host, port)),
    );
    return found.whereType<String>().toSet().toList();
  } finally {
    client.close(force: true);
  }
}

Future<String?> _devToolsDtdUri(
    HttpClient client, String host, int port) async {
  try {
    final request = await client.getUrl(
      Uri(scheme: 'http', host: host, port: port, path: '/api/getDtdUri'),
    );
    final response = await request.close().timeout(
          const Duration(seconds: 1),
        );
    if (response.statusCode != 200) {
      await response.drain<void>();
      return null;
    }
    final body = await utf8.decodeStream(response).timeout(
          const Duration(seconds: 1),
        );
    final json = jsonDecode(body);
    if (json is! Map) return null;
    final raw = _jsonString(json['dtdUri']);
    final uri = raw == null ? null : Uri.tryParse(raw);
    if (uri == null || (uri.scheme != 'ws' && uri.scheme != 'wss')) {
      return null;
    }
    return uri.toString();
  } catch (_) {
    return null;
  }
}
