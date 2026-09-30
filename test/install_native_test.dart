import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'install compiles a native server, registers it, and it answers MCP',
    () async {
      final temp = Directory.systemTemp.createTempSync('install-native');
      addTearDown(() => temp.deleteSync(recursive: true));

      final home = Directory('${temp.path}/home')..createSync();
      final binDir = '${temp.path}/bin';
      final dataDir = '${temp.path}/data';
      final realHome = Platform.environment['HOME'] ?? '';
      final env = Map<String, String>.from(Platform.environment)
        // install.sh runs `dart pub get` in the repo; keep it on the real
        // package cache so the temporary HOME does not rewrite package_config.
        ..putIfAbsent('PUB_CACHE', () => '$realHome/.pub-cache')
        ..['HOME'] = home.path
        ..['DART_NETWORK_MCP_BIN_DIR'] = binDir
        ..['DART_NETWORK_MCP_DATA'] = dataDir
        ..remove('LOCALAPPDATA');

      final install = await Process.run(
        'bash',
        ['install.sh', '--claude', '--cursor'],
        environment: env,
      );
      expect(install.exitCode, 0, reason: '${install.stdout}\n${install.stderr}');

      final exe = '$binDir/dart_network_mcp';
      expect(File(exe).existsSync(), isTrue);
      for (final config in [
        '${home.path}/.claude.json',
        '${home.path}/.cursor/mcp.json',
      ]) {
        final servers =
            (jsonDecode(File(config).readAsStringSync()) as Map)['mcpServers']
                as Map;
        expect((servers['dart-network-mcp'] as Map)['command'], exe);
      }
      expect(
        Directory('${home.path}/.docker').existsSync(),
        isFalse,
        reason: 'the native install must not touch Docker',
      );

      final server = await Process.start(exe, [], environment: env);
      addTearDown(server.kill);
      final lines = server.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();
      server.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2024-11-05',
          'capabilities': <String, Object?>{},
          'clientInfo': {'name': 'test', 'version': '0'},
        },
      }));
      final reply = jsonDecode(
        await lines.firstWhere((l) => l.contains('"id":1')).timeout(
              const Duration(seconds: 20),
            ),
      ) as Map;
      expect((reply['result'] as Map)['serverInfo'], containsPair('name', 'dart-network-mcp'));

      await server.stdin.close();
      expect(
        await server.exitCode.timeout(const Duration(seconds: 10)),
        0,
        reason: 'the server must exit once the client closes stdin',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
