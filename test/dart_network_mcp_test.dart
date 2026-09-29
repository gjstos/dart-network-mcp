import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_network_mcp/src/dart_network_mcp.dart';
import 'package:dart_network_mcp/src/session_store.dart';
import 'package:dart_network_mcp/src/tool_json.dart';
import 'package:dart_network_mcp/src/traffic_files.dart';
import 'package:dart_network_mcp/src/vm_uri.dart';
import 'package:test/test.dart';

import 'support/fake_vm_service.dart';

class ThrowingReadFiles extends TrafficFiles {
  ThrowingReadFiles(super.dataDirectory);

  int readCalls = 0;

  @override
  Uint8List? readBytes(String path) {
    readCalls++;
    throw StateError('readBytes should not be called');
  }

  @override
  HeaderMaps readHeaders(String path) {
    readCalls++;
    throw StateError('readHeaders should not be called');
  }
}

void main() {
  late Directory tempDir;
  late String dataDir;
  late SessionStore store;
  late DartNetworkMcp mcp;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dart-network-mcp-tool');
    dataDir = tempDir.path;
    store = SessionStore.open('$dataDir/network.sqlite', dataDirectory: dataDir);
    mcp = DartNetworkMcp(store: store, dataDirectory: dataDir);
  });

  tearDown(() async {
    await mcp.dispose();
    store.close();
    tempDir.deleteSync(recursive: true);
  });

  FakeHttpProfileEntry sampleRequest({
    required String id,
    required int startTime,
    int statusCode = 200,
    List<int> responseBody = const [1, 2, 3],
  }) =>
      FakeHttpProfileEntry(
        id: id,
        method: 'GET',
        uri: 'https://example.com/$id',
        startTime: startTime,
        endTime: startTime + 50,
        statusCode: statusCode,
        responseBody: responseBody,
      );

  Future<String> attachFake(FakeVmService fake) async {
    final result = await mcp.attachVm(fake.consoleHttpUri, inDocker: false);
    expect(result['error'], isNull);
    return canonicalizeVmUri(fake.consoleHttpUri);
  }

  group('DartNetworkMcp', () {
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

    test('listRequests returns sizes and does not read body files', () {
      const vmUri = 'ws://127.0.0.1:8181/ws';
      final dbPath = '${tempDir.path}/throwing.sqlite';
      final files = ThrowingReadFiles(tempDir.path);
      final store = SessionStore.open(
        dbPath,
        dataDirectory: tempDir.path,
        files: files,
      );
      final mcp = DartNetworkMcp(store: store, dataDirectory: tempDir.path);
      addTearDown(() {
        store.close();
      });
      store.upsertSession(liveSession(vmUri));
      final written = TrafficFiles(tempDir.path).write(
        vmUri: vmUri,
        requestId: '1',
        startTime: 10,
        requestHeaders: {'cookie': 'huge'},
        responseHeaders: {},
        requestBody: null,
        responseBody: Uint8List.fromList(List.filled(50, 1)),
      );
      store.upsertRequest(
        RequestRecord(
          vmUri: vmUri,
          requestId: '1',
          isolateId: 'isolates/1',
          method: 'GET',
          uri: 'https://example.com/1',
          startTime: 10,
          endTime: 5010,
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

      final page = mcp.listRequests(vmUri);
      final item = (page['requests'] as List).single as Map;
      expect(item['responseBodySize'], 50);
      expect(item['requestBodySize'], 0);
      expect(item['bodyUnavailable'], isFalse);
      expect(item['durationMs'], 5);
      expect(item.containsKey('responseBody'), isFalse);
      expect(item.containsKey('requestHeaders'), isFalse);
      expect(item.containsKey('responseBodyPath'), isFalse);
      expect(files.readCalls, 0);
    });

    test('getRequest inlines a small json body', () {
      const vmUri = 'ws://127.0.0.1:8181/ws';
      store.upsertSession(liveSession(vmUri));
      final written = store.files.write(
        vmUri: vmUri,
        requestId: '1',
        startTime: 10,
        requestHeaders: {'accept': 'application/json'},
        responseHeaders: {},
        requestBody: null,
        responseBody: Uint8List.fromList(utf8.encode('{"id":1}')),
      );
      store.upsertRequest(
        RequestRecord(
          vmUri: vmUri,
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

      final detail = mcp.getRequest(vmUri, '1')['request'] as Map;
      expect(detail['responseBody'], {'id': 1});
      expect(detail['responseBodyEncoding'], 'json');
      expect(detail.containsKey('responseBodyPath'), isFalse);
      expect(detail['requestHeaders'], {'accept': 'application/json'});
    });

    test('getRequest replaces oversized response body with path and size', () {
      const vmUri = 'ws://127.0.0.1:8181/ws';
      store.upsertSession(liveSession(vmUri));
      final body = Uint8List.fromList(List.filled(120000, 0x61));
      final written = store.files.write(
        vmUri: vmUri,
        requestId: '1',
        startTime: 10,
        requestHeaders: {'accept': 'application/json'},
        responseHeaders: {},
        requestBody: null,
        responseBody: body,
      );
      store.upsertRequest(
        RequestRecord(
          vmUri: vmUri,
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

      final detail = mcp.getRequest(vmUri, '1')['request'] as Map;
      expect(detail.containsKey('responseBody'), isFalse);
      expect(detail['responseBodyPath'], isNotEmpty);
      expect(detail['responseBodySize'], 120000);
      expect(detail.containsKey('requestHeaders'), isTrue);
    });

    test('getRequest ambiguous request does not read files', () {
      const vmUri = 'ws://127.0.0.1:8181/ws';
      final files = ThrowingReadFiles(tempDir.path);
      final store = SessionStore.open(
        '${tempDir.path}/ambiguous.sqlite',
        dataDirectory: tempDir.path,
        files: files,
      );
      final mcp = DartNetworkMcp(store: store, dataDirectory: tempDir.path);
      addTearDown(store.close);
      store.upsertSession(liveSession(vmUri));
      for (final startTime in [10, 20]) {
        store.upsertRequest(
          RequestRecord(
            vmUri: vmUri,
            requestId: 'same',
            isolateId: 'isolates/1',
            method: 'GET',
            uri: 'https://example.com/same',
            startTime: startTime,
            endTime: startTime + 1,
            statusCode: 200,
            reasonPhrase: 'OK',
            headersPath: 'unused.headers.json',
            requestBodyPath: null,
            responseBodyPath: null,
            requestBodySize: 0,
            responseBodySize: 0,
            bodyUnavailable: false,
            error: null,
          ),
        );
      }

      final result = mcp.getRequest(vmUri, 'same');
      expect((result['error'] as Map)['code'], 'ambiguous_request');
      expect(files.readCalls, 0);
    });

    test('listRequests includes response body text', () async {
      final fake = await FakeVmService.start();
      fake.addRequest(
        sampleRequest(
          id: 'body-req',
          startTime: 50,
          responseBody: '{"uuid":"abc"}'.codeUnits,
        ),
      );
      final key = await attachFake(fake);
      final result = mcp.listRequests(key);
      final requests = result['requests'] as List<dynamic>;
      final item = requests.single as Map;
      expect(item['method'], 'GET');
      expect(item['responseBodySize'], '{"uuid":"abc"}'.length);
      expect(item['durationMs'], 0);
      expect(item.containsKey('responseBody'), isFalse);
      expect(item.containsKey('requestBody'), isFalse);
      expect(item.containsKey('requestHeaders'), isFalse);
      expect(item.containsKey('isolateId'), isFalse);
      await fake.close();
    });

    test('attachVm uses the pubspec package name as appName', () async {
      final fake = await FakeVmService.start(
        rootLibUri: 'package:dart_network_mcp_example/main.dart',
      );
      final result = await mcp.attachVm(fake.consoleHttpUri, inDocker: false);
      expect(result['appName'], 'dart_network_mcp_example');
      await fake.close();
    });

    test('listRequests and getRequest encode bodies by content', () async {
      final fake = await FakeVmService.start();
      const start = 2000000;
      fake.addRequest(
        FakeHttpProfileEntry(
          id: 'json-object',
          method: 'POST',
          uri: 'https://jsonplaceholder.typicode.com/posts',
          startTime: start,
          endTime: start + 1500000,
          statusCode: 201,
          reasonPhrase: 'Created',
          requestHeaders: const {'content-type': 'application/json'},
          responseHeaders: const {'content-type': 'application/json'},
          requestBody: '{"title":"a"}'.codeUnits,
          responseBody: '{"id":1,"title":"a"}'.codeUnits,
        ),
      );
      fake.addRequest(
        FakeHttpProfileEntry(
          id: 'json-array',
          method: 'GET',
          uri: 'https://jsonplaceholder.typicode.com/posts',
          startTime: start + 1,
          endTime: start + 2,
          responseBody: '[{"id":1}]'.codeUnits,
        ),
      );
      fake.addRequest(
        FakeHttpProfileEntry(
          id: 'plain-text',
          method: 'GET',
          uri: 'https://example.com/note',
          startTime: start + 3,
          endTime: start + 4,
          responseBody: 'not json'.codeUnits,
        ),
      );
      fake.addRequest(
        FakeHttpProfileEntry(
          id: 'broken-json',
          method: 'GET',
          uri: 'https://example.com/cut',
          startTime: start + 5,
          endTime: start + 6,
          responseBody: '{"a":'.codeUnits,
        ),
      );
      fake.addRequest(
        FakeHttpProfileEntry(
          id: 'binary',
          method: 'GET',
          uri: 'https://example.com/bin',
          startTime: start + 7,
          endTime: start + 8,
          responseBody: const [0xFF, 0xFE],
        ),
      );
      final key = await attachFake(fake);
      final listed = mcp.listRequests(key);
      final byId = {
        for (final raw in listed['requests'] as List<dynamic>)
          (raw as Map)['requestId'] as String: raw,
      };

      final objectItem = byId['json-object'] as Map;
      expect(objectItem['durationMs'], 1500);
      expect(objectItem['requestBodySize'], '{"title":"a"}'.length);
      expect(objectItem['responseBodySize'], '{"id":1,"title":"a"}'.length);
      expect(objectItem.containsKey('requestBody'), isFalse);
      expect(objectItem.containsKey('responseBody'), isFalse);
      expect(objectItem.containsKey('requestHeaders'), isFalse);
      expect(objectItem.containsKey('responseHeaders'), isFalse);
      expect(objectItem.containsKey('isolateId'), isFalse);
      expect(objectItem.containsKey('reasonPhrase'), isFalse);
      expect(objectItem.containsKey('endTime'), isFalse);
      expect(objectItem.containsKey('responseBodyPath'), isFalse);

      expect(byId['json-array']!['responseBodySize'], '[{"id":1}]'.length);
      expect(byId['plain-text']!['responseBodySize'], 'not json'.length);
      expect(byId['broken-json']!['responseBodySize'], '{"a":'.length);
      expect(byId['binary']!['responseBodySize'], 2);

      final detail =
          mcp.getRequest(key, 'json-object', startTime: start)['request']
              as Map;
      expect(detail['isolateId'], 'isolates/main');
      expect(detail['reasonPhrase'], 'Created');
      expect(detail['endTime'], start + 1500000);
      expect(detail['requestHeaders'], {'content-type': 'application/json'});
      expect(detail['responseHeaders'], {'content-type': 'application/json'});
      expect(detail['requestBody'], {'title': 'a'});
      expect(detail['requestBodyEncoding'], 'json');
      expect(detail['responseBody'], {'id': 1, 'title': 'a'});
      expect(detail['responseBodyEncoding'], 'json');
      expect(detail['requestBodySize'], '{"title":"a"}'.length);
      expect(detail['responseBodySize'], '{"id":1,"title":"a"}'.length);

      final exported = mcp.exportHar(key);
      final har =
          jsonDecode(File(exported['path'] as String).readAsStringSync())
              as Map;
      final entries = ((har['log'] as Map)['entries'] as List).cast<Map>();
      final objectEntry = entries.firstWhere(
        (entry) =>
            ((entry['request'] as Map)['url'] as String).endsWith('/posts') &&
            (entry['request'] as Map)['method'] == 'POST',
      );
      final postData = (objectEntry['request'] as Map)['postData'] as Map;
      expect(postData['text'], '{"title":"a"}');
      expect(postData.containsKey('encoding'), isFalse);
      final content =
          ((objectEntry['response'] as Map)['content'] as Map);
      expect(content['text'], '{"id":1,"title":"a"}');
      expect(content['size'], '{"id":1,"title":"a"}'.length);
      expect(content.containsKey('encoding'), isFalse);
      await fake.close();
    });

    test('truncated body that is not valid JSON stays utf8 text', () async {
      final fake = await FakeVmService.start();
      final bigBody = List<int>.filled(1000001, 0x7B);
      fake.addRequest(
        sampleRequest(id: 'cut', startTime: 80, responseBody: bigBody),
      );
      final key = await attachFake(fake);
      final item =
          (mcp.listRequests(key)['requests'] as List).single as Map;
      expect(item.containsKey('responseBody'), isFalse);
      expect(item.containsKey('responseBodyEncoding'), isFalse);
      expect(item.containsKey('isolateId'), isFalse);
      await fake.close();
    });

    test('history_requires_flag omits requests from JSON', () async {
      final fake = await FakeVmService.start();
      fake.addRequest(sampleRequest(id: 'hist-req', startTime: 100));
      final key = await attachFake(fake);

      fake.closeClients();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final result = mcp.listRequests(key);
      final json = encodeJson(result);
      expect(result['error'], isNotNull);
      expect((result['error'] as Map)['code'], 'history_requires_flag');
      expect(json, isNot(contains('"requests"')));
      await fake.close();
    });

    test('historyHint lists crash vmUri when no live sessions', () async {
      final fake = await FakeVmService.start();
      final key = await attachFake(fake);
      fake.closeClients();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final result = mcp.listSessions();
      final hint = result['historyHint'] as Map<String, Object?>?;
      expect(hint, isNotNull);
      final uris = hint!['vmUris'] as List<dynamic>;
      expect(uris, contains(key));
      await fake.close();
    });

    test('vm_not_found JSON does not leak other stored vmUri', () async {
      final fakeA = await FakeVmService.start();
      final fakeB = await FakeVmService.start();
      await attachFake(fakeA);
      await attachFake(fakeB);

      const missing = 'ws://127.0.0.1:59999/no-such/ws';
      final result = mcp.getSession(missing);
      final json = encodeJson(result);
      expect((result['error'] as Map)['code'], 'vm_not_found');
      expect(json, isNot(contains(canonicalizeVmUri(fakeA.consoleHttpUri))));
      expect(json, isNot(contains(canonicalizeVmUri(fakeB.consoleHttpUri))));
      await fakeA.close();
      await fakeB.close();
    });

    test('request_not_found for unknown requestId', () async {
      final fake = await FakeVmService.start();
      final key = await attachFake(fake);
      final result = mcp.getRequest(key, 'missing-id');
      expect((result['error'] as Map)['code'], 'request_not_found');
      await fake.close();
    });

    test('ambiguous_request lists startTimes without bodies', () async {
      final fake = await FakeVmService.start();
      fake.addRequest(sampleRequest(id: 'dup', startTime: 400));
      fake.addRequest(sampleRequest(id: 'dup', startTime: 500));
      final key = await attachFake(fake);

      final result = mcp.getRequest(key, 'dup');
      final json = encodeJson(result);
      final error = result['error'] as Map<String, Object?>;
      expect(error['code'], 'ambiguous_request');
      expect(error['startTimes'], [400, 500]);
      expect(json, isNot(contains('"requestBody"')));
      expect(json, isNot(contains('"responseBody"')));
      await fake.close();
    });

    test('http_profile_unavailable when profiler disabled', () async {
      final fake = await FakeVmService.start(httpAvailable: false);
      final key = await attachFake(fake);
      final result = mcp.listRequests(key);
      expect((result['error'] as Map)['code'], 'http_profile_unavailable');
      await fake.close();
    });

    test('includeHistory on live session keeps state live', () async {
      final fake = await FakeVmService.start();
      fake.addRequest(sampleRequest(id: 'live-req', startTime: 600));
      final key = await attachFake(fake);

      final result = mcp.listRequests(key, includeHistory: true);
      expect(result['error'], isNull);
      expect(result['state'], 'live');
      expect(result['requests'], isNotEmpty);
      await fake.close();
    });

    test('deleteSession removes rows, body directory and matching exports',
        () async {
      const vmUri = 'ws://127.0.0.1:8181/ws';
      store.upsertSession(liveSession(vmUri));
      final files = TrafficFiles(tempDir.path);
      final written = files.write(
        vmUri: vmUri,
        requestId: '1',
        startTime: 10,
        requestHeaders: {},
        responseHeaders: {},
        requestBody: Uint8List.fromList([1]),
        responseBody: null,
      );
      Directory('${tempDir.path}/exports').createSync();
      final hash8 = files.exportHash8(vmUri);
      File('${tempDir.path}/exports/dart_network_mcp_20260101T000000_$hash8.json')
          .writeAsStringSync('{}');
      store.upsertRequest(
        RequestRecord(
          vmUri: vmUri,
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

      final result = await mcp.deleteSession(vmUri);
      expect(result['deleted'], isTrue);
      expect(store.getSession(vmUri), isNull);
      expect(File(written.requestBodyPath!).existsSync(), isFalse);
      expect(
        File('${tempDir.path}/exports/dart_network_mcp_20260101T000000_$hash8.json')
            .existsSync(),
        isFalse,
      );
    });

    test('deleteSession removes export har from disk', () async {
      final fake = await FakeVmService.start();
      fake.addRequest(sampleRequest(id: 'export-me', startTime: 700));
      final key = await attachFake(fake);

      final exported = mcp.exportHar(key);
      final path = exported['path'] as String;
      expect(File(path).existsSync(), isTrue);

      final deleted = await mcp.deleteSession(key);
      expect(deleted['error'], isNull);
      expect(deleted['vmUri'], key);
      expect(deleted['state'], 'live');
      expect(File(path).existsSync(), isFalse);
      expect(store.getSession(key), isNull);
      await fake.close();
    });

    test('failed history reconnect keeps requests and history state', () async {
      final fake = await FakeVmService.start();
      fake.addRequest(sampleRequest(id: 'crash-req', startTime: 900));
      final key = await attachFake(fake);
      expect(store.listRequests(vmUri: key).length, 1);

      fake.closeClients();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(store.getSession(key)?.state, 'history');

      await fake.close();
      final result = await mcp.attachVm(fake.consoleHttpUri, inDocker: false);
      expect((result['error'] as Map)['code'], 'attach_failed');
      expect(store.getSession(key)?.state, 'history');
      expect(store.listRequests(vmUri: key).length, 1);
    });

    test('exportHar includes all stored requests beyond 200', () async {
      final fake = await FakeVmService.start();
      final key = await attachFake(fake);
      store.upsertSession(
        SessionRecord(
          vmUri: key,
          state: 'live',
          appName: 'main',
          isolateIds: const ['isolates/main'],
          startedAt: DateTime.now().microsecondsSinceEpoch,
          disconnectedAt: null,
          disconnectReason: null,
          httpProfileAvailable: true,
        ),
      );
      for (var i = 0; i < 201; i++) {
        final written = store.files.write(
          vmUri: key,
          requestId: 'bulk-$i',
          startTime: 1000 + i,
          requestHeaders: const {},
          responseHeaders: const {},
          requestBody: null,
          responseBody: Uint8List.fromList(const [1]),
        );
        store.upsertRequest(
          RequestRecord(
            vmUri: key,
            requestId: 'bulk-$i',
            isolateId: 'isolates/main',
            method: 'GET',
            uri: 'https://example.com/bulk-$i',
            startTime: 1000 + i,
            endTime: 1100 + i,
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
      }

      final exported = mcp.exportHar(key);
      expect(exported['error'], isNull);
      expect(exported['requestCount'], 201);
      await fake.close();
    });

    test('listRequests for VM B omits VM A traffic', () async {
      final fakeA = await FakeVmService.start();
      final fakeB = await FakeVmService.start();
      fakeA.addRequest(sampleRequest(id: 'only-a', startTime: 800));
      final keyA = await attachFake(fakeA);
      final keyB = await attachFake(fakeB);

      final result = mcp.listRequests(keyB);
      final requests = result['requests'] as List<dynamic>;
      expect(requests, isEmpty);
      expect(store.listRequests(vmUri: keyA).length, 1);
      await fakeA.close();
      await fakeB.close();
    });
  });
}
