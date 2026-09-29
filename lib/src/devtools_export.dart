import 'har_export.dart';

Map<String, Object?> buildDevToolsSnapshot(
  List<ExportableRequest> requests, {
  required String version,
  required bool isFlutterApp,
}) {
  return {
    'devToolsSnapshot': true,
    'devToolsVersion': 'dart-network-mcp/$version',
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
          {'request': devToolsRequest(request)},
      ],
      'selectedRequestId': null,
      'socketData': <Object?>[],
      'webSocketData': <Object?>[],
      'timelineMicrosOffset': 0,
    },
  };
}

Map<String, Object?> devToolsRequest(ExportableRequest request) {
  return {
    'id': request.requestId,
    'method': request.method,
    'uri': request.uri,
    'startTime': request.startTime,
    'endTime': request.endTime,
    if (request.requestBody != null) 'requestBody': request.requestBody,
    if (request.responseBody != null) 'responseBody': request.responseBody,
  };
}
