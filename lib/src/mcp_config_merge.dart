Map<String, Object?> mergeMcpServerEntry(
  Map<String, Object?> config,
  Map<String, Object?> entry,
) {
  final result = Map<String, Object?>.from(config);
  final existing = config['mcpServers'];
  final servers = Map<String, Object?>.from(
    existing is Map ? existing.cast<String, Object?>() : {},
  );
  servers['dart-vm-mcp'] = entry;
  result['mcpServers'] = servers;
  return result;
}
