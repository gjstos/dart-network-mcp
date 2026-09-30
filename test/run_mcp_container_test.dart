import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('reaps exited containers and leaves a running session alone', () async {
    final temp = Directory.systemTemp.createTempSync('run-mcp-container');
    addTearDown(() => temp.deleteSync(recursive: true));

    final log = File('${temp.path}/docker.log');
    final fakeBin = Directory('${temp.path}/bin')..createSync();
    final fakeDocker = File('${fakeBin.path}/docker');
    fakeDocker.writeAsStringSync(r'''
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
if [ "$1" = "ps" ]; then
  case "$*" in
    *status=exited*)
      printf '%s\n' idexited
      printf '%s\n' idother
      ;;
  esac
  exit 0
fi
if [ "$1" = "inspect" ]; then
  case "$4" in
    idexited) printf '%s\n' dart-vm-mcp:local ;;
    *) printf '%s\n' postgres:16 ;;
  esac
  exit 0
fi
exit 0
''');
    Process.runSync('chmod', ['755', fakeDocker.path]);

    final home = Directory('${temp.path}/home')..createSync();
    final data = Directory('${temp.path}/data')..createSync();
    final env = Map<String, String>.from(Platform.environment);
    env['PATH'] = '${fakeBin.path}:${env['PATH']}';
    env['HOME'] = home.path;
    env['DART_NETWORK_MCP_DATA'] = data.path;
    env['FAKE_DOCKER_LOG'] = log.path;

    final result = await Process.run(
      'bash',
      ['tool/run_mcp_container.sh'],
      environment: env,
    );

    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stdout, isEmpty);

    final lines = log.readAsLinesSync();
    expect(lines, contains('ps -aq --filter status=exited'));
    expect(lines, contains('inspect -f {{.Config.Image}} idexited'));
    expect(lines, contains('inspect -f {{.Config.Image}} idother'));
    expect(lines, contains('rm -f idexited'));
    expect(
      lines.where((line) => line.startsWith('rm ')).join('\n'),
      isNot(contains('idother')),
    );
    expect(lines.join('\n'), isNot(contains('rm -f dart-network-mcp')));

    final run = lines.last;
    expect(run, startsWith('run '));
    expect(run, isNot(contains('--name dart-network-mcp')));
    expect(run, contains('-i'));
    expect(run, contains('--rm'));
    expect(run, contains('${home.path}/.dart-tool:/home/mcp/.dart-tool:ro'));
    final dtdHost = Platform.isMacOS
        ? '${home.path}/Library/Application Support/Dart/dtd'
        : Platform.isWindows
            ? '${home.path}/AppData/Local/Dart/dtd'
            : '${home.path}/.local/share/Dart/dtd';
    expect(run, contains('$dtdHost:/home/mcp/Dart/dtd:ro'));
    expect(run, contains('-e DART_NETWORK_MCP_DTD_DIR=/home/mcp/Dart/dtd'));
    expect(run, contains('${data.path}:/data:rw'));
    expect(run, endsWith('dart-network-mcp:local'));
  });
}
