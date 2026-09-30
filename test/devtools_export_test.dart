import 'dart:typed_data';

import 'package:dart_network_mcp/src/devtools_export.dart';
import 'package:dart_network_mcp/src/har_export.dart';
import 'package:test/test.dart';

void main() {
  const version = '0.1.0';

  ExportableRequest sampleRequest() {
    return ExportableRequest(
      vmUri: 'ws://vm',
      requestId: 'req-1',
      isolateId: 'isolates/1',
      method: 'GET',
      uri: 'https://example.com/',
      startTime: 1710000000000000,
      endTime: 1710000000500000,
      statusCode: 200,
      reasonPhrase: 'OK',
      requestHeaders: const {},
      responseHeaders: const {},
      requestBody: null,
      responseBody: null,
      requestBodySize: 0,
      responseBodySize: 0,
      bodyUnavailable: false,
      error: null,
    );
  }

  test('devtools request contains the full body loaded for that request only',
      () {
    final request = devToolsRequest(
      ExportableRequest(
        vmUri: 'ws://vm',
        requestId: '1',
        isolateId: 'isolates/1',
        method: 'POST',
        uri: 'https://example/order',
        startTime: 1,
        endTime: 2000,
        statusCode: 200,
        reasonPhrase: 'OK',
        requestHeaders: {},
        responseHeaders: {'content-type': 'application/json'},
        requestBody: null,
        responseBody: Uint8List.fromList('{"ok":true}'.codeUnits),
        requestBodySize: 0,
        responseBodySize: 11,
        bodyUnavailable: false,
        error: null,
      ),
    );
    expect(request['id'], '1');
    expect(request['method'], 'POST');
    expect(request['uri'], 'https://example/order');
    expect(request['startTime'], 1);
    expect(request['endTime'], 2000);
    expect(request['responseBody'], '{"ok":true}'.codeUnits);
    expect(request.containsKey('rawJson'), isFalse);
  });

  group('buildDevToolsSnapshot', () {
    test('maps requests to offline DevTools network snapshot', () {
      final sample = sampleRequest();
      final snapshot = buildDevToolsSnapshot(
        [sample],
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
      expect(first['request'], devToolsRequest(sample));
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
