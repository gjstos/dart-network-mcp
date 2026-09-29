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
  });
}
