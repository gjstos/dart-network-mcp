import 'dart:io';

import 'package:dart_network_mcp/src/session_store.dart';
import 'package:dart_network_mcp/src/vm_session.dart';
import 'package:dart_network_mcp/src/vm_uri.dart';
import 'package:test/test.dart';

import 'support/fake_vm_service.dart';

void main() {
  late Directory tempDir;
  late String dbPath;
  late SessionStore store;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dart-network-mcp-session');
    dbPath = '${tempDir.path}/network.sqlite';
    store = SessionStore.open(dbPath);
  });

  tearDown(() async {
    store.close();
    tempDir.deleteSync(recursive: true);
  });

  Future<VmSession> attachFake(
    FakeVmService fake, {
    Duration rpcTimeout = const Duration(seconds: 3),
  }) {
    final canonical = canonicalizeVmUri(fake.consoleHttpUri);
    return VmSession.attach(
      store: store,
      rawUri: fake.consoleHttpUri,
      socketUri: Uri.parse(canonical),
      enableTimer: false,
      rpcTimeout: rpcTimeout,
    );
  }

  FakeHttpProfileEntry sampleRequest({
    required String id,
    required int startTime,
    String isolateId = 'isolates/main',
    int statusCode = 200,
    List<int> responseBody = const [1, 2, 3],
  }) =>
      FakeHttpProfileEntry(
        id: id,
        method: 'GET',
        uri: 'https://example.com/$id',
        isolateId: isolateId,
        startTime: startTime,
        endTime: startTime + 50,
        statusCode: statusCode,
        responseBody: responseBody,
      );

  group('VmSession', () {
    test('isolates traffic by vmUri', () async {
      final fakeA = await FakeVmService.start();
      final fakeB = await FakeVmService.start();
      final sessionA = await attachFake(fakeA);
      final sessionB = await attachFake(fakeB);

      fakeA.addRequest(sampleRequest(id: 'req-a', startTime: 100));
      await sessionA.pollOnce();
      await sessionB.pollOnce();

      final keyA = canonicalizeVmUri(fakeA.consoleHttpUri);
      final keyB = canonicalizeVmUri(fakeB.consoleHttpUri);
      expect(keyA, isNot(keyB));
      expect(store.listRequests(vmUri: keyA).length, 1);
      expect(store.listRequests(vmUri: keyB), isEmpty);

      await sessionA.dispose();
      await sessionB.dispose();
      await fakeA.close();
      await fakeB.close();
    });

    test('appName is the package name from the root library', () async {
      final fake = await FakeVmService.start(
        rootLibUri: 'package:dart_network_mcp_example/main.dart',
      );
      final session = await attachFake(fake);
      final key = canonicalizeVmUri(fake.consoleHttpUri);
      expect(store.getSession(key)?.appName, 'dart_network_mcp_example');
      await session.dispose();
      await fake.close();
    });

    test('stores canonical vmUri from console http uri', () async {
      final fake = await FakeVmService.start();
      final session = await attachFake(fake);
      final key = canonicalizeVmUri(fake.consoleHttpUri);
      expect(store.getSession(key)?.vmUri, key);
      expect(store.getSession(key)?.state, 'live');
      await session.dispose();
      await fake.close();
    });

    test('socket close moves session to history and keeps requests', () async {
      final fake = await FakeVmService.start();
      final session = await attachFake(fake);
      final key = canonicalizeVmUri(fake.consoleHttpUri);
      fake.addRequest(sampleRequest(id: 'req-1', startTime: 200));
      await session.pollOnce();
      expect(store.listRequests(vmUri: key).length, 1);

      fake.closeClients();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final record = store.getSession(key);
      expect(record?.state, 'history');
      expect(record?.disconnectReason, 'socket closed');
      expect(store.listRequests(vmUri: key).length, 1);
      await session.dispose();
      await fake.close();
    });

    test('same requestId and startTime updates statusCode', () async {
      final fake = await FakeVmService.start();
      final session = await attachFake(fake);
      final key = canonicalizeVmUri(fake.consoleHttpUri);
      fake.addRequest(sampleRequest(id: 'req-u', startTime: 300, statusCode: 100));
      await session.pollOnce();
      fake.updateRequestStatus(id: 'req-u', startTime: 300, statusCode: 200);
      await session.pollOnce();

      final rows = store.findByRequestId(vmUri: key, requestId: 'req-u');
      expect(rows.length, 1);
      expect(rows.single.statusCode, 200);
      await session.dispose();
      await fake.close();
    });

    test('same requestId with different startTime creates second row', () async {
      final fake = await FakeVmService.start();
      final session = await attachFake(fake);
      final key = canonicalizeVmUri(fake.consoleHttpUri);
      fake.addRequest(sampleRequest(id: 'req-dup', startTime: 400));
      fake.addRequest(sampleRequest(id: 'req-dup', startTime: 500));
      await session.pollOnce();

      expect(store.findByRequestId(vmUri: key, requestId: 'req-dup').length, 2);
      await session.dispose();
      await fake.close();
    });

    test('closing one fake leaves the other live', () async {
      final fakeA = await FakeVmService.start();
      final fakeB = await FakeVmService.start();
      final sessionA = await attachFake(fakeA);
      final sessionB = await attachFake(fakeB);
      final keyA = canonicalizeVmUri(fakeA.consoleHttpUri);
      final keyB = canonicalizeVmUri(fakeB.consoleHttpUri);

      fakeA.closeClients();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(store.getSession(keyA)?.state, 'history');
      expect(store.getSession(keyB)?.state, 'live');
      await sessionA.dispose();
      await sessionB.dispose();
      await fakeA.close();
      await fakeB.close();
    });

    test('truncates response bodies above 1000000 bytes', () async {
      final fake = await FakeVmService.start();
      final session = await attachFake(fake);
      final key = canonicalizeVmUri(fake.consoleHttpUri);
      final bigBody = List<int>.filled(1000001, 7);
      fake.addRequest(
        sampleRequest(id: 'big', startTime: 600, responseBody: bigBody),
      );
      await session.pollOnce();

      final row = store.listRequests(vmUri: key).single;
      expect(row.responseBody?.length, 1000000);
      expect(row.responseBodyTruncated, isTrue);
      expect(row.responseBodySize, 1000001);
      await session.dispose();
      await fake.close();
    });

    test('httpAvailable false disables profile and logging', () async {
      final fake = await FakeVmService.start(httpAvailable: false);
      final session = await attachFake(fake);
      final key = canonicalizeVmUri(fake.consoleHttpUri);

      expect(store.getSession(key)?.httpProfileAvailable, isFalse);
      expect(session.loggingEnabled, isFalse);
      fake.addRequest(sampleRequest(id: 'ignored', startTime: 700));
      await session.pollOnce();
      expect(store.listRequests(vmUri: key), isEmpty);
      await session.dispose();
      await fake.close();
    });

    test('getHttpProfileRequest error sets bodyUnavailable then continues',
        () async {
      final fake = await FakeVmService.start();
      final session = await attachFake(fake);
      final key = canonicalizeVmUri(fake.consoleHttpUri);
      fake.addRequest(sampleRequest(id: 'fail-body', startTime: 800));
      fake.addRequest(sampleRequest(id: 'ok-body', startTime: 900));
      fake.failNextGetHttpProfileRequest = true;
      await session.pollOnce();

      final rows = store.listRequests(vmUri: key);
      expect(rows.length, 2);
      final failed = rows.firstWhere((r) => r.requestId == 'fail-body');
      final ok = rows.firstWhere((r) => r.requestId == 'ok-body');
      expect(failed.bodyUnavailable, isTrue);
      expect(ok.bodyUnavailable, isFalse);
      await session.dispose();
      await fake.close();
    });

    test('dispose does not mark session history', () async {
      final fake = await FakeVmService.start();
      final session = await attachFake(fake);
      final key = canonicalizeVmUri(fake.consoleHttpUri);
      fake.addRequest(sampleRequest(id: 'keep-me', startTime: 1000));
      await session.pollOnce();
      expect(store.listRequests(vmUri: key).length, 1);

      await session.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final record = store.getSession(key);
      expect(record?.state, 'live');
      expect(record?.disconnectReason, isNull);
      expect(store.listRequests(vmUri: key).length, 1);
      await fake.close();
    });

    test('enableTimer polls without manual pollOnce', () async {
      final fake = await FakeVmService.start();
      final key = canonicalizeVmUri(fake.consoleHttpUri);
      final session = await VmSession.attach(
        store: store,
        rawUri: fake.consoleHttpUri,
        socketUri: Uri.parse(key),
        enableTimer: true,
      );
      fake.addRequest(sampleRequest(id: 'timer-req', startTime: 1100));

      await Future<void>.delayed(const Duration(seconds: 2));

      expect(store.listRequests(vmUri: key).length, 1);
      expect(store.listRequests(vmUri: key).single.requestId, 'timer-req');
      await session.dispose();
      await fake.close();
    });

    test('pollOnce enables logging on new isolates from getVM', () async {
      final fake = await FakeVmService.start();
      final session = await attachFake(fake);
      final key = canonicalizeVmUri(fake.consoleHttpUri);

      fake.addVmIsolate(id: 'isolates/next', number: '2');
      fake.addRequest(
        sampleRequest(
          id: 'next-req',
          startTime: 1200,
          isolateId: 'isolates/next',
        ),
      );
      await session.pollOnce();

      expect(fake.isLoggingEnabledFor('isolates/next'), isTrue);
      expect(store.listRequests(vmUri: key).length, 1);
      expect(store.listRequests(vmUri: key).single.requestId, 'next-req');
      await session.dispose();
      await fake.close();
    });

    test('IsolateRunnable enables logging before pollOnce', () async {
      final fake = await FakeVmService.start();
      final session = await attachFake(fake);
      final key = canonicalizeVmUri(fake.consoleHttpUri);

      fake.addVmIsolate(id: 'isolates/next', number: '2');
      fake.emitIsolateEvent(
        kind: 'IsolateRunnable',
        isolateId: 'isolates/next',
        number: '2',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fake.isLoggingEnabledFor('isolates/next'), isTrue);

      fake.addRequest(
        sampleRequest(
          id: 'after-event',
          startTime: 1300,
          isolateId: 'isolates/next',
        ),
      );
      await session.pollOnce();
      expect(store.listRequests(vmUri: key).length, 1);
      expect(store.listRequests(vmUri: key).single.requestId, 'after-event');
      await session.dispose();
      await fake.close();
    });

    test('ServiceExtensionAdded enables logging before pollOnce', () async {
      final fake = await FakeVmService.start();
      final session = await attachFake(fake);
      final key = canonicalizeVmUri(fake.consoleHttpUri);

      fake.addVmIsolate(id: 'isolates/ext', number: '3');
      fake.emitIsolateEvent(
        kind: 'ServiceExtensionAdded',
        isolateId: 'isolates/ext',
        number: '3',
        extensionRPC: 'ext.dart.io.httpEnableTimelineLogging',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fake.isLoggingEnabledFor('isolates/ext'), isTrue);

      fake.addRequest(
        sampleRequest(
          id: 'after-extension',
          startTime: 1350,
          isolateId: 'isolates/ext',
        ),
      );
      await session.pollOnce();
      expect(store.listRequests(vmUri: key).single.requestId, 'after-extension');
      await session.dispose();
      await fake.close();
    });

    test('hung getHttpProfile times out and marks socket closed', () async {
      final fake = await FakeVmService.start();
      final session = await attachFake(
        fake,
        rpcTimeout: const Duration(milliseconds: 200),
      );
      final key = canonicalizeVmUri(fake.consoleHttpUri);
      fake.addRequest(sampleRequest(id: 'before-hang', startTime: 1400));
      await session.pollOnce();
      expect(store.listRequests(vmUri: key).length, 1);

      fake.hangNextGetHttpProfile = true;
      await session.pollOnce();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final record = store.getSession(key);
      expect(record?.state, 'history');
      expect(record?.disconnectReason, 'socket closed');
      await fake.close();
    });

    test('isFlutterApp reflects ext.flutter.version on isolate', () async {
      final flutterFake = await FakeVmService.start();
      final plainFake = await FakeVmService.start(extensionRpcs: []);
      final flutterSession = await attachFake(flutterFake);
      final plainSession = await attachFake(plainFake);

      expect(flutterSession.isFlutterApp, isTrue);
      expect(plainSession.isFlutterApp, isFalse);
      await flutterSession.dispose();
      await plainSession.dispose();
      await flutterFake.close();
      await plainFake.close();
    });
  });
}
