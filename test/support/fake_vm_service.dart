import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

class FakeHttpProfileEntry {
  FakeHttpProfileEntry({
    required this.id,
    required this.method,
    required this.uri,
    required this.startTime,
    this.isolateId = 'isolates/main',
    this.endTime,
    this.statusCode,
    this.reasonPhrase = 'OK',
    this.requestHeaders = const {},
    this.responseHeaders = const {},
    this.requestBody = const [],
    this.responseBody = const [],
    this.responseComplete = true,
    int? lastModified,
  }) : lastModified = lastModified ?? startTime;

  final String id;
  final String method;
  final String uri;
  final String isolateId;
  final int startTime;
  int? endTime;
  int? statusCode;
  String reasonPhrase;
  Map<String, String> requestHeaders;
  Map<String, String> responseHeaders;
  List<int> requestBody;
  List<int> responseBody;

  /// `false` models dart:io after the request is sent: `endTime` is set but
  /// the response has not finished (`response.endTime` absent).
  bool responseComplete;
  late int lastModified;
}

class FakeVmService {
  FakeVmService({
    this.httpAvailable = true,
    this.rootLibUri,
    List<String>? extensionRpcs,
  }) : extensionRpcs = extensionRpcs ?? ['ext.flutter.version'];

  bool httpAvailable;
  final String? rootLibUri;
  final List<String> extensionRpcs;

  late HttpServer _server;
  late String _token;
  final List<WebSocket> _clients = [];
  final List<FakeHttpProfileEntry> _requests = [];
  final Set<String> _loggingEnabledIsolates = {};
  final List<Map<String, dynamic>> _extraVmIsolates = [];
  late int _profileTimestamp;
  bool failNextGetHttpProfileRequest = false;
  bool hangNextGetHttpProfile = false;
  int clearHttpProfileCalls = 0;
  int getHttpProfileCalls = 0;

  /// Isolates whose `getHttpProfile` fails, like one that just exited.
  final Set<String> brokenIsolates = {};

  late final String consoleHttpUri;
  late final Uri webSocketUri;

  static Future<FakeVmService> start({
    bool httpAvailable = true,
    String? rootLibUri,
    List<String>? extensionRpcs,
  }) async {
    final fake = FakeVmService(
      httpAvailable: httpAvailable,
      rootLibUri: rootLibUri,
      extensionRpcs: extensionRpcs,
    );
    await fake._bind();
    return fake;
  }

  Future<void> _bind() async {
    _profileTimestamp = DateTime.now().microsecondsSinceEpoch;
    _token = _randomToken();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = _server.port;
    consoleHttpUri = 'http://127.0.0.1:$port/$_token/';
    webSocketUri = Uri.parse('ws://127.0.0.1:$port/$_token/ws');
    _server.listen(_onHttpRequest);
  }

  String _randomToken() {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    final rand = Random();
    return List.generate(12, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  void addRequest(FakeHttpProfileEntry entry) {
    final existing = _requests.indexWhere(
      (r) => r.id == entry.id && r.startTime == entry.startTime,
    );
    if (existing >= 0) {
      _requests[existing] = entry;
    } else {
      _requests.add(entry);
    }
  }

  void addVmIsolate({
    required String id,
    String name = 'main',
    String number = '2',
  }) {
    _extraVmIsolates.add({
      'type': '@Isolate',
      'id': id,
      'number': number,
      'name': name,
      'isSystemIsolate': false,
    });
  }

  bool isLoggingEnabledFor(String isolateId) =>
      _loggingEnabledIsolates.contains(isolateId);

  void emitIsolateEvent({
    required String kind,
    required String isolateId,
    String name = 'main',
    String number = '2',
    String? extensionRPC,
  }) {
    final payload = jsonEncode({
      'jsonrpc': '2.0',
      'method': 'streamNotify',
      'params': {
        'streamId': 'Isolate',
        'event': {
          'type': 'Event',
          'kind': kind,
          'isolate': {
            'type': '@Isolate',
            'id': isolateId,
            'name': name,
            'number': number,
          },
          if (extensionRPC != null) 'extensionRPC': extensionRPC,
        },
      },
    });
    for (final client in List<WebSocket>.from(_clients)) {
      client.add(payload);
    }
  }

  void updateRequestStatus({
    required String id,
    required int startTime,
    required int statusCode,
  }) {
    final entry = _requests.firstWhere(
      (r) => r.id == id && r.startTime == startTime,
    );
    entry.statusCode = statusCode;
    entry.lastModified = DateTime.now().microsecondsSinceEpoch;
  }

  void completeResponse({
    required String id,
    required int startTime,
    required int statusCode,
    List<int> responseBody = const [],
  }) {
    final entry = _requests.firstWhere(
      (r) => r.id == id && r.startTime == startTime,
    );
    entry
      ..statusCode = statusCode
      ..responseBody = responseBody
      ..responseComplete = true
      ..lastModified = DateTime.now().microsecondsSinceEpoch;
  }

  Future<void> close() async {
    closeClients();
    await _server.close(force: true);
  }

  void closeClients() {
    for (final client in List<WebSocket>.from(_clients)) {
      client.close();
    }
  }

  Future<void> _onHttpRequest(HttpRequest request) async {
    if (request.uri.path.endsWith('/ws')) {
      final socket = await WebSocketTransformer.upgrade(request);
      _clients.add(socket);
      socket.listen(
        (data) => _onMessage(socket, data as String),
        onDone: () => _clients.remove(socket),
      );
      return;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  void _onMessage(WebSocket socket, String data) {
    final message = jsonDecode(data) as Map<String, dynamic>;
    if (!message.containsKey('method')) {
      return;
    }
    final id = message['id'];
    final method = message['method'] as String;
    final params =
        (message['params'] as Map<String, dynamic>?) ?? <String, dynamic>{};

    if (method == 'ext.dart.io.getHttpProfile' && hangNextGetHttpProfile) {
      hangNextGetHttpProfile = false;
      return;
    }

    try {
      final result = _dispatch(method, params);
      socket.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
    } catch (e) {
      try {
        socket.add(jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32000, 'message': e.toString()},
        }));
      } catch (_) {}
    }
  }

  Object? _dispatch(String method, Map<String, dynamic> params) {
    switch (method) {
      case 'getVM':
        return _getVm();
      case 'getIsolate':
        return _getIsolate(params['isolateId'] as String);
      case 'streamListen':
        return {'type': 'Success'};
      case 'getVersion':
        return {'type': 'Version', 'major': 3, 'minor': 6};
      case 'ext.dart.io.getVersion':
        return {'type': 'Version', 'major': 2, 'minor': 0};
      case 'ext.dart.io.isHttpProfilingAvailable':
        return {'type': 'Success', 'enabled': httpAvailable};
      case 'ext.dart.io.httpEnableTimelineLogging':
        final isolateId = params['isolateId'] as String?;
        if (isolateId != null) {
          _loggingEnabledIsolates.add(isolateId);
        }
        return {
          'type': 'HttpTimelineLoggingState',
          'enabled': params['enabled'] ?? true,
        };
      case 'ext.dart.io.getHttpProfile':
        return _getHttpProfile(params);
      case 'ext.dart.io.getHttpProfileRequest':
        return _getHttpProfileRequest(params);
      case 'ext.dart.io.clearHttpProfile':
        clearHttpProfileCalls++;
        _requests.removeWhere((r) => r.isolateId == params['isolateId']);
        return {'type': 'Success'};
      default:
        return {'type': 'Success'};
    }
  }

  Map<String, dynamic> _getVm() {
    return {
      'type': 'VM',
      'name': 'vm',
      'architectureBits': 64,
      'hostCPU': 'test',
      'operatingSystem': 'linux',
      'targetCPU': 'x64',
      'version': '3.6.0',
      'pid': 1,
      'startTime': 0,
      'isolates': [
        {
          'type': '@Isolate',
          'id': 'isolates/main',
          'number': '1',
          'name': 'main',
          'isSystemIsolate': false,
        },
        ..._extraVmIsolates,
      ],
      'isolateGroups': [],
      'systemIsolates': [],
      'systemIsolateGroups': [],
    };
  }

  Map<String, dynamic> _getIsolate(String isolateId) {
    final rpcs = <String>[...extensionRpcs];
    if (httpAvailable) {
      rpcs.addAll([
        'ext.dart.io.getHttpProfile',
        'ext.dart.io.getHttpProfileRequest',
        'ext.dart.io.httpEnableTimelineLogging',
        'ext.dart.io.isHttpProfilingAvailable',
        'ext.dart.io.getVersion',
      ]);
    }
    return {
      'type': 'Isolate',
      'id': isolateId,
      'name': 'main',
      'number': '1',
      'isSystemIsolate': false,
      'extensionRPCs': rpcs,
      if (rootLibUri != null)
        'rootLib': {
          'type': '@Library',
          'id': 'libraries/root',
          'name': 'main',
          'uri': rootLibUri,
        },
    };
  }

  Map<String, dynamic> _getHttpProfile(Map<String, dynamic> params) {
    getHttpProfileCalls++;
    final isolateId = params['isolateId'] as String? ?? 'isolates/main';
    if (brokenIsolates.contains(isolateId)) {
      throw StateError('isolate $isolateId is gone');
    }
    if (!_loggingEnabledIsolates.contains(isolateId)) {
      return {
        'type': 'HttpProfile',
        'timestamp': _profileTimestamp,
        'requests': <Map<String, dynamic>>[],
      };
    }
    final updatedSince = params['updatedSince'] as int?;
    final filtered = _requests.where((r) {
      if (r.isolateId != isolateId) {
        return false;
      }
      if (updatedSince == null) {
        return true;
      }
      return r.lastModified >= updatedSince;
    }).toList();
    _profileTimestamp = DateTime.now().microsecondsSinceEpoch;
    return {
      'type': 'HttpProfile',
      'timestamp': _profileTimestamp,
      'requests':
          filtered.map((e) => _requestJson(e, includeBodies: false)).toList(),
    };
  }

  Map<String, dynamic> _getHttpProfileRequest(Map<String, dynamic> params) {
    if (failNextGetHttpProfileRequest) {
      failNextGetHttpProfileRequest = false;
      throw StateError('profile request failed');
    }
    final id = params['id'] as String;
    final entry = _requests.firstWhere((r) => r.id == id);
    return _requestJson(entry, includeBodies: true);
  }

  Map<String, dynamic> _requestJson(
    FakeHttpProfileEntry entry, {
    required bool includeBodies,
  }) {
    final json = <String, dynamic>{
      'type': 'HttpProfileRequest',
      'isolateId': entry.isolateId,
      'id': entry.id,
      'method': entry.method,
      'uri': entry.uri,
      'events': <Map<String, dynamic>>[],
      'startTime': entry.startTime,
      if (entry.endTime != null) 'endTime': entry.endTime,
      'request': {
        'headers': entry.requestHeaders,
        'connectionInfo': <String, dynamic>{},
        'cookies': <String>[],
      },
      'response': {
        'redirects': <Map<String, dynamic>>[],
        if (entry.statusCode != null) 'statusCode': entry.statusCode,
        'reasonPhrase': entry.reasonPhrase,
        'headers': entry.responseHeaders,
        if (entry.endTime != null && entry.responseComplete)
          'endTime': entry.endTime,
      },
    };
    if (includeBodies) {
      json['requestBody'] = entry.requestBody;
      json['responseBody'] = entry.responseBody;
    }
    return json;
  }
}
