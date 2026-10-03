import 'package:cli_kit/cli_kit.dart';
import 'package:test/test.dart';

void main() {
  test('native permission adapters preserve modes without shell tools', () {
    final calls = <(String, String)>[];
    void chmod(String path, String mode) => calls.add((path, mode));
    final adapters = <HostPermissionsInterface>[
      LinuxPermissions(chmod: chmod),
      MacOSPermissions(chmod: chmod),
    ];
    for (final adapter in adapters) {
      adapter.setPermissions('/injected/file', 0x1ed);
      adapter.setPermissions('/injected/file', 0x9ed);
    }
    expect(calls, [
      ('/injected/file', '0755'),
      ('/injected/file', '4755'),
      ('/injected/file', '0755'),
      ('/injected/file', '4755'),
    ]);
  });
}
