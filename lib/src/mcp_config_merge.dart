Map<String, Object?> mergeMcpServerEntry(
  Map<String, Object?> config,
  Map<String, Object?> entry,
) {
  final result = Map<String, Object?>.from(config);
  final existing = config['mcpServers'];
  final servers = Map<String, Object?>.from(
    existing is Map ? existing.cast<String, Object?>() : {},
  );
  servers['dart-network-mcp'] = entry;
  servers.remove('dart-vm-mcp');
  result['mcpServers'] = servers;
  return result;
}

Map<String, Object?> removeOurMcpServers(Map<String, Object?> config) {
  final result = Map<String, Object?>.from(config);
  final existing = config['mcpServers'];
  if (existing is! Map) {
    return result;
  }
  final servers = Map<String, Object?>.from(
    existing.cast<String, Object?>(),
  );
  servers.remove('dart-network-mcp');
  servers.remove('dart-vm-mcp');
  result['mcpServers'] = servers;
  return result;
}
