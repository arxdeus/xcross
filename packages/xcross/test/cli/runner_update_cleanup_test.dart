import 'package:test/test.dart';
import 'package:xcross/src/cli/runner.dart';
import 'package:xcross/src/update/install_layout.dart';
import 'package:xcross/src/version.dart';

void main() {
  group('sweepUpdateLeftovers', () {
    const layout = InstallLayout(
      binaryPath: '/opt/xcross/bin/xcross',
      binDir: '/opt/xcross/bin',
      libDir: '/opt/xcross/lib',
    );

    test('runs for an installed layout even for a dev build', () {
      expect(XcrossVersion.isDev, isTrue);
      final swept = <InstallLayout>[];

      sweepUpdateLeftovers(resolveLayout: () => layout, sweep: swept.add);

      expect(swept, [layout]);
    });

    test('keeps layout and sweep errors best-effort', () {
      expect(
        () => sweepUpdateLeftovers(
          resolveLayout: () => throw StateError('not installed'),
          sweep: (_) => fail('sweep must not run'),
        ),
        returnsNormally,
      );
      expect(
        () => sweepUpdateLeftovers(
          resolveLayout: () => layout,
          sweep: (_) => throw StateError('cleanup failed'),
        ),
        returnsNormally,
      );
    });
  });
}
