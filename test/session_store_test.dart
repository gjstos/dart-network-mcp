import 'dart:io';
import 'dart:typed_data';

import 'package:dart_network_mcp/src/session_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dart-network-mcp');
    dbPath = '${tempDir.path}/network.sqlite';
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  SessionStore openFresh() => SessionStore.open(dbPath);

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

  RequestRecord request({
    required String vmUri,
    required String requestId,
    required int startTime,
    int? statusCode,
  }) =>
      RequestRecord(
        vmUri: vmUri,
        requestId: requestId,
        isolateId: 'isolates/1',
        method: 'GET',
        uri: 'https://example.com/path',
        startTime: startTime,
        endTime: startTime + 100,
        statusCode: statusCode ?? 200,
        reasonPhrase: 'OK',
        requestHeaders: {'accept': 'application/json'},
        responseHeaders: {'content-type': 'application/json'},
        requestBody: Uint8List.fromList([1, 2, 3]),
        responseBody: Uint8List.fromList([4, 5, 6]),
        requestBodySize: 3,
        responseBodySize: 3,
        requestBodyTruncated: false,
        responseBodyTruncated: false,
        bodyUnavailable: false,
        error: null,
        rawJson: '{"id":"$requestId"}',
      );

  group('persistence via WAL', () {
    test('two vmUri do not return each other requests in listRequests', () {
      final store = openFresh();
      store.upsertSession(liveSession('ws://a'));
      store.upsertSession(liveSession('ws://b'));
      store.upsertRequest(
        request(vmUri: 'ws://a', requestId: 'req-a', startTime: 10),
      );
      store.upsertRequest(
        request(vmUri: 'ws://b', requestId: 'req-b', startTime: 20),
      );
      store.close();

      final reopened = openFresh();
      final forA = reopened.listRequests(vmUri: 'ws://a');
      expect(forA.length, 1);
      expect(forA.single.requestId, 'req-a');
      expect(
        reopened.listRequests(vmUri: 'ws://b').single.requestId,
        'req-b',
      );
      reopened.close();
    });

    test('upsertRequest twice with same startTime keeps one row and updates statusCode',
        () {
      final store = openFresh();
      store.upsertSession(liveSession('ws://a'));
      store.upsertRequest(
        request(
          vmUri: 'ws://a',
          requestId: 'req-1',
          startTime: 100,
          statusCode: 200,
        ),
      );
      store.upsertRequest(
        request(
          vmUri: 'ws://a',
          requestId: 'req-1',
          startTime: 100,
          statusCode: 404,
        ),
      );
      store.close();

      final reopened = openFresh();
      final rows = reopened.listRequests(vmUri: 'ws://a');
      expect(rows.length, 1);
      expect(rows.single.statusCode, 404);
      reopened.close();
    });

    test(
        'another startTime on same requestId inserts second row and findByRequestId returns both',
        () {
      final store = openFresh();
      store.upsertSession(liveSession('ws://a'));
      store.upsertRequest(
        request(
          vmUri: 'ws://a',
          requestId: 'req-dup',
          startTime: 200,
          statusCode: 200,
        ),
      );
      store.upsertRequest(
        request(
          vmUri: 'ws://a',
          requestId: 'req-dup',
          startTime: 300,
          statusCode: 201,
        ),
      );
      store.close();

      final reopened = openFresh();
      final byId = reopened.findByRequestId(
        vmUri: 'ws://a',
        requestId: 'req-dup',
      );
      expect(byId.length, 2);
      expect(byId.map((r) => r.startTime), [200, 300]);
      expect(byId.map((r) => r.statusCode), [200, 201]);
      reopened.close();
    });

    test('markHistory changes state and fills disconnectReason without deleting requests',
        () {
      final store = openFresh();
      store.upsertSession(liveSession('ws://a'));
      store.upsertRequest(
        request(vmUri: 'ws://a', requestId: 'keep-me', startTime: 50),
      );
      store.markHistory('ws://a', 'socket_closed', 999);
      store.close();

      final reopened = openFresh();
      final session = reopened.getSession('ws://a');
      expect(session?.state, 'history');
      expect(session?.disconnectReason, 'socket_closed');
      expect(session?.disconnectedAt, 999);
      expect(reopened.listRequests(vmUri: 'ws://a').length, 1);
      reopened.close();
    });

    test("deleteSession('ws://a') removes only that key", () {
      final store = openFresh();
      store.upsertSession(liveSession('ws://a'));
      store.upsertSession(liveSession('ws://b'));
      store.upsertRequest(
        request(vmUri: 'ws://a', requestId: 'gone', startTime: 1),
      );
      store.upsertRequest(
        request(vmUri: 'ws://b', requestId: 'stays', startTime: 2),
      );
      store.deleteSession('ws://a');
      store.close();

      final reopened = openFresh();
      expect(reopened.getSession('ws://a'), isNull);
      expect(reopened.getSession('ws://b'), isNotNull);
      expect(reopened.listRequests(vmUri: 'ws://b').length, 1);
      expect(reopened.listRequests(vmUri: 'ws://a'), isEmpty);
      reopened.close();
    });

    test("listSessions('live') omits history", () {
      final store = openFresh();
      store.upsertSession(liveSession('ws://a'));
      store.upsertSession(liveSession('ws://b'));
      store.markHistory('ws://b', 'process_restart', 500);
      store.close();

      final reopened = openFresh();
      final live = reopened.listSessions('live');
      expect(live.length, 1);
      expect(live.single.vmUri, 'ws://a');
      reopened.close();
    });
  });
}
