import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('reaps leftover containers and starts one named container', () async {
    final temp = Directory.systemTemp.createTempSync('run-mcp-container');
    addTearDown(() => temp.deleteSync(recursive: true));

    final log = File('${temp.path}/docker.log');
    final fakeBin = Directory('${temp.path}/bin')..createSync();
    final fakeDocker = File('${fakeBin.path}/docker');
    fakeDocker.writeAsStringSync(r'''
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
if [ "$1" = "ps" ]; then
  printf '%s\n' idnet
  printf '%s\n' idvm1
  printf '%s\n' idother
  exit 0
fi
if [ "$1" = "inspect" ]; then
  case "$4" in
    idnet) printf '%s\n' dart-network-mcp:local ;;
    idvm1) printf '%s\n' dart-vm-mcp:local ;;
    *) printf '%s\n' postgres:16 ;;
  esac
  exit 0
fi
if [ "$1" = "rm" ] && [ "$3" = "dart-network-mcp" ]; then
  exit 1
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
    expect(lines, contains('ps -aq'));
    expect(
      lines,
      containsAll([
        'inspect -f {{.Config.Image}} idnet',
        'inspect -f {{.Config.Image}} idvm1',
        'inspect -f {{.Config.Image}} idother',
        'rm -f idnet idvm1',
        'rm -f dart-network-mcp',
      ]),
    );
    expect(
      lines.where((line) => line.startsWith('rm ')).join('\n'),
      isNot(contains('idother')),
    );

    final run = lines.last;
    expect(run, startsWith('run '));
    expect(run, contains('--name dart-network-mcp'));
    expect(run, contains('-i'));
    expect(run, contains('--rm'));
    expect(run, contains('${home.path}/.dart-tool:/home/mcp/.dart-tool:ro'));
    expect(run, contains('${data.path}:/data:rw'));
    expect(run, endsWith('dart-network-mcp:local'));
  });
}
