import 'package:test_reflective_loader/test_reflective_loader.dart';
import 'package:repo_analyzer/src/rules/dependency_rules.dart';

import 'support/rule_test_base.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(CompositionEdgeRuleTest);
    defineReflectiveTests(ConcretePlatformEdgeRuleTest);
    defineReflectiveTests(LibraryLayoutRuleTest);
    defineReflectiveTests(ThinEntrypointRuleTest);
  });
}

@reflectiveTest
class CompositionEdgeRuleTest extends ArchitectureRuleTest {
  @override
  void setUp() {
    rule = CompositionEdgeRule();
    super.setUp();
    support('lib/src/composition/runtime.dart', 'Object compose() => 1;');
  }

  Future<void> test_sharedImportsComposition() async {
    const src =
        "import 'package:test/src/composition/runtime.dart'; Object f() => compose();";
    await check(src, [at(src, "'package:test/src/composition/runtime.dart'")]);
  }

  Future<void> test_relativeImport() async {
    const src =
        "import '../composition/runtime.dart'; Object f() => compose();";
    await check(src, [at(src, "'../composition/runtime.dart'")]);
  }

  Future<void> test_compositionMayImportComposition() async {
    await clean(
      "import 'runtime.dart'; Object f() => compose();",
      path: 'lib/src/composition/application.dart',
    );
  }

  Future<void> test_entrypointMayImportComposition() async {
    await clean(
      "import 'package:test/src/composition/runtime.dart'; void main() => compose();",
      path: 'bin/app.dart',
    );
  }

  Future<void> test_testsMayImportComposition() async {
    await clean(
      "import 'package:test/src/composition/runtime.dart'; void main() => compose();",
      path: 'test/runtime_test.dart',
    );
  }
}

@reflectiveTest
class ConcretePlatformEdgeRuleTest extends ArchitectureRuleTest {
  @override
  void setUp() {
    rule = ConcretePlatformEdgeRule();
    super.setUp();
    support(
      'lib/src/host/windows/exit_diagnostic.dart',
      'class WindowsExitDiagnostic {}',
    );
    support('lib/src/target/iphone/device.dart', 'class IPhoneDevice {}');
  }

  Future<void> test_sharedReachesHost() async {
    const src =
        "import '../../host/windows/exit_diagnostic.dart'; Object d() => WindowsExitDiagnostic();";
    await check(src, [
      at(src, "'../../host/windows/exit_diagnostic.dart'"),
    ], path: 'lib/src/shared/process/windows_exit_import.dart');
  }

  Future<void> test_hostSharedReachesConcreteHost() async {
    const src =
        "import '../windows/exit_diagnostic.dart'; Object d() => WindowsExitDiagnostic();";
    await check(src, [
      at(src, "'../windows/exit_diagnostic.dart'"),
    ], path: 'lib/src/host/shared/windows_exit_import.dart');
  }

  Future<void> test_siblingHost() async {
    const src =
        "import '../windows/exit_diagnostic.dart'; Object d() => WindowsExitDiagnostic();";
    await check(src, [
      at(src, "'../windows/exit_diagnostic.dart'"),
    ], path: 'lib/src/host/linux/windows_exit_import.dart');
  }

  Future<void> test_sharedReachesTarget() async {
    const src =
        "import 'package:test/src/target/iphone/device.dart'; Object d() => IPhoneDevice();";
    await check(src, [at(src, "'package:test/src/target/iphone/device.dart'")]);
  }

  Future<void> test_sameHostAllowed() async {
    await clean(
      "import 'exit_diagnostic.dart'; Object d() => WindowsExitDiagnostic();",
      path: 'lib/src/host/windows/user.dart',
    );
  }

  Future<void> test_targetUnderHostAllowed() async {
    await clean(
      "import '../../exit_diagnostic.dart'; Object d() => WindowsExitDiagnostic();",
      path: 'lib/src/host/windows/target/iphone/bridge.dart',
    );
  }

  Future<void> test_compositionMayWire() async {
    await clean(
      "import '../host/windows/exit_diagnostic.dart'; import '../target/iphone/device.dart'; Object d() => [WindowsExitDiagnostic(), IPhoneDevice()];",
      path: 'lib/src/composition/host_operations.dart',
    );
  }

  Future<void> test_reExportLeakIsSeen() async {
    support(
      'lib/src/shared/barrel.dart',
      "export '../host/windows/exit_diagnostic.dart';",
    );
    const src = "import 'barrel.dart'; Object d() => WindowsExitDiagnostic();";
    await check(src, [at(src, "'barrel.dart'")]);
  }

  Future<void> test_sharedContractAllowed() async {
    support('lib/shared/process/port.dart', 'abstract class ProcessPort {}');
    await clean(
      "import 'package:test/shared/process/port.dart'; ProcessPort? p;",
      path: 'lib/src/host/windows/impl.dart',
    );
  }
}

@reflectiveTest
class LibraryLayoutRuleTest extends ArchitectureRuleTest {
  @override
  void setUp() {
    rule = LibraryLayoutRule();
    super.setUp();
  }

  Future<void> test_unknownLayer() async {
    const src = 'class Policy {}';
    await check(src, [lint(0, 5)], path: 'lib/src/legacy/policy.dart');
  }

  Future<void> test_topLevelLibrary() async {
    const src = 'class Policy {}';
    await check(src, [lint(0, 5)], path: 'lib/policy.dart');
  }

  Future<void> test_hostWithoutOwner() async {
    const src = 'class Policy {}';
    await check(src, [lint(0, 5)], path: 'lib/src/host/policy.dart');
  }

  Future<void> test_knownLayers() async {
    for (final path in [
      'lib/composition/apple_host.dart',
      'lib/src/composition/cli/runner.dart',
      'lib/shared/logging.dart',
      'lib/src/shared/policy.dart',
      'lib/host/windows/windows_host.dart',
      'lib/src/host/shared/posix.dart',
      'lib/target/iphone/iphone_target.dart',
      'lib/src/host/macos/target/simulator/bridge.dart',
    ]) {
      await clean('class Policy {}', path: path);
    }
  }

  Future<void> test_nonLibraryZonesIgnored() async {
    await clean('void main() {}', path: 'bin/app.dart');
    await clean('void main() {}', path: 'test/app_test.dart');
  }
}

@reflectiveTest
class ThinEntrypointRuleTest extends ArchitectureRuleTest {
  @override
  void setUp() {
    rule = ThinEntrypointRule();
    super.setUp();
  }

  Future<void> test_tooManyDeclarations() async {
    const src = 'void main() {} void a() {} void b() {}';
    await check(src, [at(src, 'main')], path: 'bin/app.dart');
  }

  Future<void> test_delegatingMain() async {
    await clean(
      'void main(List<String> args) => run(args); void run(List<String> args) {}',
      path: 'bin/app.dart',
    );
  }
}
