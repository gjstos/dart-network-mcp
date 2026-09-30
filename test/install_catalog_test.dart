import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('catalog declares MCP tools for the Docker Desktop profile', () async {
    final temp = Directory.systemTemp.createTempSync('install-catalog');
    addTearDown(() => temp.deleteSync(recursive: true));

    final env = Map<String, String>.from(Platform.environment);
    env['HOME'] = temp.path;
    env['DART_NETWORK_MCP_INSTALL_SKIP_DOCKER'] = '1';
    env.remove('DART_NETWORK_MCP_DATA');
    env.remove('DART_NETWORK_MCP_DTD_DIR');

    final result = await Process.run(
      'bash',
      ['install.sh', '--cursor'],
      environment: env,
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

    final catalog = File(
      '${temp.path}/.docker/mcp/catalogs/dart-network-mcp.yaml',
    );
    expect(catalog.existsSync(), isTrue);
    final yaml = catalog.readAsStringSync();

    const tools = [
      'list_sessions',
      'get_session',
      'attach_vm',
      'list_requests',
      'get_request',
      'export_har',
      'export_devtools_json',
      'delete_session',
      'get_retention',
      'set_retention',
    ];
    expect(yaml, contains('tools:'));
    for (final name in tools) {
      expect(yaml, contains('name: $name'), reason: 'missing tool $name');
    }
  });
}
