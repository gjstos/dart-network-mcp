import 'dart:convert';
import 'dart:typed_data';

class ExportableRequest {
  ExportableRequest({
    required this.vmUri,
    required this.requestId,
    required this.isolateId,
    required this.method,
    required this.uri,
    required this.startTime,
    required this.endTime,
    required this.statusCode,
    required this.reasonPhrase,
    required this.requestHeaders,
    required this.responseHeaders,
    required this.requestBody,
    required this.responseBody,
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
  final Map<String, String> requestHeaders;
  final Map<String, String> responseHeaders;
  final Uint8List? requestBody;
  final Uint8List? responseBody;
  final int requestBodySize;
  final int responseBodySize;
  final bool bodyUnavailable;
  final String? error;
}

Map<String, Object?> buildHar(
  List<ExportableRequest> requests, {
  required String version,
}) {
  return {
    'log': {
      'version': '1.2',
      'creator': {
        'name': 'dart-network-mcp',
        'version': version,
      },
      'entries': requests.map(harEntry).toList(),
    },
  };
}

Map<String, Object?> harEntry(ExportableRequest request) {
  final timeMs = request.endTime == null
      ? 0
      : (request.endTime! - request.startTime) ~/ 1000;

  return {
    'startedDateTime': DateTime.fromMicrosecondsSinceEpoch(
      request.startTime,
      isUtc: true,
    ).toIso8601String(),
    'time': timeMs,
    'request': _harRequest(request),
    'response': _harResponse(request),
    'cache': <String, Object?>{},
    'timings': {
      'blocked': -1,
      'dns': -1,
      'connect': -1,
      'ssl': -1,
      'send': 0,
      'wait': timeMs,
      'receive': 0,
    },
  };
}

Map<String, Object?> _harRequest(ExportableRequest request) {
  final parsed = Uri.parse(request.uri);
  final result = <String, Object?>{
    'method': request.method,
    'url': request.uri,
    'httpVersion': 'HTTP/1.1',
    'headers': _harHeaders(request.requestHeaders),
    'queryString': parsed.queryParameters.entries
        .map((e) => {'name': e.key, 'value': e.value})
        .toList(),
  };
  final body = request.requestBody;
  if (body != null) {
    final encoded = _encodeBodyText(body);
    result['postData'] = {
      'mimeType': _mimeType(request.requestHeaders),
      if (encoded.encoding != null) 'encoding': encoded.encoding,
      'text': encoded.text,
    };
  }
  return result;
}

Map<String, Object?> _harResponse(ExportableRequest request) {
  return {
    'status': request.statusCode ?? 0,
    'statusText': request.reasonPhrase ?? '',
    'headers': _harHeaders(request.responseHeaders),
    'content': _harContent(request.responseBody, request.responseHeaders),
  };
}

List<Map<String, String>> _harHeaders(Map<String, String> headers) {
  return headers.entries
      .map((e) => {'name': e.key, 'value': e.value})
      .toList();
}

Map<String, Object?> _harContent(
  Uint8List? body,
  Map<String, String> headers,
) {
  final mimeType = _mimeType(headers);
  if (body == null) {
    return {'mimeType': mimeType, 'size': 0};
  }
  final encoded = _encodeBodyText(body);
  return {
    'mimeType': mimeType,
    'size': body.length,
    if (encoded.encoding != null) 'encoding': encoded.encoding,
    'text': encoded.text,
  };
}

String _mimeType(Map<String, String> headers) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'content-type') {
      return entry.value;
    }
  }
  return 'application/octet-stream';
}

({String text, String? encoding}) _encodeBodyText(Uint8List body) {
  if (body.contains(0)) {
    return (text: base64Encode(body), encoding: 'base64');
  }
  try {
    return (text: utf8.decode(body), encoding: null);
  } on FormatException {
    return (text: base64Encode(body), encoding: 'base64');
  }
}
