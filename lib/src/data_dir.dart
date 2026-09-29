import 'package:path/path.dart' as p;

String resolveDataDirectory(Map<String, String> env) {
  final override = env['DART_VM_MCP_DATA'];
  if (override != null && override.isNotEmpty) {
    return override;
  }
  final localAppData = env['LOCALAPPDATA'];
  if (localAppData != null && localAppData.isNotEmpty) {
    return p.windows.join(localAppData, 'dart-vm-mcp');
  }
  final home = env['HOME'] ?? env['USERPROFILE'];
  if (home == null || home.isEmpty) {
    throw StateError('HOME or USERPROFILE is required');
  }
  return p.join(home, '.local', 'share', 'dart-vm-mcp');
}
