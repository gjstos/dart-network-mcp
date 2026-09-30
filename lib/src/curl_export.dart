import 'dart:convert';
import 'dart:typed_data';

import 'har_export.dart';

/// Builds a curl command the way Chrome's "Copy as cURL (bash)" does.
///
/// [bodyFile], when set, replaces the inline request body with
/// `--data-binary @file` (used when the body is too large to inline).
String buildCurl(
  ExportableRequest request, {
  String? bodyFile,
  bool includeBody = true,
  bool includeHeaders = true,
  bool dropNoiseHeaders = false,
  bool multiline = true,
}) {
  final parts = <String>[_quote(request.uri)];

  final hasBody = includeBody &&
      (bodyFile != null ||
          (request.requestBody != null && request.requestBody!.isNotEmpty));
  final method = request.method.toUpperCase();
  if (method == 'HEAD') {
    parts.add('--head');
  } else if (!(method == 'GET' && !hasBody) && !(method == 'POST' && hasBody)) {
    parts.add('-X ${_quote(method)}');
  }

  if (includeHeaders) {
    for (final entry in request.requestHeaders.entries) {
      if (dropNoiseHeaders && _isNoise(entry.key)) {
        continue;
      }
      parts.add('-H ${_quote('${entry.key}: ${entry.value}')}');
    }
  }

  if (hasBody) {
    if (bodyFile != null) {
      parts.add('--data-binary ${_quote('@$bodyFile')}');
    } else {
      parts.add(_dataFlag(request.requestBody!));
    }
  }

  if (_acceptsCompression(request.requestHeaders)) {
    parts.add('--compressed');
  }

  return 'curl ${parts.join(multiline ? ' \\\n  ' : ' ')}';
}

bool _isNoise(String name) {
  final lower = name.toLowerCase();
  return lower.startsWith('sec-') ||
      const {
        'content-length',
        'host',
        'connection',
        'user-agent',
        'accept-encoding',
        'accept-language',
      }.contains(lower);
}

bool _acceptsCompression(Map<String, String> headers) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'accept-encoding') {
      return RegExp(r'gzip|br|deflate|zstd').hasMatch(entry.value);
    }
  }
  return false;
}

String _dataFlag(Uint8List body) {
  String text;
  try {
    text = utf8.decode(body);
  } on FormatException {
    return '--data-binary ${_ansiC(body)}';
  }
  return '--data-raw ${_quote(text)}';
}

bool _needsAnsiC(String value) {
  for (final unit in value.codeUnits) {
    if (unit < 0x20 || unit == 0x7f) {
      return true;
    }
  }
  return false;
}

String _quote(String value) {
  if (_needsAnsiC(value)) {
    return _ansiC(utf8.encode(value));
  }
  return "'${value.replaceAll("'", r"'\''")}'";
}

/// Bash `$'...'` quoting: printable ASCII and valid UTF-8 pass through,
/// everything else is escaped as `\xNN`.
String _ansiC(List<int> bytes) {
  final out = StringBuffer(r"$'");
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    switch (b) {
      case 0x27:
        out.write(r"\'");
      case 0x5c:
        out.write(r'\\');
      case 0x0a:
        out.write(r'\n');
      case 0x0d:
        out.write(r'\r');
      case 0x09:
        out.write(r'\t');
      default:
        if (b >= 0x20 && b < 0x7f) {
          out.writeCharCode(b);
        } else {
          out.write('\\x${b.toRadixString(16).padLeft(2, '0')}');
        }
    }
  }
  out.write("'");
  return out.toString();
}
