import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_network_mcp/src/devtools_export.dart';
import 'package:dart_network_mcp/src/session_store.dart';
import 'package:test/test.dart';

void main() {
  const version = '0.1.0';
  const rawJson = '{"id":"req-1","method":"GET"}';

  RequestRecord sampleRequest({required String rawJson}) {
    return RequestRecord(
      vmUri: 'ws://vm',
      requestId: 'req-1',
      isolateId: 'isolates/1',
      method: 'GET',
      uri: 'https://example.com/',
      startTime: 1710000000000000,
      endTime: 1710000000500000,
      statusCode: 200,
      reasonPhrase: 'OK',
      requestHeaders: {},
      responseHeaders: {},
      requestBody: null,
      responseBody: Uint8List(0),
      requestBodySize: 0,
      responseBodySize: 0,
      requestBodyTruncated: false,
      responseBodyTruncated: false,
      bodyUnavailable: false,
      error: null,
      rawJson: rawJson,
    );
  }

  group('buildDevToolsSnapshot', () {
    test('maps requests to offline DevTools network snapshot', () {
      final snapshot = buildDevToolsSnapshot(
        [sampleRequest(rawJson: rawJson)],
        version: version,
        isFlutterApp: true,
      );

      expect(snapshot['devToolsSnapshot'], isTrue);
      expect(snapshot['devToolsVersion'], 'dart-network-mcp/$version');
      expect(snapshot['activeScreenId'], 'network');
      expect(
        snapshot.keys.toSet(),
        {
          'devToolsSnapshot',
          'devToolsVersion',
          'activeScreenId',
          'connectedApp',
          'network',
        },
      );

      final connectedApp = snapshot['connectedApp'] as Map<String, Object?>;
      expect(connectedApp['isRunningOnDartVM'], isTrue);
      expect(connectedApp['isFlutterApp'], isTrue);
      expect(connectedApp['isProfileBuild'], isFalse);
      expect(connectedApp['isDartWebApp'], isFalse);

      final network = snapshot['network'] as Map<String, Object?>;
      expect(network['socketData'], isEmpty);
      expect(network['webSocketData'], isEmpty);
      expect(network['selectedRequestId'], isNull);
      expect(network['timelineMicrosOffset'], 0);

      final httpRequestData = network['httpRequestData'] as List<Object?>;
      expect(httpRequestData.length, 1);
      final first = httpRequestData.first as Map<String, Object?>;
      expect(first['request'], jsonDecode(rawJson));
    });

    test('connectedApp.isFlutterApp reflects argument', () {
      final snapshot = buildDevToolsSnapshot(
        [],
        version: version,
        isFlutterApp: false,
      );
      final connectedApp = snapshot['connectedApp'] as Map<String, Object?>;
      expect(connectedApp['isFlutterApp'], isFalse);
    });
  });
}
