import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vm_mcp/src/dart_vm_mcp.dart';
import 'package:dart_vm_mcp/src/session_store.dart';
import 'package:dart_vm_mcp/src/tool_json.dart';
import 'package:dart_vm_mcp/src/vm_uri.dart';
import 'package:test/test.dart';

import 'support/fake_vm_service.dart';

void main() {
  late Directory tempDir;
  late String dataDir;
  late SessionStore store;
  late DartVmMcp mcp;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dart-vm-mcp-tool');
    dataDir = tempDir.path;
    store = SessionStore.open('$dataDir/network.sqlite');
    mcp = DartVmMcp(store: store, dataDirectory: dataDir);
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

  group('DartVmMcp', () {
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
      expect(item['responseBody'], {'uuid': 'abc'});
      expect(item['responseBodyEncoding'], 'json');
      expect(item['durationMs'], 0);
      expect(item.containsKey('requestBody'), isFalse);
      expect(item.containsKey('requestHeaders'), isFalse);
      expect(item.containsKey('isolateId'), isFalse);
      await fake.close();
    });

    test('attachVm uses the pubspec package name as appName', () async {
      final fake = await FakeVmService.start(
        rootLibUri: 'package:dart_vm_mcp_example/main.dart',
      );
      final result = await mcp.attachVm(fake.consoleHttpUri, inDocker: false);
      expect(result['appName'], 'dart_vm_mcp_example');
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
      expect(objectItem['requestBody'], {'title': 'a'});
      expect(objectItem['requestBodyEncoding'], 'json');
      expect(objectItem['responseBody'], {'id': 1, 'title': 'a'});
      expect(objectItem['responseBodyEncoding'], 'json');
      expect(objectItem.containsKey('requestHeaders'), isFalse);
      expect(objectItem.containsKey('responseHeaders'), isFalse);
      expect(objectItem.containsKey('isolateId'), isFalse);
      expect(objectItem.containsKey('reasonPhrase'), isFalse);
      expect(objectItem.containsKey('endTime'), isFalse);
      expect(objectItem.containsKey('requestBodySize'), isFalse);

      expect(byId['json-array']!['responseBody'], [
        {'id': 1},
      ]);
      expect(byId['json-array']!['responseBodyEncoding'], 'json');
      expect(byId['plain-text']!['responseBody'], 'not json');
      expect(byId['plain-text']!['responseBodyEncoding'], 'utf8');
      expect(byId['broken-json']!['responseBody'], '{"a":');
      expect(byId['broken-json']!['responseBodyEncoding'], 'utf8');
      expect(byId['binary']!['responseBodyEncoding'], 'base64');
      expect(
        byId['binary']!['responseBody'],
        base64Encode(const [0xFF, 0xFE]),
      );

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
      final content =
          ((objectEntry['response'] as Map)['content'] as Map);
      expect(postData['text'], '{"title":"a"}');
      expect(postData.containsKey('encoding'), isFalse);
      expect(content['text'], '{"id":1,"title":"a"}');
      expect(content['text'], isA<String>());
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
      expect(item['responseBodyTruncated'], isTrue);
      expect(item['responseBodySize'], 1000001);
      expect(item['responseBodyEncoding'], 'utf8');
      expect(item['responseBody'], isA<String>());
      expect((item['responseBody'] as String).length, 1000000);
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

    test('deleteSession keeps export har on disk', () async {
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
      expect(File(path).existsSync(), isTrue);
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
            requestHeaders: const {},
            responseHeaders: const {},
            requestBody: null,
            responseBody: Uint8List.fromList(const [1]),
            requestBodySize: 0,
            responseBodySize: 1,
            requestBodyTruncated: false,
            responseBodyTruncated: false,
            bodyUnavailable: false,
            error: null,
            rawJson: '{"id":"bulk-$i"}',
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
