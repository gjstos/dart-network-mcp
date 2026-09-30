import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_network_mcp/src/curl_export.dart';
import 'package:dart_network_mcp/src/har_export.dart';
import 'package:test/test.dart';

ExportableRequest req({
  String method = 'GET',
  String uri = 'https://example.com/a?q=1',
  Map<String, String> headers = const {},
  List<int>? body,
}) {
  return ExportableRequest(
    vmUri: 'ws://vm',
    requestId: '1',
    isolateId: 'isolates/1',
    method: method,
    uri: uri,
    startTime: 1,
    endTime: 2,
    statusCode: 200,
    reasonPhrase: 'OK',
    requestHeaders: headers,
    responseHeaders: const {},
    requestBody: body == null ? null : Uint8List.fromList(body),
    responseBody: null,
    requestBodySize: body?.length ?? 0,
    responseBodySize: 0,
    bodyUnavailable: false,
    error: null,
  );
}

void main() {
  test('plain GET is chrome style: no -X, headers one per line', () {
    final curl = buildCurl(req(headers: {'accept': 'application/json'}));
    expect(
      curl,
      "curl 'https://example.com/a?q=1' \\\n  -H 'accept: application/json'",
    );
  });

  test('POST with body omits -X and uses --data-raw; PUT keeps -X', () {
    final post = buildCurl(req(method: 'POST', body: utf8.encode('{"a":1}')));
    expect(post, contains("--data-raw '{\"a\":1}'"));
    expect(post, isNot(contains('-X')));
    expect(buildCurl(req(method: 'PUT')), contains("-X 'PUT'"));
    expect(buildCurl(req(method: 'POST')), contains("-X 'POST'"));
    expect(buildCurl(req(method: 'HEAD')), contains('--head'));
  });

  test('quotes single quotes and uses ANSI-C for newlines', () {
    final curl = buildCurl(
      req(method: 'POST', body: utf8.encode("it's\nok")),
      multiline: false,
    );
    expect(curl, contains(r"--data-raw $'it\'s\nok'"));
    expect(curl, isNot(contains('\n')));
    final quoted = buildCurl(req(headers: {'x': "a'b"}));
    expect(quoted, contains(r"'x: a'\''b'"));
  });

  test('binary body becomes --data-binary with hex escapes', () {
    final curl = buildCurl(req(method: 'POST', body: [0xff, 0x00, 0x41]));
    expect(curl, contains(r"--data-binary $'\xff\x00A'"));
  });

  test('--compressed follows accept-encoding', () {
    final curl = buildCurl(req(headers: {'Accept-Encoding': 'gzip, br'}));
    expect(curl, endsWith('--compressed'));
    expect(buildCurl(req()), isNot(contains('--compressed')));
  });

  test('flags: no body, no headers, drop noise', () {
    final r = req(
      method: 'POST',
      body: utf8.encode('x'),
      headers: {
        'Authorization': 'Bearer t',
        'Content-Length': '1',
        'User-Agent': 'dart',
        'sec-fetch-mode': 'cors',
        'x-custom': '1',
      },
    );
    final noNoise = buildCurl(r, dropNoiseHeaders: true);
    expect(noNoise, contains('Authorization'));
    expect(noNoise, contains('x-custom'));
    expect(noNoise, isNot(contains('Content-Length')));
    expect(noNoise, isNot(contains('User-Agent')));
    expect(noNoise, isNot(contains('sec-fetch')));
    final noBody = buildCurl(r, includeBody: false);
    expect(noBody, isNot(contains('--data')));
    expect(noBody, contains("-X 'POST'"));
    expect(buildCurl(r, includeHeaders: false), isNot(contains('-H')));
  });

  test('bodyFile replaces inline body', () {
    final curl = buildCurl(req(method: 'POST'), bodyFile: '/tmp/b.bin');
    expect(curl, contains("--data-binary '@/tmp/b.bin'"));
  });
}
