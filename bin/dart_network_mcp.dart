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
  required bool inDocker,
}) async {
  final now = DateTime.now().microsecondsSinceEpoch;
  for (final session in store.listSessions('live')) {
    final result = await mcp.attachVm(session.vmUri, inDocker: inDocker);
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

Future<bool> _vmSocketOpen(String rawUri, {required bool inDocker}) async {
  try {
    final canonical = canonicalizeVmUri(rawUri);
    final socketUri = await dialUriFor(
      Uri.parse(canonical),
      inDocker: inDocker,
    );
    final service = await vmServiceConnectUri(socketUri.toString()).timeout(
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
  final sessions = response.result['sessions'];
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

Future<List<String>> _discoverVmUris(DartToolingDaemon dtd) async {
  try {
    return await _vmUrisFromConnectedApp(dtd);
  } catch (_) {
    try {
      return await _vmUrisFromEditor(dtd);
    } catch (_) {
      return [];
    }
  }
}

class _DtdConnection {
  _DtdConnection({
    required this.client,
    required this.events,
  });

  final DartToolingDaemon client;
  final StreamSubscription<DTDEvent> events;
}

class _DtdDiscovery {
  _DtdDiscovery({
    required this.mcp,
    required this.store,
    required this.inDocker,
    required this.dataDirectory,
  });

  final DartNetworkMcp mcp;
  final SessionStore store;
  final bool inDocker;
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

  Future<void> _tick() async {
    try {
      final uris = discoverDtdUris(
        dtdUriEnv: Platform.environment['DTD_URI'],
        dartDtdDir: _dartDtdDirectory(),
        dartToolDir: _dartToolDirectory(),
      );
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
    }
  }

  Future<bool> _tryConnect(String wsUri) async {
    Uri? dialed;
    try {
      final socket = await dialUriFor(Uri.parse(wsUri), inDocker: inDocker);
      dialed = socket;
      final client = await DartToolingDaemon.connect(socket);
      await client.streamListen(ConnectedAppServiceConstants.serviceName);
      final events = client.onVmServiceUpdate().listen(
        (event) => unawaited(_onVmServiceEvent(event)),
        onError: (Object e) => _log('DTD VM event stream error: $e'),
      );
      _connections[wsUri] = _DtdConnection(client: client, events: events);
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
      _log('DTD connect failed for $wsUri via ${dialed ?? wsUri}: $e');
      return false;
    }
  }

  Future<void> _drop(String wsUri) async {
    final conn = _connections.remove(wsUri);
    if (conn == null) {
      return;
    }
    await conn.events.cancel();
    try {
      await conn.client.close();
    } catch (_) {}
  }

  Future<void> _syncVmUris(DartToolingDaemon dtd) async {
    final uris = await _discoverVmUris(dtd);
    for (final uri in uris) {
      await mcp.attachVm(uri, inDocker: inDocker);
    }
  }

  Future<void> _onVmServiceEvent(DTDEvent event) async {
    try {
      if (event.kind == ConnectedAppServiceConstants.vmServiceRegistered) {
        final uri = event.data[DtdParameters.uri];
        if (uri is String && uri.isNotEmpty) {
          await mcp.attachVm(uri, inDocker: inDocker);
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
        final open = await _vmSocketOpen(raw, inDocker: inDocker);
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

void _registerTools(McpServer server, DartNetworkMcp mcp, {required bool inDocker}) {
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
      return _toolResult(await mcp.attachVm(uri, inDocker: inDocker));
    },
  );

  server.tool(
    'list_requests',
    description:
        'List calls with method, URI, status, duration and bodies. Headers stay on get_request.',
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
  final inDocker = Platform.environment['DART_NETWORK_MCP_IN_DOCKER'] == '1';
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
  await _recoverLiveSessions(mcp: mcp, store: store, inDocker: inDocker);

  final server = McpServer(
    Implementation(name: 'dart-network-mcp', version: '0.1.0'),
    options: ServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
      ),
    ),
  );
  _registerTools(server, mcp, inDocker: inDocker);

  _DtdDiscovery(
    mcp: mcp,
    store: store,
    inDocker: inDocker,
    dataDirectory: dataDir,
  ).start();

  await server.connect(StdioServerTransport());
}
