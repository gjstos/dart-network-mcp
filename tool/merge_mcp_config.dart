import 'dart:convert';
import 'dart:io';

import 'package:dart_network_mcp/src/mcp_config_merge.dart';

void main(List<String> args) {
  if (args.length == 2 && args[0] == '--strip') {
    final file = File(args[1]);
    if (!file.existsSync()) {
      return;
    }
    final config =
        (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
    final stripped = removeOurMcpServers(config);
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(stripped));
    return;
  }
  if (args.length != 2) {
    stderr.writeln(
      'Usage: merge_mcp_config.dart <config-file> <entry-json> | --strip <config-file>',
    );
    exit(1);
  }
  final path = args[0];
  final entry = (jsonDecode(args[1]) as Map).cast<String, Object?>();
  final file = File(path);
  Map<String, Object?> config;
  if (file.existsSync()) {
    config = (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
  } else {
    config = {};
  }
  final merged = mergeMcpServerEntry(config, entry);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(merged));
}
