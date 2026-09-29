import 'package:dart_vm_mcp/src/mcp_config_merge.dart';
import 'package:test/test.dart';

void main() {
  test('keeps MCP_DOCKER and adds dart-vm-mcp', () {
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
        'args': ['mcp', 'gateway', 'run', '--profile', 'dart-vm-mcp'],
      },
    );
    final servers = merged['mcpServers'] as Map;
    expect(
      (servers['MCP_DOCKER'] as Map)['args'],
      ['mcp', 'gateway', 'run'],
    );
    expect(
      (servers['dart-vm-mcp'] as Map)['args'],
      ['mcp', 'gateway', 'run', '--profile', 'dart-vm-mcp'],
    );
  });
}
