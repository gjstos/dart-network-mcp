import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('--fresh clears every agent and docker leftovers, then registers the native binary', () async {
    final temp = Directory.systemTemp.createTempSync('install-fresh');
    addTearDown(() => temp.deleteSync(recursive: true));

    final home = Directory('${temp.path}/home')..createSync();
    final bin = Directory('${temp.path}/bin')..createSync();
    final log = File('${temp.path}/docker.log');
    File('${bin.path}/docker').writeAsStringSync(r'''
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
if [ "$1" = "ps" ]; then
  printf '%s\n' idlive
  printf '%s\n' idold
  exit 0
fi
if [ "$1" = "inspect" ]; then
  case "$4" in
    idlive) printf '%s\n' dart-network-mcp:local ;;
    idold) printf '%s\n' dart-vm-mcp:local ;;
    *) printf '%s\n' postgres:16 ;;
  esac
  exit 0
fi
exit 0
''');
    Process.runSync('chmod', ['755', '${bin.path}/docker']);

    final claude = File('${home.path}/.claude.json');
    final cursor = File('${home.path}/.cursor/mcp.json');
    claude.writeAsStringSync(
      jsonEncode({
        'mcpServers': {
          'other': {'command': 'keep'},
          'dart-network-mcp': {'command': 'stale'},
          'dart-vm-mcp': {'command': 'stale'},
        },
      }),
    );
    cursor.parent.createSync(recursive: true);
    cursor.writeAsStringSync(
      jsonEncode({
        'mcpServers': {
          'MCP_DOCKER': {'command': 'docker'},
          'dart-vm-mcp': {'command': 'stale'},
        },
      }),
    );

    final networkData = Directory('${home.path}/.local/share/dart-network-mcp')
      ..createSync(recursive: true);
    File('${networkData.path}/network.sqlite').writeAsStringSync('x');
    final legacyData = Directory('${home.path}/.local/share/dart-vm-mcp')
      ..createSync(recursive: true);
    File('${legacyData.path}/network.sqlite').writeAsStringSync('x');

    final catalogs = Directory('${home.path}/.docker/mcp/catalogs')
      ..createSync(recursive: true);
    File('${catalogs.path}/dart-network-mcp.yaml').writeAsStringSync('old: true\n');
    File('${catalogs.path}/dart-vm-mcp.yaml').writeAsStringSync('old: true\n');
    File('${catalogs.path}/other.yaml').writeAsStringSync('keep: true\n');

    final env = Map<String, String>.from(Platform.environment);
    env['HOME'] = home.path;
    env['PATH'] = '${bin.path}:${env['PATH']}';
    env['FAKE_DOCKER_LOG'] = log.path;
    env.remove('DART_NETWORK_MCP_DATA');
    env.remove('DART_NETWORK_MCP_DTD_DIR');
    env['DART_NETWORK_MCP_INSTALL_SKIP_BUILD'] = '1';
    env['DART_NETWORK_MCP_BIN_DIR'] = '${temp.path}/bin-out';
    env.remove('DART_NETWORK_MCP_INSTALL_SKIP_DOCKER');
    env.remove('LOCALAPPDATA');

    final result = await Process.run(
      'bash',
      ['install.sh', '--fresh', '--cursor'],
      environment: env,
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

    final claudeServers =
        (jsonDecode(claude.readAsStringSync()) as Map)['mcpServers'] as Map;
    expect(claudeServers.containsKey('other'), isTrue);
    expect(claudeServers.containsKey('dart-network-mcp'), isFalse);
    expect(claudeServers.containsKey('dart-vm-mcp'), isFalse);

    final cursorServers =
        (jsonDecode(cursor.readAsStringSync()) as Map)['mcpServers'] as Map;
    expect(cursorServers.containsKey('MCP_DOCKER'), isTrue);
    expect(cursorServers.containsKey('dart-vm-mcp'), isFalse);
    expect(
      (cursorServers['dart-network-mcp'] as Map)['command'],
      '${temp.path}/bin-out/dart_network_mcp',
    );

    expect(networkData.existsSync(), isTrue);
    expect(File('${networkData.path}/network.sqlite').existsSync(), isFalse);
    expect(legacyData.existsSync(), isFalse);
    expect(File('${catalogs.path}/dart-vm-mcp.yaml').existsSync(), isFalse);
    expect(File('${catalogs.path}/other.yaml').existsSync(), isTrue);
    expect(File('${catalogs.path}/dart-network-mcp.yaml').existsSync(), isFalse);

    final lines = log.readAsLinesSync();
    expect(lines, contains('ps -aq'));
    expect(lines, contains('rm -f idlive idold'));
    expect(lines.join('\n'), contains('rmi dart-network-mcp:local dart-vm-mcp:local'));
    expect(lines.join('\n'), contains('mcp profile remove dart-network-mcp'));
    expect(lines.join('\n'), isNot(contains('postgres')));
  });
}
