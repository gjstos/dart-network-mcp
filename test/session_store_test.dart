import 'dart:io';
import 'dart:typed_data';

import 'package:dart_network_mcp/src/session_store.dart';
import 'package:dart_network_mcp/src/traffic_files.dart';
import 'package:sqlite3/sqlite3.dart';
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

  SessionStore openFresh() =>
      SessionStore.open(dbPath, dataDirectory: tempDir.path);

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
    WrittenTraffic? written,
    bool bodyUnavailable = false,
  }) {
    final traffic = written ??
        TrafficFiles(tempDir.path).write(
          vmUri: vmUri,
          requestId: requestId,
          startTime: startTime,
          requestHeaders: {'accept': 'application/json'},
          responseHeaders: {'content-type': 'application/json'},
          requestBody: Uint8List.fromList([1, 2, 3]),
          responseBody: Uint8List.fromList([4, 5, 6]),
        );
    return RequestRecord(
      vmUri: vmUri,
      requestId: requestId,
      isolateId: 'isolates/1',
      method: 'GET',
      uri: 'https://example.com/path',
      startTime: startTime,
      endTime: startTime + 100,
      statusCode: statusCode ?? 200,
      reasonPhrase: 'OK',
      headersPath: traffic.headersPath,
      requestBodyPath: traffic.requestBodyPath,
      responseBodyPath: traffic.responseBodyPath,
      requestBodySize: traffic.requestBodySize,
      responseBodySize: traffic.responseBodySize,
      bodyUnavailable: bodyUnavailable,
      error: null,
    );
  }

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

    test('stores paths and rewrites the same primary key', () {
      final store = SessionStore.open(dbPath, dataDirectory: tempDir.path);
      store.upsertSession(liveSession('ws://a/ws'));
      final files = store.files;
      final written = files.write(
        vmUri: 'ws://a/ws',
        requestId: '1',
        startTime: 10,
        requestHeaders: {'a': '1'},
        responseHeaders: {},
        requestBody: Uint8List.fromList([1, 2, 3, 4]),
        responseBody: null,
      );
      store.upsertRequest(
        request(
          vmUri: 'ws://a/ws',
          requestId: '1',
          startTime: 10,
          written: written,
          bodyUnavailable: false,
        ),
      );
      store.close();

      final reopened = SessionStore.open(dbPath, dataDirectory: tempDir.path);
      final row = reopened.listRequests(vmUri: 'ws://a/ws').single;
      expect(row.requestBodyPath, written.requestBodyPath);
      expect(row.responseBodyPath, isNull);
      expect(row.requestBodySize, 4);
      expect(row.headersPath, written.headersPath);
      reopened.close();
    });

    test('migrates inline blobs into files and drops raw_json', () {
      final db = sqlite3.open(dbPath);
      db.execute('CREATE TABLE sessions (vm_uri TEXT PRIMARY KEY, state TEXT, app_name TEXT, isolate_ids TEXT, started_at INTEGER, disconnected_at INTEGER, disconnect_reason TEXT, http_profile_available INTEGER)');
      db.execute('''CREATE TABLE requests (
    vm_uri TEXT, request_id TEXT, isolate_id TEXT, method TEXT, uri TEXT,
    start_time INTEGER, end_time INTEGER, status_code INTEGER, reason_phrase TEXT,
    request_headers TEXT, response_headers TEXT, request_body BLOB, response_body BLOB,
    request_body_size INTEGER, response_body_size INTEGER,
    request_body_truncated INTEGER, response_body_truncated INTEGER,
    body_unavailable INTEGER, error TEXT, raw_json TEXT,
    PRIMARY KEY (vm_uri, request_id, start_time))''');
      db.execute(
        "INSERT INTO sessions VALUES ('ws://old/ws','history','app','[]',1,2,NULL,1)",
      );
      db.execute(
        "INSERT INTO requests VALUES ('ws://old/ws','1','isolates/1','GET','https://example/',10,20,200,'OK','{\"a\":\"b\"}','{}',X'0102',NULL,2,0,1,0,0,NULL,'{\"id\":\"1\"}')",
      );
      db.dispose();

      final store = SessionStore.open(dbPath, dataDirectory: tempDir.path);
      final row = store.listRequests(vmUri: 'ws://old/ws').single;
      expect(row.requestBodyPath, isNotNull);
      expect(File(row.requestBodyPath!).readAsBytesSync(), [1, 2]);
      expect(row.responseBodyPath, isNull);
      expect(row.requestBodySize, 2);
      final headers = store.files.readHeaders(row.headersPath);
      expect(headers.requestHeaders['a'], 'b');
      final info = store.debugTableInfo('requests');
      expect(info.contains('raw_json'), isFalse);
      expect(info.contains('request_body'), isFalse);
      store.close();
    });
  });
}
