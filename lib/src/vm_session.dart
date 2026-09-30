import 'dart:async';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'session_store.dart';
import 'vm_uri.dart';

String? _packageNameFromRootLib(String? uri) {
  if (uri == null || !uri.startsWith('package:')) {
    return null;
  }
  final rest = uri.substring('package:'.length);
  final slash = rest.indexOf('/');
  if (slash <= 0) {
    return null;
  }
  return rest.substring(0, slash);
}

/// Service RPCs share the app's event loop and were seen taking 10s on a busy
/// Flutter app, so this is generous; a hung socket is caught by `onDone`.
const Duration _defaultRpcTimeout = Duration(seconds: 20);

/// A request still open after this long no longer holds back
/// `clearHttpProfile`, so a hung exchange cannot grow the VM profile forever.
const Duration _defaultInFlightTimeout = Duration(minutes: 10);

class VmSession {
  VmSession._({
    required this.store,
    required this.vmUri,
    required VmService service,
    required List<String> isolateIds,
    required bool httpProfileAvailable,
    required bool loggingEnabled,
    required bool isFlutterApp,
    required bool enableTimer,
    required Duration rpcTimeout,
    required Duration inFlightTimeout,
    required Set<String> loggingEnabledIsolateIds,
  })  : _service = service,
        _isolateIds = List<String>.from(isolateIds),
        _httpProfileAvailable = httpProfileAvailable,
        _loggingEnabled = loggingEnabled,
        _isFlutterApp = isFlutterApp,
        _enableTimer = enableTimer,
        _rpcTimeout = rpcTimeout,
        _inFlightTimeout = inFlightTimeout,
        _loggingEnabledIsolateIds = loggingEnabledIsolateIds {
    _service.onDone.then((_) {
      if (_disposed) {
        return;
      }
      store.markHistory(
        vmUri,
        'socket closed',
        DateTime.now().microsecondsSinceEpoch,
      );
    });
    if (_enableTimer) {
      _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        pollOnce();
      });
    }
  }

  final SessionStore store;
  final String vmUri;
  final VmService _service;
  final List<String> _isolateIds;
  bool _httpProfileAvailable;
  bool _loggingEnabled;
  final bool _isFlutterApp;
  final bool _enableTimer;
  final Duration _rpcTimeout;
  final Duration _inFlightTimeout;
  final Set<String> _loggingEnabledIsolateIds;
  Timer? _pollTimer;
  final Map<String, DateTime> _lastProfileTimestampByIsolate = {};
  final Map<String, Map<String, DateTime>> _inFlightByIsolate = {};
  bool _polling = false;
  bool _disposed = false;
  StreamSubscription<Event>? _isolateEventSub;

  bool get loggingEnabled => _loggingEnabled;
  bool get isFlutterApp => _isFlutterApp;

  static Future<VmSession> attach({
    required SessionStore store,
    required String rawUri,
    required Uri socketUri,
    required bool enableTimer,
    Duration rpcTimeout = _defaultRpcTimeout,
    Duration? inFlightTimeout,
  }) async {
    final vmUri = canonicalizeVmUri(rawUri);
    final service = await vmServiceConnectUri(socketUri.toString());
    final vm = await service.getVM();
    final isolateIds = vm.isolates?.map((i) => i.id!).toList() ?? <String>[];
    final rootName = vm.isolates?.isNotEmpty == true
        ? vm.isolates!.first.name ?? 'main'
        : 'main';
    var appName = rootName;

    var httpProfileAvailable = false;
    var loggingEnabled = false;
    var isFlutterApp = false;
    final loggingEnabledIsolateIds = <String>{};

    for (final isolateId in isolateIds) {
      final isolate = await service.getIsolate(isolateId);
      if (appName == rootName) {
        final packageName = _packageNameFromRootLib(isolate.rootLib?.uri);
        if (packageName != null) {
          appName = packageName;
        }
      }
      final rpcs = isolate.extensionRPCs ?? <String>[];
      if (rpcs.contains('ext.flutter.version')) {
        isFlutterApp = true;
      }
      if (await service.isHttpProfilingAvailable(isolateId)) {
        httpProfileAvailable = true;
        await service.httpEnableTimelineLogging(isolateId, true);
        loggingEnabledIsolateIds.add(isolateId);
        loggingEnabled = true;
      }
    }

    await service.streamListen('Isolate');

    store.upsertSession(
      SessionRecord(
        vmUri: vmUri,
        state: 'live',
        appName: appName,
        isolateIds: isolateIds,
        startedAt: DateTime.now().microsecondsSinceEpoch,
        disconnectedAt: null,
        disconnectReason: null,
        httpProfileAvailable: httpProfileAvailable,
      ),
    );

    final session = VmSession._(
      store: store,
      vmUri: vmUri,
      service: service,
      isolateIds: isolateIds,
      httpProfileAvailable: httpProfileAvailable,
      loggingEnabled: loggingEnabled,
      isFlutterApp: isFlutterApp,
      enableTimer: enableTimer,
      rpcTimeout: rpcTimeout,
      inFlightTimeout: inFlightTimeout ?? _defaultInFlightTimeout,
      loggingEnabledIsolateIds: loggingEnabledIsolateIds,
    );
    session._listenIsolateStream();
    return session;
  }

  void _listenIsolateStream() {
    _isolateEventSub = _service.onEvent('Isolate').listen((event) {
      final kind = event.kind;
      final isolateId = event.isolate?.id;
      if (isolateId == null) {
        return;
      }
      final extensionReady = kind == EventKind.kServiceExtensionAdded &&
          event.extensionRPC == 'ext.dart.io.httpEnableTimelineLogging';
      if (extensionReady) {
        unawaited(_enableHttpLogging(isolateId, assumeAvailable: true));
        return;
      }
      if (kind == EventKind.kIsolateRunnable ||
          kind == EventKind.kIsolateStart) {
        unawaited(_enableHttpLogging(isolateId));
      }
    });
  }

  Future<T> _rpc<T>(Future<T> Function() call) {
    return call().timeout(_rpcTimeout);
  }

  Future<void> _enableHttpLogging(
    String isolateId, {
    bool assumeAvailable = false,
  }) async {
    if (_disposed || _loggingEnabledIsolateIds.contains(isolateId)) {
      return;
    }
    try {
      if (!assumeAvailable &&
          !await _rpc(() => _service.isHttpProfilingAvailable(isolateId))) {
        return;
      }
      await _rpc(() => _service.httpEnableTimelineLogging(isolateId, true));
      _loggingEnabledIsolateIds.add(isolateId);
      if (!_isolateIds.contains(isolateId)) {
        _isolateIds.add(isolateId);
      }
    } on TimeoutException {
      return;
    } catch (_) {
      return;
    }
  }

  Future<void> _handleConnectionFailure() async {
    if (_disposed) {
      return;
    }
    try {
      store.markHistory(
        vmUri,
        'socket closed',
        DateTime.now().microsecondsSinceEpoch,
      );
    } catch (_) {}
    await dispose();
  }

  Future<void> pollOnce() async {
    if (_disposed || _polling) {
      return;
    }
    _polling = true;
    try {
      final vm = await _rpc(() => _service.getVM());
      final currentIds = vm.isolates?.map((i) => i.id!).toList() ?? <String>[];
      _isolateIds
        ..clear()
        ..addAll(currentIds);

      for (final isolateId in List<String>.from(_isolateIds)) {
        try {
          await _pollIsolate(isolateId);
        } on TimeoutException {
          // A busy app answers slowly; retry on the next poll.
        } on RPCError catch (e) {
          if (e.code == RPCErrorKind.kConnectionDisposed.code) {
            rethrow;
          }
          // The isolate went away mid-poll; the others are still fine.
        } on SentinelException {
          // Same: isolate collected between getVM and the profile call.
        }
      }
    } on TimeoutException {
      // Same as above: only `onDone` proves the socket is gone.
    } catch (e) {
      stderr.writeln('poll failed, dropping session $vmUri: $e');
      await _handleConnectionFailure();
    } finally {
      _polling = false;
    }
  }

  Future<void> _pollIsolate(String isolateId) async {
    if (!await _rpc(() => _service.isHttpProfilingAvailable(isolateId))) {
      return;
    }
    if (!_httpProfileAvailable) {
      _httpProfileAvailable = true;
      _markHttpProfileAvailable();
    }
    if (!_loggingEnabledIsolateIds.contains(isolateId)) {
      await _rpc(() => _service.httpEnableTimelineLogging(isolateId, true));
      _loggingEnabledIsolateIds.add(isolateId);
      _loggingEnabled = true;
    }
    final lastTimestamp = _lastProfileTimestampByIsolate[isolateId];
    var profile = await _rpc(
      () => _service.getHttpProfile(isolateId, updatedSince: lastTimestamp),
    );
    if (lastTimestamp != null && profile.timestamp.isBefore(lastTimestamp)) {
      profile = await _rpc(() => _service.getHttpProfile(isolateId));
    }
    final inFlight = _inFlightByIsolate[isolateId] ??= {};
    var needsRetry = false;
    for (final ref in profile.requests) {
      if (_completedAt(ref) == null) {
        inFlight.putIfAbsent(ref.id, DateTime.now);
      } else {
        inFlight.remove(ref.id);
      }
      try {
        if (!await _persistRequest(isolateId, ref)) {
          needsRetry = true;
        }
      } catch (e) {
        stderr.writeln('persist failed for ${ref.method} ${ref.uri}: $e');
        needsRetry = true;
      }
    }
    if (!needsRetry) {
      _lastProfileTimestampByIsolate[isolateId] = profile.timestamp;
    }
    final now = DateTime.now();
    inFlight.removeWhere((_, seen) => now.difference(seen) >= _inFlightTimeout);
    if (!needsRetry && inFlight.isEmpty) {
      try {
        await _rpc(() => _service.clearHttpProfile(isolateId));
      } catch (_) {}
    }
  }

  void _markHttpProfileAvailable() {
    final record = store.getSession(vmUri);
    if (record == null) {
      return;
    }
    store.upsertSession(
      SessionRecord(
        vmUri: record.vmUri,
        state: record.state,
        appName: record.appName,
        isolateIds: record.isolateIds,
        startedAt: record.startedAt,
        disconnectedAt: record.disconnectedAt,
        disconnectReason: record.disconnectReason,
        httpProfileAvailable: true,
      ),
    );
  }

  /// Returns `false` when the request body could not be fetched, so the
  /// caller retries it on the next poll instead of settling for a partial row.
  Future<bool> _persistRequest(String isolateId, HttpProfileRequest ref) async {
    HttpProfileRequest? full;
    var bodyUnavailable = false;
    try {
      full =
          await _rpc(() => _service.getHttpProfileRequest(isolateId, ref.id));
    } on TimeoutException {
      bodyUnavailable = true;
      full = null;
    } catch (_) {
      bodyUnavailable = true;
      full = null;
    }

    final requestData = full?.request ?? ref.request;
    final responseData = ref.response ?? full?.response;

    final requestHeaders = _stringHeaders(requestData?.headers);
    final responseHeaders = _stringHeaders(responseData?.headers);

    final requestBody = full?.requestBody;
    final responseBody = full?.responseBody;

    final startTime = ref.startTime.microsecondsSinceEpoch;
    final written = store.files.write(
      vmUri: vmUri,
      requestId: ref.id,
      startTime: startTime,
      requestHeaders: requestHeaders,
      responseHeaders: responseHeaders,
      requestBody: requestBody,
      responseBody: responseBody,
    );

    // Without a fresh body fetch, keep what an earlier poll already stored.
    final prior = bodyUnavailable
        ? store
            .findByRequestId(vmUri: vmUri, requestId: ref.id)
            .where((r) => r.startTime == startTime)
            .firstOrNull
        : null;

    store.upsertRequest(
      RequestRecord(
        vmUri: vmUri,
        requestId: ref.id,
        isolateId: isolateId,
        method: ref.method,
        uri: ref.uri.toString(),
        startTime: ref.startTime.microsecondsSinceEpoch,
        endTime: _completedAt(ref)?.microsecondsSinceEpoch,
        statusCode: responseData?.statusCode,
        reasonPhrase: responseData?.reasonPhrase,
        headersPath: written.headersPath,
        requestBodyPath: prior?.requestBodyPath ?? written.requestBodyPath,
        responseBodyPath: prior?.responseBodyPath ?? written.responseBodyPath,
        requestBodySize: prior?.requestBodySize ?? written.requestBodySize,
        responseBodySize: prior?.responseBodySize ?? written.responseBodySize,
        bodyUnavailable: bodyUnavailable,
        error: responseData?.error ?? requestData?.error,
      ),
    );
    return !bodyUnavailable;
  }

  /// `HttpProfileRequest.endTime` only marks the request being sent; the
  /// exchange is over once the response finished, or the request failed.
  DateTime? _completedAt(HttpProfileRequest ref) {
    final responseEnd = ref.response?.endTime;
    if (responseEnd != null) {
      return responseEnd;
    }
    final failed = ref.request?.error != null || ref.response?.error != null;
    return failed ? ref.endTime : null;
  }

  Map<String, String> _stringHeaders(Map<String, dynamic>? headers) {
    if (headers == null) {
      return {};
    }
    return headers.map((key, value) => MapEntry(key, value.toString()));
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _pollTimer?.cancel();
    await _isolateEventSub?.cancel();
    await _service.dispose();
  }
}
