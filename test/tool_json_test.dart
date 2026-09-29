import 'package:dart_network_mcp/src/tool_json.dart';
import 'package:test/test.dart';

void main() {
  test('error json includes code and vmUri', () {
    final encoded = encodeJson(
      toolError('vm_not_found', 'missing', vmUri: 'ws://x'),
    );
    expect(encoded, contains('"code":"vm_not_found"'));
    expect(encoded, contains('"vmUri":"ws://x"'));
  });
}
