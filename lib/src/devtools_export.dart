import 'dart:convert';

import 'session_store.dart';

Map<String, Object?> buildDevToolsSnapshot(
  List<RequestRecord> requests, {
  required String version,
  required bool isFlutterApp,
}) {
  return {
    'devToolsSnapshot': true,
    'devToolsVersion': 'dart-vm-mcp/$version',
    'activeScreenId': 'network',
    'connectedApp': {
      'isFlutterApp': isFlutterApp,
      'isProfileBuild': false,
      'isDartWebApp': false,
      'isRunningOnDartVM': true,
    },
    'network': {
      'httpRequestData': [
        for (final request in requests)
          {'request': jsonDecode(request.rawJson)},
      ],
      'selectedRequestId': null,
      'socketData': <Object?>[],
      'webSocketData': <Object?>[],
      'timelineMicrosOffset': 0,
    },
  };
}
