import 'dart:io';

import 'package:dart_network_mcp/src/discovery.dart';
import 'package:test/test.dart';

void main() {
  test('env, dtd files, and no recursion', () {
    final dir = Directory.systemTemp.createTempSync('dtd');
    addTearDown(() => dir.deleteSync(recursive: true));
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
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/dtd.json').writeAsStringSync(
      '{"uri": 1, "dtdUri": "ws://127.0.0.1:9/ok"}',
    );

    expect(
      discoverDtdUris(dartToolDir: dir),
      ['ws://127.0.0.1:9/ok'],
    );
  });

  test('reads wsUri from legacy dtd.json', () {
    final dir = Directory.systemTemp.createTempSync('dtd');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/dtd.json')
        .writeAsStringSync('{"wsUri":"ws://127.0.0.1:7/ws"}');

    expect(
      discoverDtdUris(dartToolDir: dir),
      ['ws://127.0.0.1:7/ws'],
    );
  });

  test('modern dart dtd dir: all json files, wsUri, no name filter', () {
    final tool = Directory.systemTemp.createTempSync('dart-tool');
    final modern = Directory.systemTemp.createTempSync('dart-dtd');
    addTearDown(() => tool.deleteSync(recursive: true));
    addTearDown(() => modern.deleteSync(recursive: true));

    File('${modern.path}/80179').writeAsStringSync(
      '{"wsUri":"ws://127.0.0.1:65002/a=","pid":80179}',
    );
    File('${modern.path}/41922').writeAsStringSync(
      '{"wsUri":"ws://127.0.0.1:63161/b=","pid":41922}',
    );
    File('${tool.path}/notes.json')
        .writeAsStringSync('{"uri":"ws://127.0.0.1:4/skipped"}');

    expect(
      discoverDtdUris(dartDtdDir: modern, dartToolDir: tool),
      [
        'ws://127.0.0.1:63161/b=',
        'ws://127.0.0.1:65002/a=',
      ],
    );
  });

  test('order is env, modern dir, then legacy dart-tool', () {
    final tool = Directory.systemTemp.createTempSync('dart-tool');
    final modern = Directory.systemTemp.createTempSync('dart-dtd');
    addTearDown(() => tool.deleteSync(recursive: true));
    addTearDown(() => modern.deleteSync(recursive: true));

    File('${modern.path}/80179').writeAsStringSync(
      '{"wsUri":"ws://127.0.0.1:2/modern"}',
    );
    File('${tool.path}/dtd.json')
        .writeAsStringSync('{"dtdUri":"ws://127.0.0.1:3/legacy"}');

    expect(
      discoverDtdUris(
        dtdUriEnv: 'ws://127.0.0.1:1/env',
        dartDtdDir: modern,
        dartToolDir: tool,
      ),
      [
        'ws://127.0.0.1:1/env',
        'ws://127.0.0.1:2/modern',
        'ws://127.0.0.1:3/legacy',
      ],
    );
  });

  test('defaultDartDtdDirectory respects DART_NETWORK_MCP_DTD_DIR', () {
    final override = Directory.systemTemp.createTempSync('dtd-override');
    addTearDown(() => override.deleteSync(recursive: true));

    final dir = defaultDartDtdDirectory(
      environment: {'DART_NETWORK_MCP_DTD_DIR': override.path},
      home: '/unused',
    );
    expect(dir.path, override.path);
  });

  test('defaultDartDtdDirectory macOS path', () {
    final dir = defaultDartDtdDirectory(
      environment: const {},
      home: '/Users/me',
      operatingSystem: 'macos',
    );
    expect(
      dir.path,
      '/Users/me/Library/Application Support/Dart/dtd',
    );
  });

  test('defaultDartDtdDirectory linux path uses XDG_DATA_HOME', () {
    final dir = defaultDartDtdDirectory(
      environment: const {'XDG_DATA_HOME': '/xdg'},
      home: '/home/me',
      operatingSystem: 'linux',
    );
    expect(dir.path, '/xdg/Dart/dtd');
  });

  test('defaultDartDtdDirectory windows path uses LOCALAPPDATA', () {
    final dir = defaultDartDtdDirectory(
      environment: const {'LOCALAPPDATA': r'C:\Users\me\AppData\Local'},
      home: r'C:\Users\me',
      operatingSystem: 'windows',
    );
    expect(dir.path, r'C:\Users\me\AppData\Local\Dart\dtd');
  });
}
