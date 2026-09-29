import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_network_mcp/src/har_export.dart';
import 'package:dart_network_mcp/src/session_store.dart';
import 'package:test/test.dart';

void main() {
  const harVersion = '0.1.0-test';

  RequestRecord sampleGetRequest({
    int? endTime = 1710000000500000,
    Uint8List? responseBody,
    int? responseBodySize,
    Uint8List? requestBody,
    int? requestBodySize,
  }) {
    final body = responseBody ?? Uint8List.fromList(utf8.encode('{"ok":true}'));
    return RequestRecord(
      vmUri: 'ws://vm',
      requestId: 'req-1',
      isolateId: 'isolates/1',
      method: 'GET',
      uri: 'https://example.com/a?q=1',
      startTime: 1710000000000000,
      endTime: endTime,
      statusCode: 200,
      reasonPhrase: 'OK',
      requestHeaders: {'accept': 'application/json'},
      responseHeaders: {'content-type': 'application/json'},
      requestBody: requestBody,
      responseBody: body,
      requestBodySize: requestBodySize ?? requestBody?.length ?? 0,
      responseBodySize: responseBodySize ?? body.length,
      requestBodyTruncated: false,
      responseBodyTruncated: false,
      bodyUnavailable: false,
      error: null,
      rawJson: '{}',
    );
  }

  group('buildHar', () {
    test('maps a GET request to HAR 1.2 log metadata and entry fields', () {
      final har = buildHar([sampleGetRequest()], version: harVersion);
      final log = har['log'] as Map<String, Object?>;
      expect(log['version'], '1.2');

      final creator = log['creator'] as Map<String, Object?>;
      expect(creator['name'], 'dart-network-mcp');
      expect(creator['version'], harVersion);

      final entries = log['entries'] as List<Object?>;
      expect(entries.length, 1);
      final entry = entries.single as Map<String, Object?>;
      expect(entry['time'], 500);

      final request = entry['request'] as Map<String, Object?>;
      expect(request['httpVersion'], 'HTTP/1.1');
      expect(
        request['queryString'],
        [
          {'name': 'q', 'value': '1'},
        ],
      );

      final response = entry['response'] as Map<String, Object?>;
      final content = response['content'] as Map<String, Object?>;
      expect(content['text'], '{"ok":true}');
      expect(content.containsKey('encoding'), isFalse);

      final timings = entry['timings'] as Map<String, Object?>;
      expect(timings['send'], 0);
      expect(timings['wait'], 500);
      expect(timings['receive'], 0);
      expect(timings['blocked'], -1);
      expect(timings['dns'], -1);
      expect(timings['connect'], -1);
      expect(timings['ssl'], -1);
    });

    test('empty request list yields empty entries', () {
      final har = buildHar([], version: harVersion);
      final log = har['log'] as Map<String, Object?>;
      final entries = log['entries'] as List<Object?>;
      expect(entries, isEmpty);
    });

    test('binary response body with null byte uses base64 encoding', () {
      final body = Uint8List.fromList([0x00, 0x41]);
      final har = buildHar(
        [
          sampleGetRequest(
            responseBody: body,
            responseBodySize: body.length,
          ),
        ],
        version: harVersion,
      );
      final entries = (har['log'] as Map)['entries'] as List;
      final content =
          ((entries.single as Map)['response'] as Map)['content'] as Map;
      expect(content['encoding'], 'base64');
      expect(content['text'], base64Encode(body));
    });

    test('null endTime yields entry time 0', () {
      final har = buildHar(
        [sampleGetRequest(endTime: null)],
        version: harVersion,
      );
      final entries = (har['log'] as Map)['entries'] as List;
      final entry = entries.single as Map<String, Object?>;
      expect(entry['time'], 0);
    });

    test('invalid UTF-8 response without null byte uses base64 encoding', () {
      final body = Uint8List.fromList([0xC3, 0x28]);
      final har = buildHar(
        [
          sampleGetRequest(
            responseBody: body,
            responseBodySize: body.length,
          ),
        ],
        version: harVersion,
      );
      final entries = (har['log'] as Map)['entries'] as List;
      final content =
          ((entries.single as Map)['response'] as Map)['content'] as Map;
      expect(content['encoding'], 'base64');
      expect(content['text'], base64Encode(body));
    });

    test('UTF-8 request body maps to postData text without encoding', () {
      final requestBody = Uint8List.fromList(utf8.encode('hello'));
      final har = buildHar(
        [sampleGetRequest(requestBody: requestBody)],
        version: harVersion,
      );
      final entries = (har['log'] as Map)['entries'] as List;
      final request = (entries.single as Map)['request'] as Map;
      final postData = request['postData'] as Map;
      expect(postData['text'], 'hello');
      expect(postData.containsKey('encoding'), isFalse);
    });
  });
}
