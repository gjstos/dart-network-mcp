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

  final resolvedHome =
      home ?? env['HOME'] ?? env['USERPROFILE'] ?? '';
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
