import 'package:dart_network_mcp/src/data_dir.dart';
import 'package:test/test.dart';

void main() {
  test('DART_NETWORK_MCP_DATA wins', () {
    expect(
      resolveDataDirectory({'DART_NETWORK_MCP_DATA': '/data', 'HOME': '/home/a'}),
      '/data',
    );
  });

  test('LOCALAPPDATA is the windows default', () {
    expect(
      resolveDataDirectory({'LOCALAPPDATA': r'C:\Users\a\AppData\Local'}),
      r'C:\Users\a\AppData\Local\dart-network-mcp',
    );
  });

  test('home fallback is .local/share', () {
    expect(
      resolveDataDirectory({'HOME': '/Users/a'}),
      '/Users/a/.local/share/dart-network-mcp',
    );
  });
}
