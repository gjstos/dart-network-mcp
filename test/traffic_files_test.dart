import 'dart:io';
import 'dart:typed_data';

import 'package:dart_network_mcp/src/traffic_files.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('traffic-files');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('writes headers and both bodies, including empty body', () {
    final files = TrafficFiles(temp.path);
    final written = files.write(
      vmUri: 'ws://vm/ws',
      requestId: 'req/1',
      startTime: 10,
      requestHeaders: {},
      responseHeaders: {'set-cookie': 'a=b'},
      requestBody: Uint8List(0),
      responseBody: Uint8List.fromList([1, 2, 3]),
    );

    expect(File(written.headersPath).readAsStringSync(),
        '{"requestHeaders":{},"responseHeaders":{"set-cookie":"a=b"}}');
    expect(written.requestBodyPath, isNotNull);
    expect(File(written.requestBodyPath!).lengthSync(), 0);
    expect(File(written.responseBodyPath!).readAsBytesSync(), [1, 2, 3]);
    expect(written.requestBodySize, 0);
    expect(written.responseBodySize, 3);
    expect(files.readHeaders(written.headersPath).responseHeaders['set-cookie'],
        'a=b');
  });

  test('omits a body file when that side is null', () {
    final files = TrafficFiles(temp.path);
    final written = files.write(
      vmUri: 'ws://vm/ws',
      requestId: '1',
      startTime: 10,
      requestHeaders: {},
      responseHeaders: {},
      requestBody: null,
      responseBody: Uint8List.fromList([9]),
    );
    expect(written.requestBodyPath, isNull);
    expect(written.responseBodyPath, isNotNull);
  });

  test('readHeaders returns empty maps when the headers file is missing', () {
    final files = TrafficFiles(temp.path);
    final missing = '${temp.path}/nonexistent.headers.json';
    final result = files.readHeaders(missing);
    expect(result.requestHeaders, isEmpty);
    expect(result.responseHeaders, isEmpty);
  });

  test(
      'readHeaders returns empty maps when the headers file contains invalid JSON',
      () {
    final files = TrafficFiles(temp.path);
    final badFile = '${temp.path}/bad.headers.json';
    File(badFile).writeAsStringSync('not-valid-json{{{');
    final result = files.readHeaders(badFile);
    expect(result.requestHeaders, isEmpty);
    expect(result.responseHeaders, isEmpty);
  });

  test(
      'rewrite keeps one file and delete removes the session directory and exports',
      () {
    final files = TrafficFiles(temp.path);
    files.write(
      vmUri: 'ws://vm/ws',
      requestId: '1',
      startTime: 10,
      requestHeaders: {'a': '1'},
      responseHeaders: {},
      requestBody: Uint8List.fromList([1]),
      responseBody: null,
    );
    final again = files.write(
      vmUri: 'ws://vm/ws',
      requestId: '1',
      startTime: 10,
      requestHeaders: {'a': '2'},
      responseHeaders: {},
      requestBody: Uint8List.fromList([1, 2]),
      responseBody: null,
    );
    expect(files.readHeaders(again.headersPath).requestHeaders['a'], '2');
    expect(File(again.requestBodyPath!).lengthSync(), 2);

    final exportDir = Directory('${temp.path}/exports')..createSync();
    final hash8 = files.exportHash8('ws://vm/ws');
    File('${exportDir.path}/dart_network_mcp_20260101T000000_$hash8.har')
        .writeAsStringSync('x');
    File('${exportDir.path}/dart_network_mcp_20260101T000000_other.har')
        .writeAsStringSync('keep');

    files.deleteSessionFiles('ws://vm/ws');
    files.deleteExportFiles('ws://vm/ws');

    expect(
        Directory(files.sessionDirectory('ws://vm/ws')).existsSync(), isFalse);
    expect(
      File('${exportDir.path}/dart_network_mcp_20260101T000000_$hash8.har')
          .existsSync(),
      isFalse,
    );
    expect(
      File('${exportDir.path}/dart_network_mcp_20260101T000000_other.har')
          .existsSync(),
      isTrue,
    );
  });
}
