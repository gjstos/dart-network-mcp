import 'dart:io';
import 'dart:typed_data';

import 'package:dart_network_mcp/src/dart_network_mcp.dart';
import 'package:dart_network_mcp/src/session_store.dart';
import 'package:dart_network_mcp/src/traffic_files.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String dataDir;
  late SessionStore store;
  late DartNetworkMcp mcp;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dart-network-mcp-retention');
    dataDir = tempDir.path;
    store = SessionStore.open('$dataDir/network.sqlite', dataDirectory: dataDir);
    mcp = DartNetworkMcp(store: store, dataDirectory: dataDir);
  });

  tearDown(() async {
    await mcp.dispose();
    store.close();
    tempDir.deleteSync(recursive: true);
  });

  SessionRecord liveSession(String vmUri) => SessionRecord(
        vmUri: vmUri,
        state: 'live',
        appName: 'app',
        isolateIds: ['isolates/1'],
        startedAt: 1,
        disconnectedAt: null,
        disconnectReason: null,
        httpProfileAvailable: true,
      );

  SessionRecord historySession({
    required String vmUri,
    required int? disconnectedAt,
  }) =>
      SessionRecord(
        vmUri: vmUri,
        state: 'history',
        appName: 'app',
        isolateIds: ['isolates/1'],
        startedAt: 1,
        disconnectedAt: disconnectedAt,
        disconnectReason: 'closed',
        httpProfileAvailable: true,
      );

  test('default retention is 90 days and setRetention rejects zero', () {
    expect(mcp.getRetention()['retentionDays'], 90);
    expect((mcp.setRetention(0)['error'] as Map)['code'], 'invalid_params');
    expect(mcp.getRetention()['retentionDays'], 90);
  });

  test('sweep deletes history older than the configured days and keeps live', () {
    final day = 24 * 60 * 60 * 1000000;
    mcp.setRetention(1);

    store.upsertSession(historySession(vmUri: 'ws://old/ws', disconnectedAt: 1));
    store.upsertSession(
      historySession(vmUri: 'ws://new/ws', disconnectedAt: 10 * day),
    );
    store.upsertSession(liveSession('ws://live/ws'));
    store.upsertSession(
      historySession(vmUri: 'ws://null/ws', disconnectedAt: null),
    );

    final files = TrafficFiles(dataDir);
    final written = files.write(
      vmUri: 'ws://old/ws',
      requestId: '1',
      startTime: 10,
      requestHeaders: {},
      responseHeaders: {},
      requestBody: Uint8List.fromList([1]),
      responseBody: null,
    );
    store.upsertRequest(
      RequestRecord(
        vmUri: 'ws://old/ws',
        requestId: '1',
        isolateId: 'isolates/1',
        method: 'GET',
        uri: 'https://example.com/1',
        startTime: 10,
        endTime: 20,
        statusCode: 200,
        reasonPhrase: 'OK',
        headersPath: written.headersPath,
        requestBodyPath: written.requestBodyPath,
        responseBodyPath: written.responseBodyPath,
        requestBodySize: written.requestBodySize,
        responseBodySize: written.responseBodySize,
        bodyUnavailable: false,
        error: null,
      ),
    );
    Directory('$dataDir/exports').createSync();
    final hash8 = files.exportHash8('ws://old/ws');
    final exportPath =
        '$dataDir/exports/dart_network_mcp_20260101T000000_$hash8.json';
    File(exportPath).writeAsStringSync('{}');

    final removed = mcp.sweepRetention(nowMicros: 10 * day);
    expect(removed, greaterThanOrEqualTo(1));
    expect(store.getSession('ws://old/ws'), isNull);
    expect(store.getSession('ws://new/ws'), isNotNull);
    expect(store.getSession('ws://live/ws'), isNotNull);
    expect(store.getSession('ws://null/ws'), isNotNull);
    expect(File(written.requestBodyPath!).existsSync(), isFalse);
    expect(File(exportPath).existsSync(), isFalse);
  });
}
