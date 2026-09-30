import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'traffic_files.dart';

class SessionRecord {
  SessionRecord({
    required this.vmUri,
    required this.state,
    required this.appName,
    required this.isolateIds,
    required this.startedAt,
    required this.disconnectedAt,
    required this.disconnectReason,
    required this.httpProfileAvailable,
  });

  final String vmUri;
  final String state;
  final String appName;
  final List<String> isolateIds;
  final int startedAt;
  final int? disconnectedAt;
  final String? disconnectReason;
  final bool httpProfileAvailable;
}

class RequestRecord {
  RequestRecord({
    required this.vmUri,
    required this.requestId,
    required this.isolateId,
    required this.method,
    required this.uri,
    required this.startTime,
    required this.endTime,
    required this.statusCode,
    required this.reasonPhrase,
    required this.headersPath,
    required this.requestBodyPath,
    required this.responseBodyPath,
    required this.requestBodySize,
    required this.responseBodySize,
    required this.bodyUnavailable,
    required this.error,
  });

  final String vmUri;
  final String requestId;
  final String isolateId;
  final String method;
  final String uri;
  final int startTime;
  final int? endTime;
  final int? statusCode;
  final String? reasonPhrase;
  final String headersPath;
  final String? requestBodyPath;
  final String? responseBodyPath;
  final int requestBodySize;
  final int responseBodySize;
  final bool bodyUnavailable;
  final String? error;
}

class SessionStore {
  SessionStore._(this._db, this.files);

  final Database _db;
  final TrafficFileStore files;

  static const _requestsTableSql = '''
CREATE TABLE IF NOT EXISTS requests (
  vm_uri TEXT NOT NULL,
  request_id TEXT NOT NULL,
  isolate_id TEXT NOT NULL,
  method TEXT NOT NULL,
  uri TEXT NOT NULL,
  start_time INTEGER NOT NULL,
  end_time INTEGER,
  status_code INTEGER,
  reason_phrase TEXT,
  headers_path TEXT NOT NULL,
  request_body_path TEXT,
  response_body_path TEXT,
  request_body_size INTEGER NOT NULL,
  response_body_size INTEGER NOT NULL,
  body_unavailable INTEGER NOT NULL,
  error TEXT,
  PRIMARY KEY (vm_uri, request_id, start_time),
  FOREIGN KEY (vm_uri) REFERENCES sessions(vm_uri) ON DELETE CASCADE
)
''';

  static SessionStore open(
    String databasePath, {
    required String dataDirectory,
    TrafficFileStore? files,
  }) {
    final fileStore = files ?? TrafficFiles(dataDirectory);
    final db = sqlite3.open(databasePath);
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA busy_timeout=5000');
    db.execute('PRAGMA foreign_keys=ON');
    db.execute('''
CREATE TABLE IF NOT EXISTS sessions (
  vm_uri TEXT PRIMARY KEY,
  state TEXT NOT NULL,
  app_name TEXT NOT NULL,
  isolate_ids TEXT NOT NULL,
  started_at INTEGER NOT NULL,
  disconnected_at INTEGER,
  disconnect_reason TEXT,
  http_profile_available INTEGER NOT NULL
)
''');
    _migrateRequestsIfNeeded(db, fileStore);
    db.execute(_requestsTableSql);
    db.execute('CREATE TABLE IF NOT EXISTS retention (days INTEGER NOT NULL)');
    final retentionCount = db.select('SELECT COUNT(*) AS c FROM retention').first['c'] as int;
    if (retentionCount == 0) {
      db.execute('INSERT INTO retention(days) VALUES (90)');
    }
    return SessionStore._(db, fileStore);
  }

  static void _migrateRequestsIfNeeded(Database db, TrafficFileStore files) {
    final columns = _tableColumns(db, 'requests');
    if (!columns.contains('raw_json')) {
      return;
    }
    db.execute('BEGIN');
    try {
      db.execute('DROP TABLE IF EXISTS requests_new');
      db.execute(_requestsTableSql.replaceFirst(
        'CREATE TABLE IF NOT EXISTS requests',
        'CREATE TABLE requests_new',
      ));
      final insert = db.prepare('''
INSERT INTO requests_new (
  vm_uri, request_id, isolate_id, method, uri, start_time, end_time,
  status_code, reason_phrase, headers_path, request_body_path, response_body_path,
  request_body_size, response_body_size, body_unavailable, error
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
''');
      try {
        for (final row in db.select('SELECT * FROM requests')) {
          final written = files.write(
            vmUri: row['vm_uri']! as String,
            requestId: row['request_id']! as String,
            startTime: row['start_time']! as int,
            requestHeaders: _decodeStringMap(row['request_headers']! as String),
            responseHeaders: _decodeStringMap(row['response_headers']! as String),
            requestBody: _readBlob(row['request_body']),
            responseBody: _readBlob(row['response_body']),
          );
          insert.execute([
            row['vm_uri'],
            row['request_id'],
            row['isolate_id'],
            row['method'],
            row['uri'],
            row['start_time'],
            row['end_time'],
            row['status_code'],
            row['reason_phrase'],
            written.headersPath,
            written.requestBodyPath,
            written.responseBodyPath,
            row['request_body_size'],
            row['response_body_size'],
            row['body_unavailable'],
            row['error'],
          ]);
        }
      } finally {
        insert.dispose();
      }
      db.execute('DROP TABLE requests');
      db.execute('ALTER TABLE requests_new RENAME TO requests');
      db.execute('COMMIT');
    } catch (e) {
      try {
        db.execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    }
  }

  static List<String> _tableColumns(Database db, String table) {
    return db
        .select('PRAGMA table_info($table)')
        .map((row) => row['name']! as String)
        .toList();
  }

  List<String> debugTableInfo(String table) => _tableColumns(_db, table);

  void close() {
    _db.dispose();
  }

  void upsertSession(SessionRecord session) {
    final stmt = _db.prepare('''
INSERT INTO sessions (
  vm_uri, state, app_name, isolate_ids, started_at,
  disconnected_at, disconnect_reason, http_profile_available
) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(vm_uri) DO UPDATE SET
  state = excluded.state,
  app_name = excluded.app_name,
  isolate_ids = excluded.isolate_ids,
  started_at = excluded.started_at,
  disconnected_at = excluded.disconnected_at,
  disconnect_reason = excluded.disconnect_reason,
  http_profile_available = excluded.http_profile_available
''');
    try {
      stmt.execute([
        session.vmUri,
        session.state,
        session.appName,
        jsonEncode(session.isolateIds),
        session.startedAt,
        session.disconnectedAt,
        session.disconnectReason,
        session.httpProfileAvailable ? 1 : 0,
      ]);
    } finally {
      stmt.dispose();
    }
  }

  SessionRecord? getSession(String vmUri) {
    final result = _db.select(
      'SELECT * FROM sessions WHERE vm_uri = ?',
      [vmUri],
    );
    if (result.isEmpty) {
      return null;
    }
    return _sessionFromRow(result.first);
  }

  List<SessionRecord> listSessions(String state) {
    final String sql;
    final List<Object?> args;
    switch (state) {
      case 'live':
        sql = 'SELECT * FROM sessions WHERE state = ? ORDER BY started_at';
        args = ['live'];
      case 'history':
        sql = 'SELECT * FROM sessions WHERE state = ? ORDER BY started_at';
        args = ['history'];
      case 'all':
        sql = 'SELECT * FROM sessions ORDER BY started_at';
        args = [];
      default:
        throw ArgumentError.value(state, 'state', 'must be live, history, or all');
    }
    return _db.select(sql, args).map(_sessionFromRow).toList();
  }

  void markHistory(String vmUri, String reason, int disconnectedAt) {
    final stmt = _db.prepare('''
UPDATE sessions SET
  state = 'history',
  disconnect_reason = ?,
  disconnected_at = ?
WHERE vm_uri = ?
''');
    try {
      stmt.execute([reason, disconnectedAt, vmUri]);
    } finally {
      stmt.dispose();
    }
  }

  void deleteSession(String vmUri) {
    final stmt = _db.prepare('DELETE FROM sessions WHERE vm_uri = ?');
    try {
      stmt.execute([vmUri]);
    } finally {
      stmt.dispose();
    }
  }

  int retentionDays() {
    return _db.select('SELECT days FROM retention LIMIT 1').first['days'] as int;
  }

  void setRetentionDays(int days) {
    _db.execute('UPDATE retention SET days = ?', [days]);
  }

  List<String> historyVmUrisPastRetention(int nowMicros) {
    final days = retentionDays();
    return _db
        .select(
          '''
SELECT vm_uri FROM sessions
WHERE state = 'history'
  AND disconnected_at IS NOT NULL
  AND ? - disconnected_at >= ? * 86400000000
''',
          [nowMicros, days],
        )
        .map((row) => row['vm_uri']! as String)
        .toList();
  }

  void upsertRequest(RequestRecord request) {
    final stmt = _db.prepare('''
INSERT INTO requests (
  vm_uri, request_id, isolate_id, method, uri, start_time, end_time,
  status_code, reason_phrase, headers_path, request_body_path, response_body_path,
  request_body_size, response_body_size, body_unavailable, error
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(vm_uri, request_id, start_time) DO UPDATE SET
  isolate_id = excluded.isolate_id,
  method = excluded.method,
  uri = excluded.uri,
  end_time = excluded.end_time,
  status_code = excluded.status_code,
  reason_phrase = excluded.reason_phrase,
  headers_path = excluded.headers_path,
  request_body_path = excluded.request_body_path,
  response_body_path = excluded.response_body_path,
  request_body_size = excluded.request_body_size,
  response_body_size = excluded.response_body_size,
  body_unavailable = excluded.body_unavailable,
  error = excluded.error
''');
    try {
      stmt.execute([
        request.vmUri,
        request.requestId,
        request.isolateId,
        request.method,
        request.uri,
        request.startTime,
        request.endTime,
        request.statusCode,
        request.reasonPhrase,
        request.headersPath,
        request.requestBodyPath,
        request.responseBodyPath,
        request.requestBodySize,
        request.responseBodySize,
        request.bodyUnavailable ? 1 : 0,
        request.error,
      ]);
    } finally {
      stmt.dispose();
    }
  }

  ({String where, List<Object?> args}) _requestFilter({
    required String vmUri,
    String? method,
    int? status,
    String? urlContains,
  }) {
    final conditions = <String>['vm_uri = ?'];
    final args = <Object?>[vmUri];

    if (method != null) {
      conditions.add('method = ?');
      args.add(method);
    }
    if (status != null) {
      conditions.add('status_code = ?');
      args.add(status);
    }
    if (urlContains != null) {
      conditions.add('uri LIKE ? ESCAPE \'\\\'');
      args.add('%${_escapeLike(urlContains)}%');
    }
    return (where: conditions.join(' AND '), args: args);
  }

  List<RequestRecord> listRequests({
    required String vmUri,
    int limit = 50,
    int offset = 0,
    String? method,
    int? status,
    String? urlContains,
  }) {
    final filter = _requestFilter(
      vmUri: vmUri,
      method: method,
      status: status,
      urlContains: urlContains,
    );
    final sql = '''
SELECT * FROM requests
WHERE ${filter.where}
ORDER BY start_time ASC
LIMIT ? OFFSET ?
''';
    return _db
        .select(sql, [...filter.args, limit, offset])
        .map(_requestFromRow)
        .toList();
  }

  /// Rows matching the same filters as [listRequests], ignoring paging.
  int countRequests({
    required String vmUri,
    String? method,
    int? status,
    String? urlContains,
  }) {
    final filter = _requestFilter(
      vmUri: vmUri,
      method: method,
      status: status,
      urlContains: urlContains,
    );
    return _db
        .select('SELECT COUNT(*) AS c FROM requests WHERE ${filter.where}', filter.args)
        .first['c']! as int;
  }

  List<RequestRecord> findByRequestId({
    required String vmUri,
    required String requestId,
  }) {
    return _db
        .select(
          '''
SELECT * FROM requests
WHERE vm_uri = ? AND request_id = ?
ORDER BY start_time ASC
''',
          [vmUri, requestId],
        )
        .map(_requestFromRow)
        .toList();
  }

  static String _escapeLike(String input) {
    return input
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
  }

  static SessionRecord _sessionFromRow(Map<String, Object?> row) {
    return SessionRecord(
      vmUri: row['vm_uri']! as String,
      state: row['state']! as String,
      appName: row['app_name']! as String,
      isolateIds: (jsonDecode(row['isolate_ids']! as String) as List<dynamic>)
          .cast<String>(),
      startedAt: row['started_at']! as int,
      disconnectedAt: row['disconnected_at'] as int?,
      disconnectReason: row['disconnect_reason'] as String?,
      httpProfileAvailable: (row['http_profile_available']! as int) == 1,
    );
  }

  static RequestRecord _requestFromRow(Map<String, Object?> row) {
    return RequestRecord(
      vmUri: row['vm_uri']! as String,
      requestId: row['request_id']! as String,
      isolateId: row['isolate_id']! as String,
      method: row['method']! as String,
      uri: row['uri']! as String,
      startTime: row['start_time']! as int,
      endTime: row['end_time'] as int?,
      statusCode: row['status_code'] as int?,
      reasonPhrase: row['reason_phrase'] as String?,
      headersPath: row['headers_path']! as String,
      requestBodyPath: row['request_body_path'] as String?,
      responseBodyPath: row['response_body_path'] as String?,
      requestBodySize: row['request_body_size']! as int,
      responseBodySize: row['response_body_size']! as int,
      bodyUnavailable: (row['body_unavailable']! as int) == 1,
      error: row['error'] as String?,
    );
  }

  static Map<String, String> _decodeStringMap(String json) {
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    return decoded.map((key, value) => MapEntry(key, value as String));
  }

  static Uint8List? _readBlob(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is Uint8List) {
      return value;
    }
    if (value is List<int>) {
      return Uint8List.fromList(value);
    }
    throw StateError('unexpected blob type: ${value.runtimeType}');
  }
}
