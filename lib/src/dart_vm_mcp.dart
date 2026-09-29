import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'devtools_export.dart';
import 'har_export.dart';
import 'session_store.dart';
import 'tool_json.dart';
import 'vm_session.dart';
import 'vm_uri.dart';

class DartVmMcp {
  DartVmMcp({
    required this.store,
    required this.dataDirectory,
    this.version = '0.1.0',
  });

  final SessionStore store;
  final String dataDirectory;
  final String version;

  final Map<String, VmSession> _liveSessions = {};

  Future<void> dispose() async {
    for (final session in _liveSessions.values.toList()) {
      await session.dispose();
    }
    _liveSessions.clear();
  }

  Future<void> disposeLiveSession(String vmUri) async {
    final key = _canonicalKeyOrError(vmUri);
    if (key.canonical == null) {
      return;
    }
    final live = _liveSessions.remove(key.canonical);
    await live?.dispose();
  }

  Map<String, Object?> listSessions({String state = 'live'}) {
    return _runStore(() {
      final sessions = store.listSessions(state);
      final result = <String, Object?>{
        'sessions': sessions.map(_sessionSummary).toList(),
      };
      if (state == 'live') {
        final live = store.listSessions('live');
        if (live.isEmpty) {
          final history = store.listSessions('history');
          if (history.isNotEmpty) {
            final sorted = [...history];
            sorted.sort(
              (a, b) =>
                  (b.disconnectedAt ?? 0).compareTo(a.disconnectedAt ?? 0),
            );
            result['historyHint'] = <String, Object?>{
              'vmUris': sorted.take(5).map((s) => s.vmUri).toList(),
            };
          }
        }
      }
      return result;
    });
  }

  Map<String, Object?> getSession(String vmUri) {
    final key = _canonicalKeyOrError(vmUri);
    if (key.error != null) {
      return key.error!;
    }
    return _runStore(() {
      final session = store.getSession(key.canonical!);
      if (session == null) {
        return toolError(
          'vm_not_found',
          'Session not found',
          vmUri: key.canonical,
        );
      }
      return _sessionDetail(session);
    });
  }

  Future<Map<String, Object?>> attachVm(
    String uri, {
    required bool inDocker,
  }) async {
    final String canonical;
    try {
      canonical = canonicalizeVmUri(uri);
    } on FormatException {
      return toolError('attach_failed', 'Attach failed', vmUri: uri);
    }

    if (_liveSessions.containsKey(canonical)) {
      final record = store.getSession(canonical);
      if (record != null && record.state == 'live') {
        return _withSessionContext(record);
      }
      final stale = _liveSessions.remove(canonical);
      await stale?.dispose();
    }

    final beforeAttach = store.getSession(canonical);
    final socketUri = socketUriFor(Uri.parse(canonical), inDocker: inDocker);
    VmSession? session;
    try {
      session = await VmSession.attach(
        store: store,
        rawUri: uri,
        socketUri: socketUri,
        enableTimer: true,
      );
      await session.pollOnce();
      _liveSessions[canonical] = session;
      final record = store.getSession(canonical);
      if (record == null) {
        await _rollbackAttach(canonical, session, beforeAttach);
        return toolError('attach_failed', 'Attach failed', vmUri: canonical);
      }
      return _withSessionContext(record);
    } on SqliteException catch (e) {
      await _rollbackAttach(canonical, session, beforeAttach);
      if (e.message.contains('database is locked')) {
        return toolError('sqlite_busy', 'Database is busy');
      }
      rethrow;
    } catch (_) {
      await _rollbackAttach(canonical, session, beforeAttach);
      return toolError('attach_failed', 'Attach failed', vmUri: canonical);
    }
  }

  Map<String, Object?> listRequests(
    String vmUri, {
    bool includeHistory = false,
    int? limit,
    int? offset,
    String? method,
    int? status,
    String? urlContains,
  }) {
    final key = _canonicalKeyOrError(vmUri);
    if (key.error != null) {
      return key.error!;
    }
    vmUri = key.canonical!;
    return _runStore(() {
      final guard = _trafficGuard(vmUri, includeHistory);
      if (guard != null) {
        return guard;
      }
      final record = store.getSession(vmUri)!;
      final effectiveLimit = _clampLimit(limit);
      final effectiveOffset = offset ?? 0;
      final requests = store
          .listRequests(
            vmUri: vmUri,
            limit: effectiveLimit,
            offset: effectiveOffset,
            method: method,
            status: status,
            urlContains: urlContains,
          )
          .map(_requestListItem)
          .toList();
      return {
        'vmUri': vmUri,
        'state': record.state,
        'requests': requests,
      };
    });
  }

  Map<String, Object?> getRequest(
    String vmUri,
    String requestId, {
    int? startTime,
    bool includeHistory = false,
  }) {
    final key = _canonicalKeyOrError(vmUri);
    if (key.error != null) {
      return key.error!;
    }
    vmUri = key.canonical!;
    return _runStore(() {
      final guard = _trafficGuard(vmUri, includeHistory);
      if (guard != null) {
        return guard;
      }
      final record = store.getSession(vmUri)!;
      final rows = store.findByRequestId(vmUri: vmUri, requestId: requestId);
      if (rows.isEmpty) {
        return toolError(
          'request_not_found',
          'Request not found',
          vmUri: vmUri,
        );
      }
      if (startTime == null && rows.length > 1) {
        return {
          'error': <String, Object?>{
            'code': 'ambiguous_request',
            'message': 'Multiple requests share this id',
            'vmUri': vmUri,
            'startTimes': rows.map((r) => r.startTime).toList(),
          },
        };
      }
      final RequestRecord row;
      if (startTime != null) {
        final match = rows.where((r) => r.startTime == startTime).toList();
        if (match.isEmpty) {
          return toolError(
            'request_not_found',
            'Request not found',
            vmUri: vmUri,
          );
        }
        row = match.single;
      } else {
        row = rows.single;
      }
      return {
        'vmUri': vmUri,
        'state': record.state,
        'request': _requestDetail(row),
      };
    });
  }

  Map<String, Object?> exportHar(
    String vmUri, {
    bool includeHistory = false,
  }) {
    final key = _canonicalKeyOrError(vmUri);
    if (key.error != null) {
      return key.error!;
    }
    return _export(
      vmUri: key.canonical!,
      includeHistory: includeHistory,
      extension: 'har',
      build: (requests, isFlutterApp) =>
          buildHar(requests, version: version),
    );
  }

  Map<String, Object?> exportDevToolsJson(
    String vmUri, {
    bool includeHistory = false,
  }) {
    final key = _canonicalKeyOrError(vmUri);
    if (key.error != null) {
      return key.error!;
    }
    return _export(
      vmUri: key.canonical!,
      includeHistory: includeHistory,
      extension: 'json',
      build: (requests, isFlutterApp) => buildDevToolsSnapshot(
        requests,
        version: version,
        isFlutterApp: isFlutterApp,
      ),
    );
  }

  Future<Map<String, Object?>> deleteSession(String vmUri) async {
    final key = _canonicalKeyOrError(vmUri);
    if (key.error != null) {
      return key.error!;
    }
    vmUri = key.canonical!;
    return _runStoreAsync(() async {
      final session = store.getSession(vmUri);
      if (session == null) {
        return toolError('vm_not_found', 'Session not found', vmUri: vmUri);
      }
      final state = session.state;
      final live = _liveSessions.remove(vmUri);
      if (live != null) {
        await live.dispose();
      }
      store.deleteSession(vmUri);
      return {'vmUri': vmUri, 'state': state, 'deleted': true};
    });
  }

  Map<String, Object?> _export({
    required String vmUri,
    required bool includeHistory,
    required String extension,
    required Map<String, Object?> Function(
      List<RequestRecord> requests,
      bool isFlutterApp,
    )
        build,
  }) {
    return _runStore(() {
      final guard = _trafficGuard(vmUri, includeHistory);
      if (guard != null) {
        return guard;
      }
      final record = store.getSession(vmUri)!;
      final requests = _allStoredRequests(vmUri);
      final isFlutterApp = _liveSessions[vmUri]?.isFlutterApp ?? false;
      final document = build(requests, isFlutterApp);
      final path = _writeExportFile(
        vmUri: vmUri,
        extension: extension,
        contents: jsonEncode(document),
      );
      final bytes = File(path).lengthSync();
      return {
        'path': path,
        'requestCount': requests.length,
        'bytes': bytes,
        'vmUri': vmUri,
        'state': record.state,
      };
    });
  }

  String _writeExportFile({
    required String vmUri,
    required String extension,
    required String contents,
  }) {
    final exportsDir = Directory('$dataDirectory/exports');
    exportsDir.createSync(recursive: true);
    final stamp = _exportTimestamp();
    final hash = sha1.convert(utf8.encode(vmUri)).toString().substring(0, 8);
    final fileName = 'dart_vm_mcp_${stamp}_$hash.$extension';
    final path = '${exportsDir.path}/$fileName';
    File(path).writeAsStringSync(contents);
    return path;
  }

  String _exportTimestamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}T'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  Map<String, Object?>? _trafficGuard(String vmUri, bool includeHistory) {
    final session = store.getSession(vmUri);
    if (session == null) {
      return toolError('vm_not_found', 'Session not found', vmUri: vmUri);
    }
    if (session.state == 'history' && !includeHistory) {
      return toolError(
        'history_requires_flag',
        'includeHistory is required for history sessions',
        vmUri: vmUri,
      );
    }
    if (!session.httpProfileAvailable) {
      return toolError(
        'http_profile_unavailable',
        'HTTP profiling is not available for this session',
        vmUri: vmUri,
      );
    }
    return null;
  }

  Map<String, Object?> _withSessionContext(SessionRecord record) {
    return {
      'vmUri': record.vmUri,
      'state': record.state,
      'appName': record.appName,
      'httpProfileAvailable': record.httpProfileAvailable,
    };
  }

  Map<String, Object?> _sessionDetail(SessionRecord session) {
    return {
      'vmUri': session.vmUri,
      'appName': session.appName,
      'isolates': session.isolateIds,
      'state': session.state,
      'disconnectReason': session.disconnectReason,
      'httpProfileAvailable': session.httpProfileAvailable,
    };
  }

  Map<String, Object?> _sessionSummary(SessionRecord session) {
    return {
      'vmUri': session.vmUri,
      'state': session.state,
      'appName': session.appName,
      'httpProfileAvailable': session.httpProfileAvailable,
    };
  }

  Map<String, Object?> _requestListItem(RequestRecord record) {
    final end = record.endTime;
    final durationMs = end == null ? null : (end - record.startTime) ~/ 1000;
    return {
      'requestId': record.requestId,
      'startTime': record.startTime,
      'method': record.method,
      'uri': record.uri,
      'statusCode': record.statusCode,
      if (durationMs != null) 'durationMs': durationMs,
      if (record.requestBodyTruncated) 'requestBodyTruncated': true,
      if (record.requestBodyTruncated) 'requestBodySize': record.requestBodySize,
      if (record.responseBodyTruncated) 'responseBodyTruncated': true,
      if (record.responseBodyTruncated) 'responseBodySize': record.responseBodySize,
      if (record.bodyUnavailable) 'bodyUnavailable': true,
      if (record.error != null) 'error': record.error,
      ..._bodyFields('request', _nonEmptyBody(record.requestBody)),
      ..._bodyFields('response', record.responseBody),
    };
  }

  Uint8List? _nonEmptyBody(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    return bytes;
  }

  Map<String, Object?> _requestDetail(RequestRecord record) {
    return {
      'requestId': record.requestId,
      'isolateId': record.isolateId,
      'method': record.method,
      'uri': record.uri,
      'startTime': record.startTime,
      if (record.endTime != null) 'endTime': record.endTime,
      'statusCode': record.statusCode,
      'reasonPhrase': record.reasonPhrase,
      'requestHeaders': record.requestHeaders,
      'responseHeaders': record.responseHeaders,
      'requestBodySize': record.requestBodySize,
      'responseBodySize': record.responseBodySize,
      'requestBodyTruncated': record.requestBodyTruncated,
      'responseBodyTruncated': record.responseBodyTruncated,
      'bodyUnavailable': record.bodyUnavailable,
      if (record.error != null) 'error': record.error,
      ..._bodyFields('request', record.requestBody),
      ..._bodyFields('response', record.responseBody),
    };
  }

  Map<String, Object?> _bodyFields(String prefix, Uint8List? bytes) {
    if (bytes == null) {
      return {};
    }
    String text;
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } catch (_) {
      return {
        '${prefix}Body': base64Encode(bytes),
        '${prefix}BodyEncoding': 'base64',
      };
    }
    try {
      return {
        '${prefix}Body': jsonDecode(text),
        '${prefix}BodyEncoding': 'json',
      };
    } on FormatException {
      return {
        '${prefix}Body': text,
        '${prefix}BodyEncoding': 'utf8',
      };
    }
  }

  Future<void> _rollbackAttach(
    String canonical,
    VmSession? session,
    SessionRecord? beforeAttach,
  ) async {
    _liveSessions.remove(canonical);
    if (session == null) {
      return;
    }
    await session.dispose();
    if (beforeAttach == null) {
      store.deleteSession(canonical);
    } else {
      store.upsertSession(beforeAttach);
    }
  }

  List<RequestRecord> _allStoredRequests(String vmUri) {
    const pageSize = 200;
    final all = <RequestRecord>[];
    var offset = 0;
    while (true) {
      final page = store.listRequests(
        vmUri: vmUri,
        limit: pageSize,
        offset: offset,
      );
      if (page.isEmpty) {
        break;
      }
      all.addAll(page);
      if (page.length < pageSize) {
        break;
      }
      offset += page.length;
    }
    return all;
  }

  ({Map<String, Object?>? error, String? canonical}) _canonicalKeyOrError(
    String vmUri,
  ) {
    try {
      return (error: null, canonical: canonicalizeVmUri(vmUri));
    } on FormatException {
      return (
        error: toolError('vm_not_found', 'Session not found', vmUri: vmUri),
        canonical: null,
      );
    }
  }

  int _clampLimit(int? limit) {
    final value = limit ?? 50;
    if (value < 1) {
      return 1;
    }
    if (value > 200) {
      return 200;
    }
    return value;
  }

  Map<String, Object?> _runStore(Map<String, Object?> Function() action) {
    try {
      return action();
    } on SqliteException catch (e) {
      if (e.message.contains('database is locked')) {
        return toolError('sqlite_busy', 'Database is busy');
      }
      rethrow;
    }
  }

  Future<Map<String, Object?>> _runStoreAsync(
    Future<Map<String, Object?>> Function() action,
  ) async {
    try {
      return await action();
    } on SqliteException catch (e) {
      if (e.message.contains('database is locked')) {
        return toolError('sqlite_busy', 'Database is busy');
      }
      rethrow;
    }
  }
}
