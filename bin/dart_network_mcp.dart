import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_network_mcp/src/dart_network_mcp.dart';
import 'package:dart_network_mcp/src/data_dir.dart';
import 'package:dart_network_mcp/src/discovery.dart';
import 'package:dart_network_mcp/src/session_store.dart';
import 'package:dart_network_mcp/src/tool_json.dart';
import 'package:dart_network_mcp/src/vm_uri.dart';
import 'package:dtd/dtd.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service_io.dart';

void _log(String message) {
  stderr.writeln(message);
}

void _configureMcpLogging() {
  Logger.setHandler((loggerName, level, message) {
    stderr.writeln('[${level.name.toUpperCase()}][$loggerName] $message');
  });
}

CallToolResult _toolResult(Map<String, Object?> map) {
  return CallToolResult.fromContent(
    content: [TextContent(text: jsonEncode(map))],
    isError: map.containsKey('error'),
  );
}

void _chmodIfUnix(String path, String mode) {
  if (Platform.isWindows) {
    return;
  }
  Process.runSync('chmod', [mode, path]);
}

Future<void> _ensureDataDirectory(String dataDir) async {
  final dir = Directory(dataDir);
  dir.createSync(recursive: true);
  _chmodIfUnix(dataDir, '700');
  final dbFile = File(p.join(dataDir, 'network.sqlite'));
  if (dbFile.existsSync()) {
    _chmodIfUnix(dbFile.path, '600');
  }
}

Future<void> _recoverLiveSessions({
  required DartNetworkMcp mcp,
  required SessionStore store,
}) async {
  final now = DateTime.now().microsecondsSinceEpoch;
  for (final session in store.listSessions('live')) {
    final result = await mcp.attachVm(session.vmUri);
    if (!result.containsKey('error')) {
      continue;
    }
    final error = result['error'];
    if (error is Map && error['code'] == 'attach_failed') {
      store.markHistory(session.vmUri, 'process_restart', now);
    }
  }
}

bool _isHttpOrWsUri(String raw) {
  final uri = Uri.tryParse(raw);
  if (uri == null) {
    return false;
  }
  return uri.scheme == 'http' ||
      uri.scheme == 'https' ||
      uri.scheme == 'ws' ||
      uri.scheme == 'wss';
}

String? _pickVmUriField(Map<String, Object?> session) {
  for (final key in ['vmServiceUri', 'vmServiceWsUri', 'uri']) {
    final raw = session[key];
    if (raw is String && raw.isNotEmpty && _isHttpOrWsUri(raw)) {
      return raw;
    }
  }
  return null;
}

Future<bool> _vmSocketOpen(String rawUri) async {
  try {
    final canonical = canonicalizeVmUri(rawUri);
    final service = await vmServiceConnectUri(canonical).timeout(
      const Duration(seconds: 2),
    );
    await service.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

Future<List<String>> _vmUrisFromConnectedApp(DartToolingDaemon dtd) async {
  final response = await dtd.getVmServices();
  return response.vmServicesInfos
      .map((info) => info.exposedUri ?? info.uri)
      .where((uri) => uri.isNotEmpty)
      .toList();
}

Future<List<String>> _vmUrisFromEditor(DartToolingDaemon dtd) async {
  final response = await dtd.call('Editor', 'getDebugSessions');
  final sessions = response.result['debugSessions'];
  if (sessions is! List) {
    return [];
  }
  final uris = <String>[];
  for (final entry in sessions) {
    if (entry is! Map) {
      continue;
    }
    final map = entry.map((k, v) => MapEntry(k.toString(), v));
    final picked = _pickVmUriField(map);
    if (picked != null) {
      uris.add(picked);
    }
  }
  return uris;
}

/// DTDs answer differently depending on who owns them: a `flutter run` DTD
/// lists apps through `getVmServices`, while the VS Code one never replies to
/// it and only exposes them through `Editor.getDebugSessions`. Ask both, each
/// with a deadline, and merge.
Future<List<String>> _discoverVmUris(DartToolingDaemon dtd) async {
  const deadline = Duration(seconds: 5);
  Future<List<String>> safely(Future<List<String>> Function() source) async {
    try {
      return await source().timeout(deadline);
    } catch (_) {
      return const [];
    }
  }

  final found = await Future.wait([
    safely(() => _vmUrisFromConnectedApp(dtd)),
    safely(() => _vmUrisFromEditor(dtd)),
  ]);
  return {for (final uris in found) ...uris}.toList();
}

class _DtdConnection {
  _DtdConnection({
    required this.client,
    required this.events,
  });

  final DartToolingDaemon client;
  final StreamSubscription<DTDEvent>? events;
}

class _DtdDiscovery {
  _DtdDiscovery({
    required this.mcp,
    required this.store,
    required this.dataDirectory,
  });

  final DartNetworkMcp mcp;
  final SessionStore store;
  final String dataDirectory;

  final Map<String, _DtdConnection> _connections = {};
  Set<String> _discovered = {};
  late final Directory _emptyDartToolDir;

  void start() {
    _emptyDartToolDir = Directory(p.join(dataDirectory, '_empty_dart_tool'));
    _emptyDartToolDir.createSync(recursive: true);
    Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_tick());
    });
  }

  Directory _dartToolDirectory() {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) {
      return _emptyDartToolDir;
    }
    final dir = Directory(p.join(home, '.dart-tool'));
    try {
      if (!dir.existsSync()) {
        return _emptyDartToolDir;
      }
    } on FileSystemException {
      return _emptyDartToolDir;
    }
    return dir;
  }

  Directory? _dartDtdDirectory() {
    final dir = defaultDartDtdDirectory();
    try {
      if (!dir.existsSync()) {
        return null;
      }
    } on FileSystemException {
      return null;
    }
    return dir;
  }

  bool _ticking = false;

  Future<void> _tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      final uris = discoverDtdUris(
        dtdUriEnv: Platform.environment['DTD_URI'],
        dartDtdDir: _dartDtdDirectory(),
        dartToolDir: _dartToolDirectory(),
      );
      for (final uri in await probeDevToolsDtdUris(host: '127.0.0.1')) {
        if (!uris.contains(uri)) uris.add(uri);
      }
      final wanted = uris.toSet();
      if (wanted.length != _discovered.length ||
          !wanted.containsAll(_discovered)) {
        _discovered = wanted;
        _log(
          uris.isEmpty
              ? 'DTD discovery: (none)'
              : 'DTD discovery: ${uris.join(' ')}',
        );
      }
      for (final uri in _connections.keys.toList()) {
        if (!wanted.contains(uri)) {
          await _drop(uri);
        }
      }
      for (final uri in uris) {
        final existing = _connections[uri];
        if (existing != null) {
          await _syncVmUris(existing.client);
          continue;
        }
        await _tryConnect(uri);
      }
    } catch (e, st) {
      _log('DTD discovery error: $e\n$st');
    } finally {
      _ticking = false;
    }
  }

  Future<bool> _tryConnect(String wsUri) async {
    try {
      final client = await DartToolingDaemon.connect(Uri.parse(wsUri));
      // Some DTDs (VS Code's) never answer the ConnectedApp service calls;
      // polling in `_syncVmUris` still finds their apps, so events are a bonus.
      StreamSubscription<DTDEvent>? events;
      try {
        await client
            .streamListen(ConnectedAppServiceConstants.serviceName)
            .timeout(const Duration(seconds: 5));
        events = client.onVmServiceUpdate().listen(
          (event) => unawaited(_onVmServiceEvent(event)),
          onError: (Object e) => _log('DTD VM event stream error: $e'),
        );
      } catch (e) {
        _log('DTD event stream unavailable for $wsUri: $e');
      }
      _connections[wsUri] = _DtdConnection(client: client, events: events);
      _log('DTD connected: $wsUri');
      unawaited(
        client.done.whenComplete(() {
          if (_connections[wsUri]?.client == client) {
            unawaited(_drop(wsUri));
          }
        }),
      );
      await _syncVmUris(client);
      return true;
    } catch (e) {
      _log('DTD connect failed for $wsUri: $e');
      return false;
    }
  }

  Future<void> _drop(String wsUri) async {
    final conn = _connections.remove(wsUri);
    if (conn == null) {
      return;
    }
    await conn.events?.cancel();
    try {
      await conn.client.close();
    } catch (_) {}
  }

  Future<void> _syncVmUris(DartToolingDaemon dtd) async {
    final uris = await _discoverVmUris(dtd);
    for (final uri in uris) {
      final result = await mcp.attachVm(uri);
      if (result['error'] != null) {
        _log('attach failed for $uri: ${jsonEncode(result['error'])}');
      }
    }
  }

  Future<void> _onVmServiceEvent(DTDEvent event) async {
    try {
      if (event.kind == ConnectedAppServiceConstants.vmServiceRegistered) {
        final uri = event.data[DtdParameters.uri];
        if (uri is String && uri.isNotEmpty) {
          await mcp.attachVm(uri);
        }
        return;
      }
      if (event.kind == ConnectedAppServiceConstants.vmServiceUnregistered) {
        final raw = event.data[DtdParameters.uri];
        if (raw is! String || raw.isEmpty) {
          return;
        }
        String canonical;
        try {
          canonical = canonicalizeVmUri(raw);
        } on FormatException {
          return;
        }
        final record = store.getSession(canonical);
        if (record == null || record.state != 'live') {
          return;
        }
        final open = await _vmSocketOpen(raw);
        if (!open) {
          await mcp.disposeLiveSession(canonical);
          store.markHistory(
            canonical,
            'socket closed',
            DateTime.now().microsecondsSinceEpoch,
          );
        }
      }
    } catch (e) {
      _log('DTD VM event handler error: $e');
    }
  }
}

void _registerTools(McpServer server, DartNetworkMcp mcp) {
  server.tool(
    'list_sessions',
    description: 'List VM sessions',
    toolInputSchema: ToolInputSchema(
      properties: {
        'state': {
          'type': 'string',
          'enum': ['live', 'history', 'all'],
        },
      },
    ),
    callback: ({args, extra}) async {
      final state = args?['state'];
      if (state != null && state is! String) {
        return _toolResult(
          toolError('invalid_params', 'state must be a string'),
        );
      }
      final stateStr = state as String? ?? 'live';
      if (stateStr != 'live' && stateStr != 'history' && stateStr != 'all') {
        return _toolResult(
          toolError('invalid_params', 'state must be live, history, or all'),
        );
      }
      return _toolResult(mcp.listSessions(state: stateStr));
    },
  );

  server.tool(
    'get_session',
    description: 'Get one VM session',
    toolInputSchema: ToolInputSchema(
      properties: {'vmUri': {'type': 'string'}},
      required: ['vmUri'],
    ),
    callback: ({args, extra}) async {
      final vmUri = args?['vmUri'];
      if (vmUri is! String || vmUri.isEmpty) {
        return _toolResult(toolError('invalid_params', 'vmUri is required'));
      }
      return _toolResult(mcp.getSession(vmUri));
    },
  );

  server.tool(
    'attach_vm',
    description: 'Attach to a VM by URI',
    toolInputSchema: ToolInputSchema(
      properties: {'uri': {'type': 'string'}},
      required: ['uri'],
    ),
    callback: ({args, extra}) async {
      final uri = args?['uri'];
      if (uri is! String || uri.isEmpty) {
        return _toolResult(toolError('invalid_params', 'uri is required'));
      }
      return _toolResult(await mcp.attachVm(uri));
    },
  );

  server.tool(
    'list_requests',
    description:
        'List calls with method, URI, status, duration and bodies. Headers stay on get_request. Paged: limit defaults to 50 (max 200); the result carries total and nextOffset, so pass nextOffset as offset until it is null.',
    toolInputSchema: ToolInputSchema(
      properties: {
        'vmUri': {'type': 'string'},
        'includeHistory': {'type': 'boolean'},
        'limit': {'type': 'integer'},
        'offset': {'type': 'integer'},
        'method': {'type': 'string'},
        'status': {'type': 'integer'},
        'urlContains': {'type': 'string'},
      },
      required: ['vmUri'],
    ),
    callback: ({args, extra}) async {
      final vmUri = args?['vmUri'];
      if (vmUri is! String || vmUri.isEmpty) {
        return _toolResult(toolError('invalid_params', 'vmUri is required'));
      }
      return _toolResult(
        mcp.listRequests(
          vmUri,
          includeHistory: args?['includeHistory'] == true,
          limit: args?['limit'] is int ? args!['limit'] as int : null,
          offset: args?['offset'] is int ? args!['offset'] as int : null,
          method: args?['method'] is String ? args!['method'] as String : null,
          status: args?['status'] is int ? args!['status'] as int : null,
          urlContains: args?['urlContains'] is String
              ? args!['urlContains'] as String
              : null,
        ),
      );
    },
  );

  server.tool(
    'get_request',
    description: 'Get one HTTP profile request',
    toolInputSchema: ToolInputSchema(
      properties: {
        'vmUri': {'type': 'string'},
        'requestId': {'type': 'string'},
        'startTime': {'type': 'integer'},
        'includeHistory': {'type': 'boolean'},
      },
      required: ['vmUri', 'requestId'],
    ),
    callback: ({args, extra}) async {
      final vmUri = args?['vmUri'];
      final requestId = args?['requestId'];
      if (vmUri is! String || vmUri.isEmpty) {
        return _toolResult(toolError('invalid_params', 'vmUri is required'));
      }
      if (requestId is! String || requestId.isEmpty) {
        return _toolResult(
          toolError('invalid_params', 'requestId is required'),
        );
      }
      return _toolResult(
        mcp.getRequest(
          vmUri,
          requestId,
          startTime: args?['startTime'] is int ? args!['startTime'] as int : null,
          includeHistory: args?['includeHistory'] == true,
        ),
      );
    },
  );

  server.tool(
    'export_har',
    description: 'Export session traffic as HAR',
    toolInputSchema: ToolInputSchema(
      properties: {
        'vmUri': {'type': 'string'},
        'includeHistory': {'type': 'boolean'},
      },
      required: ['vmUri'],
    ),
    callback: ({args, extra}) async {
      final vmUri = args?['vmUri'];
      if (vmUri is! String || vmUri.isEmpty) {
        return _toolResult(toolError('invalid_params', 'vmUri is required'));
      }
      return _toolResult(
        mcp.exportHar(vmUri, includeHistory: args?['includeHistory'] == true),
      );
    },
  );

  server.tool(
    'export_devtools_json',
    description: 'Export session traffic as DevTools JSON',
    toolInputSchema: ToolInputSchema(
      properties: {
        'vmUri': {'type': 'string'},
        'includeHistory': {'type': 'boolean'},
      },
      required: ['vmUri'],
    ),
    callback: ({args, extra}) async {
      final vmUri = args?['vmUri'];
      if (vmUri is! String || vmUri.isEmpty) {
        return _toolResult(toolError('invalid_params', 'vmUri is required'));
      }
      return _toolResult(
        mcp.exportDevToolsJson(
          vmUri,
          includeHistory: args?['includeHistory'] == true,
        ),
      );
    },
  );

  server.tool(
    'delete_session',
    description: 'Delete a session and its stored requests',
    toolInputSchema: ToolInputSchema(
      properties: {'vmUri': {'type': 'string'}},
      required: ['vmUri'],
    ),
    callback: ({args, extra}) async {
      final vmUri = args?['vmUri'];
      if (vmUri is! String || vmUri.isEmpty) {
        return _toolResult(toolError('invalid_params', 'vmUri is required'));
      }
      return _toolResult(await mcp.deleteSession(vmUri));
    },
  );

  server.tool(
    'get_retention',
    description: 'Return the session retention period in days',
    toolInputSchema: ToolInputSchema(properties: {}),
    callback: ({args, extra}) async => _toolResult(mcp.getRetention()),
  );

  server.tool(
    'set_retention',
    description: 'Set the session retention period in days and sweep expired history',
    toolInputSchema: ToolInputSchema(
      properties: {'days': {'type': 'integer'}},
      required: ['days'],
    ),
    callback: ({args, extra}) async {
      final days = args?['days'];
      if (days is! int) {
        return _toolResult(toolError('invalid_params', 'days must be an integer'));
      }
      return _toolResult(mcp.setRetention(days));
    },
  );
}

Future<void> main() async {
  _configureMcpLogging();
  final dataDir = resolveDataDirectory(Platform.environment);
  await _ensureDataDirectory(dataDir);

  final dbPath = p.join(dataDir, 'network.sqlite');
  final store = SessionStore.open(dbPath, dataDirectory: dataDir);
  _chmodIfUnix(dbPath, '600');

  final mcp = DartNetworkMcp(store: store, dataDirectory: dataDir);
  try {
    mcp.sweepRetention();
  } catch (e) {
    _log('startup sweepRetention error (ignored): $e');
  }
  Timer.periodic(const Duration(hours: 1), (_) {
    try {
      mcp.sweepRetention();
    } catch (e) {
      _log('hourly sweepRetention error (ignored): $e');
    }
  });
  await _recoverLiveSessions(mcp: mcp, store: store);

  final server = McpServer(
    Implementation(name: 'dart-network-mcp', version: '0.1.0'),
    options: ServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
      ),
    ),
  );
  _registerTools(server, mcp);

  _DtdDiscovery(
    mcp: mcp,
    store: store,
    dataDirectory: dataDir,
  ).start();

  // The client owns this process: once it closes stdin there is nobody left to
  // serve, so leave instead of lingering on the discovery timers.
  server.server.onclose = () {
    try {
      store.close();
    } finally {
      exit(0);
    }
  };
  await server.connect(StdioServerTransport());
}
