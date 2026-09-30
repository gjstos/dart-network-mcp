import 'package:dart_network_mcp/src/mcp_config_merge.dart';
import 'package:test/test.dart';

void main() {
  test('keeps MCP_DOCKER and adds dart-network-mcp', () {
    final merged = mergeMcpServerEntry(
      {
        'mcpServers': {
          'MCP_DOCKER': {
            'command': 'docker',
            'args': ['mcp', 'gateway', 'run'],
          },
          'dart-vm-mcp': {
            'command': 'docker',
            'args': ['run', 'dart-vm-mcp:local'],
          },
        },
      },
      {
        'command': 'docker',
        'args': ['mcp', 'gateway', 'run', '--profile', 'dart-network-mcp'],
      },
    );
    final servers = merged['mcpServers'] as Map;
    expect(
      (servers['MCP_DOCKER'] as Map)['args'],
      ['mcp', 'gateway', 'run'],
    );
    expect(
      (servers['dart-network-mcp'] as Map)['args'],
      ['mcp', 'gateway', 'run', '--profile', 'dart-network-mcp'],
    );
    expect(servers.containsKey('dart-vm-mcp'), isFalse);
  });

  test('removeOurMcpServers drops only this server from every agent file', () {
    final stripped = removeOurMcpServers({
      'mcpServers': {
        'MCP_DOCKER': {'command': 'docker'},
        'dart-network-mcp': {'command': 'old'},
        'dart-vm-mcp': {'command': 'older'},
      },
    });
    final servers = stripped['mcpServers'] as Map;
    expect(servers.keys, ['MCP_DOCKER']);
  });
}
