import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_vm_mcp/src/session_store.dart';

Map<String, Object?> buildHar(
  List<RequestRecord> requests, {
  required String version,
}) {
  return {
    'log': {
      'version': '1.2',
      'creator': {
        'name': 'dart-vm-mcp',
        'version': version,
      },
      'entries': requests.map(_entryFromRequest).toList(),
    },
  };
}

Map<String, Object?> _entryFromRequest(RequestRecord record) {
  final timeMs = record.endTime == null
      ? 0
      : (record.endTime! - record.startTime) ~/ 1000;

  return {
    'startedDateTime': DateTime.fromMicrosecondsSinceEpoch(
      record.startTime,
      isUtc: true,
    ).toIso8601String(),
    'time': timeMs,
    'request': _harRequest(record),
    'response': _harResponse(record),
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

Map<String, Object?> _harRequest(RequestRecord record) {
  final parsed = Uri.parse(record.uri);
  final request = <String, Object?>{
    'method': record.method,
    'url': record.uri,
    'httpVersion': 'HTTP/1.1',
    'headers': _harHeaders(record.requestHeaders),
    'queryString': parsed.queryParameters.entries
        .map((e) => {'name': e.key, 'value': e.value})
        .toList(),
  };
  if (record.requestBody != null) {
    request['postData'] = _harPostData(record.requestBody!);
  }
  return request;
}

Map<String, Object?> _harResponse(RequestRecord record) {
  final response = <String, Object?>{
    'status': record.statusCode ?? 0,
    'statusText': record.reasonPhrase ?? '',
    'headers': _harHeaders(record.responseHeaders),
    'content': _harContent(record.responseBody),
  };
  return response;
}

List<Map<String, String>> _harHeaders(Map<String, String> headers) {
  return headers.entries
      .map((e) => {'name': e.key, 'value': e.value})
      .toList();
}

Map<String, Object?> _harPostData(Uint8List body) {
  final encoded = _encodeBodyText(body);
  return {
    'mimeType': 'application/octet-stream',
    if (encoded.encoding != null) 'encoding': encoded.encoding,
    'text': encoded.text,
  };
}

Map<String, Object?> _harContent(Uint8List? body) {
  if (body == null) {
    return {'mimeType': 'application/octet-stream', 'size': 0};
  }
  final encoded = _encodeBodyText(body);
  return {
    'mimeType': 'application/octet-stream',
    'size': body.length,
    if (encoded.encoding != null) 'encoding': encoded.encoding,
    'text': encoded.text,
  };
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
