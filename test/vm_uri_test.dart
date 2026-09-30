import 'package:dart_network_mcp/src/vm_uri.dart';
import 'package:test/test.dart';

void main() {
  test('http console uri becomes the canonical ws uri', () {
    expect(
      canonicalizeVmUri('http://127.0.0.1:8181/abc=/'),
      'ws://127.0.0.1:8181/abc=/ws',
    );
  });

  test('ws uri keeps its path and gains a single /ws suffix', () {
    expect(
      canonicalizeVmUri('ws://127.0.0.1:1/x=/ws'),
      'ws://127.0.0.1:1/x=/ws',
    );
    expect(
      canonicalizeVmUri('ws://127.0.0.1:1/x='),
      'ws://127.0.0.1:1/x=/ws',
    );
  });

  test('https maps to wss and other schemes are rejected', () {
    expect(canonicalizeVmUri('https://h:1/a/'), 'wss://h:1/a/ws');
    expect(() => canonicalizeVmUri('ftp://h/a'), throwsFormatException);
  });
}
