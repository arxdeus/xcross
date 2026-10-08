import 'package:repo_analyzer/src/rules/declaration_rules.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'support/rule_test_base.dart';

const _p = ArchitectureRuleTest.platform;

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(PrivateTypeRuleTest);
    defineReflectiveTests(DirectImportRuleTest);
    defineReflectiveTests(MissingInternalRuleTest);
    defineReflectiveTests(GlobalServiceRuleTest);
    defineReflectiveTests(HiddenDependencyRuleTest);
    defineReflectiveTests(TargetHostBoundRuleTest);
  });
}

@reflectiveTest
class PrivateTypeRuleTest extends ArchitectureRuleTest {
  @override
  void setUp() {
    rule = PrivateTypeRule();
    super.setUp();
  }

  Future<void> test_privateClassLikes() async {
    const src =
        'class _A {} mixin _B {} enum _C { v } extension type _D(int v) {} mixin M {} class _E = Object with M;';
    await check(src, [
      at(src, '_A'),
      at(src, '_B'),
      at(src, '_C'),
      at(src, '_D'),
      at(src, '_E'),
    ]);
  }

  Future<void> test_privateMembersAllowed() async {
    await clean('class Helper { final int _v = 1; int _read() => _v; }');
  }

  Future<void> test_testsChecked() async {
    const src = 'class _TestDouble {}';
    await check(src, [at(src, '_TestDouble')], path: 'test/fake_test.dart');
  }
}

@reflectiveTest
class DirectImportRuleTest extends ArchitectureRuleTest {
  @override
  void setUp() {
    rule = DirectImportRule();
    super.setUp();
    support('lib/src/shared/other.dart', 'class Other {} class Hidden {}');
  }

  Future<void> test_export() async {
    const src = "export 'other.dart';";
    await check(src, [at(src, 'export')]);
  }

  Future<void> test_showAndHide() async {
    const src =
        "import 'other.dart' show Other; import 'other.dart' as o hide Hidden; Other? a; o.Other? b;";
    await check(src, [at(src, 'show'), at(src, 'hide')]);
  }

  Future<void> test_stringsAndCommentsIgnored() async {
    await clean(
      "// export 'x.dart';\nconst text = \"export 'x.dart'; import 'x.dart' hide Y;\";",
    );
  }
}

@reflectiveTest
class MissingInternalRuleTest extends ArchitectureRuleTest {
  @override
  void setUp() {
    rule = MissingInternalRule();
    super.setUp();
  }

  Future<void> test_srcDeclarationsRequireInternal() async {
    const src =
        "import 'package:meta/meta.dart'; class Bare {} @internal class Marked {} void helper() {} const value = 1; typedef Alias = int; class _Private {}";
    await check(src, [
      at(src, 'Bare'),
      at(src, 'helper'),
      at(src, 'value'),
      at(src, 'Alias'),
    ]);
  }

  Future<void> test_internalLibraryCoversDeclarations() async {
    await clean(
      "@internal\nlibrary;\nimport 'package:meta/meta.dart'; class Bare {} void helper() {}",
    );
  }

  Future<void> test_publicApiNeedsNothing() async {
    await clean('class Contract {}', path: 'lib/shared/contract.dart');
  }

  Future<void> test_testHelpersRequireInternal() async {
    const src = 'void main() {} class FakeHost {}';
    await check(src, [at(src, 'FakeHost')], path: 'test/host_test.dart');
  }

  Future<void> test_testSupportLibrariesMayBePublic() async {
    await clean('class PbzxChunk {}', path: 'test/test_fixtures.dart');
  }

  Future<void> test_toolHelpersRequireInternal() async {
    const src = 'void main() {} String render() => "";';
    await check(src, [at(src, 'render')], path: 'tool/build.dart');
  }
}

@reflectiveTest
class GlobalServiceRuleTest extends ArchitectureRuleTest {
  @override
  void setUp() {
    rule = GlobalServiceRule();
    super.setUp();
  }

  static const _log =
      'abstract interface class LogOutput { void write(String m); } class Log { final LogOutput output; Log(this.output); }';

  Future<void> test_globalService() async {
    const src = '$_log late final Log logger;';
    await check(src, [at(src, 'logger')]);
  }

  Future<void> test_globalServiceSubtype() async {
    const src =
        '$_log class CustomLog extends Log { CustomLog(super.output); } late CustomLog activeLog;';
    await check(src, [at(src, 'activeLog')]);
  }

  Future<void> test_staticService() async {
    const src = '$_log class Holder { static Log? shared; }';
    await check(src, [at(src, 'shared')]);
  }

  Future<void> test_platformHostGlobal() async {
    const src = '$_p PlatformHostInterface? currentHost;';
    await check(src, [at(src, 'currentHost')]);
  }

  Future<void> test_descriptorGlobalAllowed() async {
    await clean(
      'abstract interface class Formatter { String format(String v); } class Upper implements Formatter { const Upper(); @override String format(String v) => v; } const Formatter formatter = Upper();',
    );
  }

  Future<void> test_valueGlobalsAllowed() async {
    await clean("const name = 'xcross'; final pattern = RegExp('x');");
  }
}

@reflectiveTest
class HiddenDependencyRuleTest extends ArchitectureRuleTest {
  @override
  void setUp() {
    rule = HiddenDependencyRule();
    super.setUp();
  }

  /// `Log` is a service because it wraps an effect port; its own default
  /// output is supplied by a composition-owned factory.
  static const _log =
      'abstract interface class LogOutput { void write(String m); } class Log { final LogOutput output; Log(this.output); } Log createLog() => throw 0;';

  Future<void> test_fieldInitializer() async {
    const src = '$_log class Service { final Log log = createLog(); }';
    await check(src, [at(src, 'createLog()', skip: 1)]);
  }

  Future<void> test_constructorInitializer() async {
    const src =
        '$_log class Service { final Log log; Service() : log = createLog(); }';
    await check(src, [at(src, 'log = createLog()')]);
  }

  Future<void> test_nullFallback() async {
    const src =
        '$_log class Service { final Log log; Service({Log? log}) : log = log ?? createLog(); }';
    await check(src, [at(src, 'log = log ?? createLog()')]);
  }

  Future<void> test_factoryDefault() async {
    const src =
        "import 'dart:io'; class Service { final HttpClient Function() create; Service({this.create = HttpClient.new}); }";
    await check(src, [at(src, 'HttpClient.new')]);
  }

  Future<void> test_explicitInjectionAllowed() async {
    await clean(
      "import 'dart:io'; class Service { final HttpClient Function() create; final HttpClient client; Service({required this.create, required HttpClient Function() factory}) : client = factory(); }",
    );
  }

  Future<void> test_derivedCollaboratorAllowed() async {
    await clean(
      'abstract interface class Runner { Future<void> run(); } class Tunnel { final Runner runner; Tunnel(this.runner); } class Daemon { final Runner runner; final Tunnel tunnel; Daemon(this.runner) : tunnel = Tunnel(runner); }',
    );
  }

  Future<void> test_pureDescriptorDefaultAllowed() async {
    await clean(
      "class IPhoneBuildPlatform { const IPhoneBuildPlatform(); } String sdkPath({IPhoneBuildPlatform input = const IPhoneBuildPlatform()}) => '/sdk';",
    );
  }

  Future<void> test_concreteHostWiresOwnCollaborators() async {
    support(
      'lib/src/host/windows/allocator.dart',
      'abstract interface class Memory { void free(); } class WindowsAllocator { final Memory memory; WindowsAllocator(this.memory); } WindowsAllocator createAllocator() => throw 0;',
    );
    await clean(
      "import 'allocator.dart'; class Loader { late final WindowsAllocator allocator = createAllocator(); }",
      path: 'lib/src/host/windows/loader.dart',
    );
  }

  Future<void> test_sharedCodeCannotWireHostCollaborators() async {
    support(
      'lib/src/host/windows/allocator.dart',
      'abstract interface class Memory { void free(); } class WindowsAllocator { final Memory memory; WindowsAllocator(this.memory); } WindowsAllocator createAllocator() => throw 0;',
    );
    const src =
        "import '../host/windows/allocator.dart'; class Loader { late final WindowsAllocator allocator = createAllocator(); }";
    await check(src, [at(src, 'createAllocator()')]);
  }

  Future<void> test_valueFromInjectedProviderAllowed() async {
    await clean(
      'abstract interface class Port { Future<void> run(); } abstract interface class Provider { Port resolve(); } class Runtime { final Provider provider; Runtime(this.provider); } class Target { final Port port; Target(this.port); } class Features { final Runtime runtime; Features(this.runtime); late final Target target = Target(runtime.provider.resolve()); }',
    );
  }

  Future<void> test_privateBuilderMethodAllowed() async {
    await clean(
      'abstract interface class Port { Future<void> run(); } class Target { final Port port; Target(this.port); } class Features { final Port port; Features(this.port); late final Target target = _build(); Target _build() => Target(port); }',
    );
  }

  Future<void> test_compositionMayConstruct() async {
    await clean(
      '$_log class Wiring { final Log log = createLog(); }',
      path: 'lib/src/composition/wiring.dart',
    );
  }
}

@reflectiveTest
class TargetHostBoundRuleTest extends ArchitectureRuleTest {
  @override
  void setUp() {
    rule = TargetHostBoundRule();
    super.setUp();
  }

  Future<void> test_unbounded() async {
    const src =
        '$_p abstract class BadTarget<T> implements PlatformTargetInterface<T> {}';
    await assertTargetBoundLint(src);
  }

  Future<void> assertTargetBoundLint(String src) async {
    support(defaultPath, src);
    final result = await resolveFile(
      convertPath('$testPackageRootPath/$defaultPath'),
    );
    final names = result.diagnostics.map((d) => d.diagnosticCode.lowerCaseName);
    expect(names, contains('target_host_bound'));
  }

  Future<void> test_bounded() async {
    await clean(
      '$_p abstract class Target<H extends PlatformHostInterface> implements PlatformTargetInterface<H> {}',
    );
  }

  Future<void> test_narrowBound() async {
    await clean(
      '$_p abstract class Target<T extends WindowsHostInterface> implements PlatformTargetInterface<T> {}',
    );
  }

  Future<void> test_holderAllowed() async {
    await clean(
      '$_p abstract class Holder { PlatformTargetInterface<PlatformHostInterface> get target; }',
    );
  }
}
