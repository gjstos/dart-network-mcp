import 'package:dart_vm_mcp/src/data_dir.dart';
import 'package:test/test.dart';

void main() {
  test('DART_VM_MCP_DATA wins', () {
    expect(
      resolveDataDirectory({'DART_VM_MCP_DATA': '/data', 'HOME': '/home/a'}),
      '/data',
    );
  });

  test('LOCALAPPDATA is the windows default', () {
    expect(
      resolveDataDirectory({'LOCALAPPDATA': r'C:\Users\a\AppData\Local'}),
      r'C:\Users\a\AppData\Local\dart-vm-mcp',
    );
  });

  test('home fallback is .local/share', () {
    expect(
      resolveDataDirectory({'HOME': '/Users/a'}),
      '/Users/a/.local/share/dart-vm-mcp',
    );
  });
}
