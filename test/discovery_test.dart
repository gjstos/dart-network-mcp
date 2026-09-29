import 'dart:io';

import 'package:dart_network_mcp/src/discovery.dart';
import 'package:test/test.dart';

void main() {
  test('env, dtd files, and no recursion', () {
    final dir = Directory.systemTemp.createTempSync('dtd');
    File('${dir.path}/dart-tooling-daemon.json')
        .writeAsStringSync('{"uri":"ws://127.0.0.1:2/y"}');
    File('${dir.path}/dtd.json').writeAsStringSync('{"dtdUri":"ws://127.0.0.1:3/z"}');
    File('${dir.path}/notes.json').writeAsStringSync('{"uri":"ws://127.0.0.1:4/no"}');
    Directory('${dir.path}/nested').createSync();
    File('${dir.path}/nested/dtd.json').writeAsStringSync('{"uri":"ws://127.0.0.1:5/no"}');

    expect(
      discoverDtdUris(dtdUriEnv: 'ws://127.0.0.1:1/x', dartToolDir: dir),
      [
        'ws://127.0.0.1:1/x',
        'ws://127.0.0.1:2/y',
        'ws://127.0.0.1:3/z',
      ],
    );
  });

  test('skips non-string uri values in json', () {
    final dir = Directory.systemTemp.createTempSync('dtd');
    File('${dir.path}/dtd.json').writeAsStringSync(
      '{"uri": 1, "dtdUri": "ws://127.0.0.1:9/ok"}',
    );

    expect(
      discoverDtdUris(dartToolDir: dir),
      ['ws://127.0.0.1:9/ok'],
    );
  });
}
