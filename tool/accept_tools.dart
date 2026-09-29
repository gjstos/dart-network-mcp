import 'dart:convert';
import 'dart:io';

import 'package:dart_network_mcp/src/dart_network_mcp.dart';
import 'package:dart_network_mcp/src/session_store.dart';

/// Live acceptance: one check per MCP tool against a running VM.
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: accept_tools.dart <vmUri>');
    exit(2);
  }
  final vmUri = args.first;
  final dataDir = Directory.systemTemp.createTempSync('dart_network_mcp_tools_').path;
  stdout.writeln('DATA_DIR=$dataDir');
  final store = SessionStore.open('$dataDir/network.sqlite', dataDirectory: dataDir);
  final mcp = DartNetworkMcp(store: store, dataDirectory: dataDir);
  var failed = 0;

  void check(String name, bool ok, Object? detail) {
    stdout.writeln('${ok ? 'PASS' : 'FAIL'} $name ${detail ?? ''}');
    if (!ok) failed++;
  }

  try {
    final attach = await mcp.attachVm(vmUri, inDocker: false);
    check(
      'attach_vm',
      attach['state'] == 'live' && attach['error'] == null,
      attach,
    );
    final canonical = attach['vmUri'] as String? ?? vmUri;

    final sessions = mcp.listSessions();
    final listed = (sessions['sessions'] as List?) ?? const [];
    check(
      'list_sessions',
      listed.any((s) => (s as Map)['vmUri'] == canonical && s['state'] == 'live'),
      sessions,
    );

    final session = mcp.getSession(canonical);
    check(
      'get_session',
      session['state'] == 'live' && session['vmUri'] == canonical,
      session,
    );

    final retention = mcp.getRetention();
    check('get_retention', retention['retentionDays'] == 90, retention);

    final rejected = mcp.setRetention(0);
    final err = rejected['error'];
    check(
      'set_retention_invalid',
      err is Map && err['code'] == 'invalid_params' && mcp.getRetention()['retentionDays'] == 90,
      rejected,
    );
    final kept = mcp.setRetention(90);
    check('set_retention', kept['retentionDays'] == 90, kept);

    Map<String, Object?>? page;
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      page = mcp.listRequests(canonical, limit: 200);
      final reqs = (page['requests'] as List?) ?? const [];
      stdout.writeln('POLL$i count=${reqs.length}');
      if (reqs.length >= 3) break;
    }
    final requests = (page?['requests'] as List?) ?? const [];
    final first = requests.isEmpty ? null : requests.first as Map;
    final listClean = first != null &&
        !first.containsKey('responseBody') &&
        !first.containsKey('requestHeaders') &&
        !first.containsKey('responseBodyPath') &&
        first.containsKey('responseBodySize');
    check('list_requests', listClean && requests.length >= 3, first);

    final detail = mcp.getRequest(canonical, first!['requestId'] as String);
    final request = detail['request'] as Map?;
    final gotBody = request != null &&
        (request.containsKey('responseBody') || request.containsKey('responseBodyPath'));
    check('get_request', detail['error'] == null && gotBody, detail['error'] ?? request?.keys.toList());

    final bodies = Directory('$dataDir/bodies');
    check('bodies_on_disk', bodies.existsSync(), bodies.path);

    final har = mcp.exportHar(canonical);
    final harPath = har['path'] as String?;
    final harOk = harPath != null &&
        File(harPath).existsSync() &&
        File(harPath).readAsStringSync().contains('"version":"1.2"');
    check('export_har', harOk, har);

    final dev = mcp.exportDevToolsJson(canonical);
    final devPath = dev['path'] as String?;
    var devOk = false;
    if (devPath != null && File(devPath).existsSync()) {
      final decoded = jsonDecode(File(devPath).readAsStringSync());
      devOk = decoded is Map && decoded['devToolsSnapshot'] == true;
    }
    check('export_devtools_json', devOk, dev);

    final deleted = await mcp.deleteSession(canonical);
    final after = mcp.getSession(canonical);
    final afterErr = after['error'];
    check(
      'delete_session',
      deleted['deleted'] == true && afterErr is Map && afterErr['code'] == 'vm_not_found',
      {'deleted': deleted, 'after': after},
    );
    check('bodies_removed', !bodies.existsSync(), bodies.path);
  } finally {
    await mcp.dispose();
    store.close();
  }

  stdout.writeln(failed == 0 ? 'ACCEPT_PASS' : 'ACCEPT_FAIL count=$failed');
  exit(failed == 0 ? 0 : 1);
}
