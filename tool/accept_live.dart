import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_vm_mcp/src/dart_vm_mcp.dart';
import 'package:dart_vm_mcp/src/session_store.dart';

/// Long-lived Task 15 acceptance driver (native, not Docker).
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: accept_live.dart <vmUriHttpOrWs>');
    exit(2);
  }
  final vmUri = args.first;
  final dataDir = Directory.systemTemp.createTempSync('dart_vm_mcp_accept_').path;
  stdout.writeln('DATA_DIR=$dataDir');
  final store = SessionStore.open('$dataDir/network.sqlite');
  final mcp = DartVmMcp(store: store, dataDirectory: dataDir);

  Future<void> dump(String label, Map<String, Object?> map) async {
    stdout.writeln('=== $label ===');
    stdout.writeln(jsonEncode(map));
  }

  try {
    await dump('attach', await mcp.attachVm(vmUri, inDocker: false));

    Map<String, Object?> list({bool history = false, String? url}) {
      return mcp.listRequests(
        vmUri,
        includeHistory: history,
        limit: 200,
        urlContains: url,
      );
    }

    // Step 3: wait for opening GETs
    var step3Ok = false;
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final r = list();
      final reqs = (r['requests'] as List?) ?? const [];
      final uris = reqs.map((e) => (e as Map)['uri'] as String).toList();
      final hasPosts = uris.any((u) => u.contains('/posts/1'));
      final hasUsers = uris.any((u) => u.contains('/users/1'));
      final hasAlbums = uris.any((u) => u.contains('/albums/1'));
      stdout.writeln(
        'STEP3_POLL$i total=${reqs.length} posts=$hasPosts users=$hasUsers albums=$hasAlbums',
      );
      if (hasPosts && hasUsers && hasAlbums) {
        step3Ok = true;
        await dump('list_opening', r);
        break;
      }
    }
    stdout.writeln('STEP3=${step3Ok ? "PASS" : "FAIL"}');

    // Step 4: wait for batch (POST/PUT/PATCH or DELETE)
    var step4Ok = false;
    final before = ((list()['requests'] as List?) ?? const []).length;
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final r = list();
      final reqs = (r['requests'] as List?) ?? const [];
      final methods = reqs.map((e) => (e as Map)['method'] as String).toSet();
      final hasWrite = methods.contains('POST') ||
          methods.contains('PUT') ||
          methods.contains('PATCH') ||
          methods.contains('DELETE');
      stdout.writeln(
        'STEP4_POLL$i total=${reqs.length} (was $before) writes=$hasWrite methods=$methods',
      );
      if (reqs.length > before && hasWrite) {
        step4Ok = true;
        await dump('list_batch', r);
        break;
      }
    }
    stdout.writeln('STEP4=${step4Ok ? "PASS" : "FAIL"}');

    // Step 5: hot reload signal — wait for parent to send "reload" on stdin
    stdout.writeln('WAIT_RELOAD');
    stdout.flush();
    final lines = stdin.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
    final reloadLine = await lines.first;
    stdout.writeln('GOT_RELOAD=$reloadLine');
    final beforeReload = ((list()['requests'] as List?) ?? const []).length;
    var step5Ok = false;
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final r = list();
      final total = ((r['requests'] as List?) ?? const []).length;
      stdout.writeln('STEP5_POLL$i total=$total (was $beforeReload)');
      if (total > beforeReload) {
        step5Ok = true;
        break;
      }
    }
    final sessionAfterReload = mcp.getSession(vmUri);
    await dump('session_after_reload', sessionAfterReload);
    stdout.writeln('STEP5=${step5Ok && sessionAfterReload['state'] == 'live' ? "PASS" : "FAIL"}');

    // Step 6: hot restart
    stdout.writeln('WAIT_RESTART');
    stdout.flush();
    final restartLine = await lines.first;
    stdout.writeln('GOT_RESTART=$restartLine');
    final beforeRestart = list();
    final beforeCount = ((beforeRestart['requests'] as List?) ?? const []).length;
    final beforeStarts = ((beforeRestart['requests'] as List?) ?? const [])
        .whereType<Map>()
        .where((e) => (e['uri'] as String).contains('/posts/1'))
        .map((e) => e['startTime'] as int)
        .toSet();
    var step6Ok = false;
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final r = list();
      final reqs = (r['requests'] as List?) ?? const [];
      final postStarts = reqs
          .whereType<Map>()
          .where((e) => (e['uri'] as String).contains('/posts/1') && e['method'] == 'GET')
          .map((e) => e['startTime'] as int)
          .toSet();
      final newStarts = postStarts.difference(beforeStarts);
      stdout.writeln(
        'STEP6_POLL$i total=${reqs.length} (was $beforeCount) newPostStarts=${newStarts.length}',
      );
      if (reqs.length >= beforeCount && newStarts.isNotEmpty) {
        step6Ok = true;
        await dump('list_after_restart', r);
        break;
      }
    }
    stdout.writeln('STEP6=${step6Ok ? "PASS" : "FAIL"}');

    // Step 7: wait for stop + socket close
    stdout.writeln('WAIT_STOP');
    stdout.flush();
    final stopLine = await lines.first;
    stdout.writeln('GOT_STOP=$stopLine');
    var step7History = false;
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final s = mcp.getSession(vmUri);
      stdout.writeln('STEP7_SESSION_POLL$i state=${s['state']} reason=${s['disconnectReason']}');
      if (s['state'] == 'history') {
        step7History = true;
        await dump('session_history', s);
        break;
      }
    }
    final noHist = list(history: false);
    final withHist = list(history: true);
    await dump('list_no_history', noHist);
    await dump('list_with_history', withHist);
    final err = noHist['error'];
    final flagOk = err is Map && err['code'] == 'history_requires_flag';
    final histRows = ((withHist['requests'] as List?) ?? const []).isNotEmpty;
    stdout.writeln(
      'STEP7=${step7History && flagOk && histRows ? "PASS" : "FAIL"} history=$step7History flag=$flagOk rows=$histRows',
    );

    // Step 8: exports
    final har = mcp.exportHar(vmUri, includeHistory: true);
    final dev = mcp.exportDevToolsJson(vmUri, includeHistory: true);
    await dump('export_har', har);
    await dump('export_devtools', dev);
    final harPath = har['path'] as String?;
    final devPath = dev['path'] as String?;
    final harOk = harPath != null && File(harPath).existsSync();
    final devOk = devPath != null && File(devPath).existsSync();
    stdout.writeln('STEP8=${harOk && devOk ? "PASS" : "FAIL"} har=$harOk dev=$devOk');
    stdout.writeln('DONE');
  } finally {
    await mcp.dispose();
    store.close();
  }
}
