String canonicalizeVmUri(String raw) {
  final uri = Uri.parse(raw.trim());
  final scheme = switch (uri.scheme) {
    'http' => 'ws',
    'https' => 'wss',
    'ws' => 'ws',
    'wss' => 'wss',
    _ => throw FormatException('unsupported vm uri scheme: ${uri.scheme}'),
  };
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty || segments.last != 'ws') {
    segments.add('ws');
  }
  return uri.replace(scheme: scheme, pathSegments: segments).removeFragment().toString();
}
