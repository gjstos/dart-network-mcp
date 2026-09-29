import 'dart:convert';

String encodeJson(Map<String, Object?> value) => jsonEncode(value);

Map<String, Object?> toolError(
  String code,
  String message, {
  String? vmUri,
}) {
  return {
    'error': {
      'code': code,
      'message': message,
      if (vmUri != null) 'vmUri': vmUri,
    },
  };
}
