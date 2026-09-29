import 'dart:convert';
import 'dart:io';

List<String> discoverDtdUris({
  String? dtdUriEnv,
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

  addIfWs(dtdUriEnv);

  final files = dartToolDir
      .listSync(followLinks: false)
      .whereType<File>()
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final entity in files) {
    final name = entity.uri.pathSegments.last;
    if (!name.contains('dtd') && !name.contains('tooling-daemon')) {
      continue;
    }
    Map<String, dynamic> json;
    try {
      json = jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    addIfWs(_jsonString(json['uri']));
    addIfWs(_jsonString(json['dtdUri']));
  }

  return result;
}

String? _jsonString(Object? value) => value is String ? value : null;
