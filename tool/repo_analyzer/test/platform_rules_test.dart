import 'package:repo_analyzer/src/rules/native_access_rules.dart';
import 'package:repo_analyzer/src/rules/platform_dispatch_rules.dart';
import 'package:repo_analyzer/src/rules/platform_rules.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'support/rule_test_base.dart';

const _p = ArchitectureRuleTest.platform;

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(PlatformBranchRuleTest);
    defineReflectiveTests(PlatformIdentityBoolRuleTest);
    defineReflectiveTests(PlatformRegistryRuleTest);
    defineReflectiveTests(PlatformVisitorRuleTest);
    defineReflectiveTests(PlatformCallbackDispatchRuleTest);
    defineReflectiveTests(AmbientPlatformStateRuleTest);
    defineReflectiveTests(HiddenPlatformDetectionRuleTest);
    defineReflectiveTests(NativeAcquisitionRuleTest);
  });
}

@reflectiveTest
class PlatformBranchRuleTest extends ArchitectureRuleTest {
  @override
  void setUp() {
    rule = PlatformBranchRule();
    super.setUp();
  }

  Future<void> test_operatingSystemComparison() async {
    const src =
        "$_p void build(PlatformHostInterface host) { if (host.operatingSystem == 'windows') print('x'); }";
    await check(src, [at(src, "host.operatingSystem == 'windows'")]);
  }

  Future<void> test_renamedAlias() async {
    const src =
        "$_p void build(PlatformHostInterface host) { final label = host.operatingSystem; final second = label; if (second == 'linux') print('x'); }";
    await check(src, [at(src, "second == 'linux'")]);
  }

  Future<void> test_assignedDiscriminator() async {
    const src =
        "$_p void build(PlatformHostInterface host) { bool renamed = false; renamed = host.operatingSystem == 'windows'; if (renamed) print('x'); }";
    await check(src, [at(src, 'renamed', skip: 2)]);
  }

  Future<void> test_typeTest() async {
    const src =
        "$_p void build(Object host) { if (host is WindowsHostInterface) print('x'); }";
    await check(src, [at(src, 'host is WindowsHostInterface')]);
  }

  Future<void> test_typedefAlias() async {
    const src =
        "$_p typedef Renamed = WindowsHostInterface; void build(Object host) { if (host is Renamed) print('x'); }";
    await check(src, [at(src, 'host is Renamed')]);
  }

  Future<void> test_ifCase() async {
    const src =
        "$_p void build(Object host) { if (host case WindowsHostInterface()) print('x'); }";
    await check(src, [at(src, 'WindowsHostInterface()')]);
  }

  Future<void> test_literalSwitch() async {
    const src =
        "void build(String renamed) { switch (renamed) { case 'windows': print('x'); } }";
    await check(src, [at(src, "'windows'")]);
  }

  Future<void> test_collectionIf() async {
    const src =
        "$_p List<String> args(PlatformHostInterface host) => [if (host.operatingSystem == 'windows') '/c' else '-c'];";
    await check(src, [
      at(src, "if (host.operatingSystem == 'windows') '/c' else '-c'"),
    ]);
  }

  Future<void> test_loops() async {
    const src =
        "$_p void build(PlatformHostInterface host) { while (host.operatingSystem.startsWith('win')) { break; } for (; host.operatingSystem.startsWith('win');) { break; } do {} while (host.operatingSystem.startsWith('win')); }";
    await check(src, [
      at(src, "host.operatingSystem.startsWith('win')"),
      at(src, "host.operatingSystem.startsWith('win')", skip: 1),
      at(src, "host.operatingSystem.startsWith('win')", skip: 2),
    ]);
  }

  Future<void> test_architectureDispatchInSharedCode() async {
    const src =
        "$_p void build(PlatformHostInterface host) { if (host.architecture == 'arm64') print('compiler'); }";
    await check(src, [at(src, "host.architecture == 'arm64'")]);
  }

  Future<void> test_targetDispatch() async {
    const src =
        "$_p void build(IosBuildPlatformInterface target) { if (target.sdkName == 'iphoneos') print('sign'); }";
    await check(src, [at(src, "target.sdkName == 'iphoneos'")]);
  }

  Future<void> test_targetValidationAllowed() async {
    await clean(
      "$_p void verify(String requested, IosBuildPlatformInterface target) { if (requested != target.sdkName) throw ArgumentError('missing'); }",
    );
  }

  Future<void> test_hostArchitectureMetadataAllowed() async {
    await clean(
      "$_p String asset(PlatformHostInterface host) { if (host.architecture == 'x64') return 'windows-x64.zip'; throw UnsupportedError('cpu'); }",
      path: 'lib/src/host/windows/release_metadata.dart',
    );
  }

  Future<void> test_hostArchitectureSwitchMetadataAllowed() async {
    await clean(
      "$_p String asset(PlatformHostInterface host) => switch (host.architecture) { 'arm64' => 'linux-arm64.tar.gz', _ => throw UnsupportedError('cpu') };",
      path: 'lib/src/host/linux/asset_mapping.dart',
    );
  }

  Future<void> test_hostArchitectureEffectRejected() async {
    const src =
        "$_p String backend(PlatformHostInterface host) { if (host.architecture == 'x64') return build(); throw UnsupportedError('cpu'); } String build() => 'effect';";
    await check(src, [
      at(src, "host.architecture == 'x64'"),
    ], path: 'lib/src/host/windows/release_metadata.dart');
  }

  Future<void> test_snapshotAbi() async {
    const src =
        "import 'dart:ffi'; class NativeHostSnapshot { final Abi abi; NativeHostSnapshot(this.abi); } void build(NativeHostSnapshot snapshot) { if (snapshot.abi == Abi.linuxX64) print('linux tool'); }";
    await check(src, [at(src, 'snapshot.abi == Abi.linuxX64')]);
  }

  Future<void> test_abiDescriptorsAllowed() async {
    await clean(
      "import 'dart:ffi'; String arch(Abi abi) => switch (abi) { Abi.linuxX64 || Abi.macosX64 => 'x64', _ => 'other' };",
    );
  }

  Future<void> test_ordinaryPathTransform() async {
    await clean(
      "void check(String path) { final normalized = path.toLowerCase(); if (normalized.startsWith('/sdk')) print('path'); }",
    );
  }

  Future<void> test_ordinaryFlags() async {
    await clean('void build(bool debug, bool ipa) { if (debug) print(ipa); }');
  }

  Future<void> test_compositionMaySelect() async {
    await clean(
      "$_p void build(PlatformHostInterface host) { if (host.operatingSystem == 'windows') print('x'); }",
      path: 'lib/src/composition/runtime.dart',
    );
  }

  Future<void> test_entrypointMaySelect() async {
    await clean(
      "$_p void main() {} void build(PlatformHostInterface host) { if (host.operatingSystem == 'windows') print('x'); }",
      path: 'bin/tool.dart',
    );
  }

  Future<void> test_testsAreExempt() async {
    await clean(
      "$_p void build(PlatformHostInterface host) { if (host.operatingSystem == 'windows') print('x'); }",
      path: 'test/subject_test.dart',
    );
  }
}

@reflectiveTest
class PlatformIdentityBoolRuleTest extends ArchitectureRuleTest {
  @override
  void setUp() {
    rule = PlatformIdentityBoolRule();
    super.setUp();
  }

  Future<void> test_parameter() async {
    const src = 'void build({required bool isSimulator}) {}';
    await check(src, [at(src, 'required bool isSimulator')]);
  }

  Future<void> test_inferredGetter() async {
    const src =
        "$_p class Service { final PlatformHostInterface host; Service(this.host); bool get compatible => host.operatingSystem == 'windows'; }";
    await check(src, [at(src, 'compatible')]);
  }

  Future<void> test_variable() async {
    const src =
        "$_p void build(PlatformHostInterface host) { final windows = host.operatingSystem == 'windows'; print(windows); }";
    await check(src, [at(src, 'windows')]);
  }

  Future<void> test_identityFlagName() async {
    const src = 'class Config { final bool isWindows = false; }';
    await check(src, [at(src, 'isWindows')]);
  }

  Future<void> test_hostArchitectureCapabilityAllowed() async {
    await clean(
      "$_p class Host { final PlatformHostInterface host; Host(this.host); bool get supported => host.architecture == 'arm64'; }",
      path: 'lib/src/host/linux/capability.dart',
    );
  }

  Future<void> test_ordinaryBooleans() async {
    await clean('bool verbose = false; bool get ready => verbose;');
  }
}

@reflectiveTest
class PlatformRegistryRuleTest extends ArchitectureRuleTest {
  @override
  void setUp() {
    rule = PlatformRegistryRule();
    super.setUp();
  }

  Future<void> test_strategyRegistry() async {
    const src = "final strategies = {'windows': () => 1, 'linux': () => 2};";
    await check(src, [
      at(src, "'windows': () => 1"),
      at(src, "'linux': () => 2"),
    ]);
  }

  Future<void> test_metadataAllowed() async {
    await clean("const labels = {'windows': 'Windows', 'linux': 'Linux'};");
  }
}

@reflectiveTest
class PlatformVisitorRuleTest extends ArchitectureRuleTest {
  @override
  void setUp() {
    rule = PlatformVisitorRule();
    super.setUp();
  }

  Future<void> test_visitMethods() async {
    const src =
        'class Dispatcher { void visitWindows() {} void visitLinux() {} }';
    await check(src, [at(src, 'Dispatcher')]);
  }

  Future<void> test_hostVisitorName() async {
    const src = 'class HostVisitor { void visit() {} }';
    await check(src, [at(src, 'HostVisitor')]);
  }

  Future<void> test_acceptDeclaration() async {
    const src =
        '$_p abstract class Host implements PlatformHostInterface { void accept(Object visitor) {} }';
    await check(src, [at(src, 'accept')]);
  }

  Future<void> test_renamedMethodObject() async {
    const src =
        '$_p abstract class Choices { int first(WindowsHostInterface host); int second(LinuxHostInterface host); }';
    await check(src, [at(src, 'Choices')]);
  }

  Future<void> test_unrelatedVisitor() async {
    await clean('class TreeVisitor { void visit(int pid) {} }');
  }

  Future<void> test_ordinaryAccept() async {
    await clean(
      "void which({bool Function(String)? accept}) { if (accept != null) accept('file'); }",
    );
  }
}

@reflectiveTest
class PlatformCallbackDispatchRuleTest extends ArchitectureRuleTest {
  @override
  void setUp() {
    rule = PlatformCallbackDispatchRule();
    super.setUp();
  }

  Future<void> test_twoCallbacks() async {
    const src =
        '$_p abstract class Host implements PlatformHostInterface { int route(int Function() first, int Function() second) => first(); }';
    await check(src, [at(src, 'route')]);
  }

  Future<void> test_callbackRecord() async {
    const src =
        '$_p abstract class Host implements PlatformHostInterface { int route((int Function(), int Function()) callbacks) => callbacks.\$1(); }';
    await check(src, [at(src, 'route')]);
  }

  Future<void> test_callbackList() async {
    const src =
        '$_p abstract class Host implements PlatformHostInterface { int route(List<int Function()> callbacks) => callbacks.first(); }';
    await check(src, [at(src, 'route')]);
  }

  Future<void> test_callbackObjectFields() async {
    const src =
        '$_p class Choices { final int Function() first, second; Choices(this.first, this.second); } abstract class Host implements PlatformHostInterface { int route(Choices choices) => choices.first(); }';
    await check(src, [at(src, 'route')]);
  }

  Future<void> test_constructorStorage() async {
    const src =
        '$_p abstract class Host implements PlatformHostInterface { final int Function() first, second; Host(this.first, this.second); }';
    await check(src, [at(src, 'Host')]);
  }

  Future<void> test_serviceLocator() async {
    const src =
        '$_p abstract class Host implements PlatformHostInterface { T get<T>() => throw 0; }';
    await check(src, [at(src, 'get')]);
  }

  Future<void> test_singleFactoryAllowed() async {
    await clean(
      '$_p abstract class Host implements PlatformHostInterface { final int Function() factory; Host(this.factory); }',
    );
  }

  Future<void> test_nonPlatformCallbacksAllowed() async {
    await clean(
      'class Runner { bool pollUntil(bool Function() ready, bool Function() expired) => ready() || expired(); }',
    );
  }
}

@reflectiveTest
class AmbientPlatformStateRuleTest extends ArchitectureRuleTest {
  @override
  void setUp() {
    rule = AmbientPlatformStateRule();
    super.setUp();
  }

  Future<void> test_platformFlag() async {
    const src =
        "import 'dart:io' as runtime; bool build() => runtime.Platform.isWindows;";
    await check(src, [at(src, 'isWindows')]);
  }

  Future<void> test_standardStream() async {
    const src = "import 'dart:io' as native; Object build() => native.stdout;";
    await check(src, [at(src, 'stdout')]);
  }

  Future<void> test_currentDirectory() async {
    const src =
        "import 'dart:io' as native; String path() => native.Directory.current.toString();";
    await check(src, [at(src, 'current')]);
  }

  Future<void> test_abiCurrent() async {
    const src =
        "import 'dart:ffi' as native; Object build() => native.Abi.current();";
    await check(src, [at(src, 'current')]);
  }

  Future<void> test_streamDefaultFallback() async {
    const src =
        "import 'dart:io' as native; class Service { final native.IOSink output; Service({native.IOSink? output}) : output = output ?? native.stdout; }";
    await check(src, [at(src, 'stdout')]);
  }

  Future<void> test_abiCurrentAllowedOnConcreteHost() async {
    await clean(
      "import 'dart:ffi'; Object build() => Abi.current();",
      path: 'lib/src/host/windows/loader.dart',
    );
  }

  Future<void> test_compositionAllowed() async {
    await clean(
      "import 'dart:io'; bool build() => Platform.isWindows;",
      path: 'lib/composition/native_host.dart',
    );
  }

  Future<void> test_injectedStreamShadow() async {
    await clean(
      "import 'dart:io'; void write(IOSink stdout) { stdout.write('message'); }",
    );
  }

  Future<void> test_processStreamsAllowed() async {
    await clean(
      "import 'dart:io'; void drain(Process process) { process.toString(); }",
    );
  }
}

@reflectiveTest
class HiddenPlatformDetectionRuleTest extends ArchitectureRuleTest {
  @override
  void setUp() {
    rule = HiddenPlatformDetectionRule();
    super.setUp();
  }

  Future<void> test_detectorCallOutsideComposition() async {
    support(
      'lib/composition/native_host.dart',
      "String detectPlatformHostSnapshot() => 'host';",
    );
    const src =
        "import 'package:test/composition/native_host.dart'; class Service { Object build() => detectPlatformHostSnapshot(); }";
    await check(src, [at(src, 'detectPlatformHostSnapshot')]);
  }

  Future<void> test_detectorTearoff() async {
    support(
      'lib/composition/native_host.dart',
      "String detectPlatformHostSnapshot() => 'host';",
    );
    const src =
        "import 'package:test/composition/native_host.dart'; final hidden = detectPlatformHostSnapshot;";
    await check(src, [at(src, 'detectPlatformHostSnapshot')]);
  }

  Future<void> test_compositionMayCall() async {
    support(
      'lib/composition/native_host.dart',
      "String detectPlatformHostSnapshot() => 'host';",
    );
    await clean(
      "import 'package:test/composition/native_host.dart'; Object create() => detectPlatformHostSnapshot();",
      path: 'lib/src/composition/native_runtime.dart',
    );
  }

  Future<void> test_sharedDetectHelperAllowed() async {
    await clean(
      "String detectEncoding(String text) => 'utf8'; Object build() => detectEncoding('x');",
    );
  }
}

@reflectiveTest
class NativeAcquisitionRuleTest extends ArchitectureRuleTest {
  @override
  void setUp() {
    rule = NativeAcquisitionRule();
    super.setUp();
  }

  Future<void> test_fileConstructor() async {
    const src =
        "import 'dart:io' as renamed; Object acquire(String path) => renamed.File(path);";
    await check(src, [at(src, 'renamed.File(path)')]);
  }

  Future<void> test_typedefConstructor() async {
    const src =
        "import 'dart:io' as renamed; typedef Selected = renamed.File; Object acquire(String path) => Selected(path);";
    await check(src, [at(src, 'Selected(path)')]);
  }

  Future<void> test_constructorTearoff() async {
    const src =
        "import 'dart:io' as renamed; final acquire = renamed.Directory.new;";
    await check(src, [at(src, 'renamed.Directory.new')]);
  }

  Future<void> test_processStatics() async {
    const src =
        "import 'dart:io' as renamed; Object a() => renamed.Process.run('tool', []); final b = renamed.Process.start;";
    await check(src, [at(src, 'run'), at(src, 'start')]);
  }

  Future<void> test_socketAndFilesystemQueries() async {
    const src =
        "import 'dart:io' as renamed; Object a() => renamed.Socket.connect('localhost', 80); Object b(String p) => renamed.FileSystemEntity.typeSync(p);";
    await check(src, [at(src, 'connect'), at(src, 'typeSync')]);
  }

  Future<void> test_targetLayerChecked() async {
    const src = "import 'dart:io'; Object acquire(String path) => File(path);";
    await check(src, [
      at(src, 'File(path)'),
    ], path: 'lib/src/target/iphone/native_fixture.dart');
  }

  Future<void> test_hostLayerAllowed() async {
    await clean(
      "import 'dart:io'; Object acquire(String path) => File(path);",
      path: 'lib/src/host/shared/native_file_system.dart',
    );
  }

  Future<void> test_suppliedEntitiesAllowed() async {
    await clean(
      "import 'dart:io' as renamed; void operate(renamed.File file, renamed.Directory directory) { file.existsSync(); directory.existsSync(); }",
    );
  }

  Future<void> test_unrelatedSpellings() async {
    await clean(
      'class File { File(String path); } class Socket { static String connect(String h, int p) => h; } void work(String path) { File(path); Socket.connect(path, 0); }',
    );
  }
}
