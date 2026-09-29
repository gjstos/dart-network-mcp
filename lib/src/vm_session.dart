import 'dart:async';

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
const Duration _defaultRpcTimeout = Duration(seconds: 3);

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
    required Set<String> loggingEnabledIsolateIds,
  })  : _service = service,
        _isolateIds = List<String>.from(isolateIds),
        _httpProfileAvailable = httpProfileAvailable,
        _loggingEnabled = loggingEnabled,
        _isFlutterApp = isFlutterApp,
        _enableTimer = enableTimer,
        _rpcTimeout = rpcTimeout,
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
  final bool _httpProfileAvailable;
  final bool _loggingEnabled;
  final bool _isFlutterApp;
  final bool _enableTimer;
  final Duration _rpcTimeout;
  final Set<String> _loggingEnabledIsolateIds;
  Timer? _pollTimer;
  final Map<String, DateTime> _lastProfileTimestampByIsolate = {};
  final Map<String, Set<String>> _inFlightByIsolate = {};
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
    if (!_httpProfileAvailable || _disposed) {
      return;
    }
    try {
      final vm = await _rpc(() => _service.getVM());
      final currentIds = vm.isolates?.map((i) => i.id!).toList() ?? <String>[];
      _isolateIds
        ..clear()
        ..addAll(currentIds);

      for (final isolateId in List<String>.from(_isolateIds)) {
        if (!await _rpc(() => _service.isHttpProfilingAvailable(isolateId))) {
          continue;
        }
        if (!_loggingEnabledIsolateIds.contains(isolateId)) {
          await _rpc(() => _service.httpEnableTimelineLogging(isolateId, true));
          _loggingEnabledIsolateIds.add(isolateId);
        }
        final lastTimestamp = _lastProfileTimestampByIsolate[isolateId];
        var profile = await _rpc(
          () => _service.getHttpProfile(
            isolateId,
            updatedSince: lastTimestamp,
          ),
        );
        if (lastTimestamp != null &&
            profile.timestamp.isBefore(lastTimestamp)) {
          profile = await _rpc(() => _service.getHttpProfile(isolateId));
        }
        final inFlight = _inFlightByIsolate[isolateId] ??= {};
        var anyPersistFailed = false;
        for (final ref in profile.requests) {
          if (ref.endTime == null) {
            inFlight.add(ref.id);
          } else {
            inFlight.remove(ref.id);
          }
          try {
            await _persistRequest(isolateId, ref);
          } catch (_) {
            anyPersistFailed = true;
          }
        }
        if (!anyPersistFailed) {
          _lastProfileTimestampByIsolate[isolateId] = profile.timestamp;
        }
        if (!anyPersistFailed && inFlight.isEmpty) {
          try {
            await _rpc(() => _service.clearHttpProfile(isolateId));
          } on TimeoutException {
            rethrow;
          } catch (_) {}
        }
      }
    } on TimeoutException {
      await _handleConnectionFailure();
    } catch (_) {
      await _handleConnectionFailure();
    }
  }

  Future<void> _persistRequest(String isolateId, HttpProfileRequest ref) async {
    HttpProfileRequest? full;
    var bodyUnavailable = false;
    try {
      full = await _rpc(() => _service.getHttpProfileRequest(isolateId, ref.id));
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

    var requestBody = full?.requestBody;
    var responseBody = full?.responseBody;
    final requestBodySize = requestBody?.length ?? 0;
    final responseBodySize = responseBody?.length ?? 0;

    final written = store.files.write(
      vmUri: vmUri,
      requestId: ref.id,
      startTime: ref.startTime.microsecondsSinceEpoch,
      requestHeaders: requestHeaders,
      responseHeaders: responseHeaders,
      requestBody: requestBody,
      responseBody: responseBody,
    );

    store.upsertRequest(
      RequestRecord(
        vmUri: vmUri,
        requestId: ref.id,
        isolateId: isolateId,
        method: ref.method,
        uri: ref.uri.toString(),
        startTime: ref.startTime.microsecondsSinceEpoch,
        endTime: ref.endTime?.microsecondsSinceEpoch,
        statusCode: responseData?.statusCode,
        reasonPhrase: responseData?.reasonPhrase,
        headersPath: written.headersPath,
        requestBodyPath: written.requestBodyPath,
        responseBodyPath: written.responseBodyPath,
        requestBodySize: requestBodySize,
        responseBodySize: responseBodySize,
        bodyUnavailable: bodyUnavailable,
        error: responseData?.error ?? requestData?.error,
      ),
    );
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
