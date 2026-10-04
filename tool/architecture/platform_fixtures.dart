Map<String, (String, Set<String>)> platformFixtures() => {
  'inferred_getter': (
    '''abstract class PlatformHostInterface { String get operatingSystem; } class Service { final PlatformHostInterface host; Service(this.host); get compatible => host.operatingSystem == 'windows'; }''',
    {'identity-bool'},
  ),
  'identity_parameter': (
    '''void build({required bool isSimulator}) {}''',
    {'identity-bool'},
  ),
  'registry': (
    '''final strategies = {'windows': () => 1, 'linux': () => 2};''',
    {'platform-registry'},
  ),
  'ordinary_metadata': (
    '''const labels = {'windows': 'Windows', 'linux': 'Linux'};''',
    {},
  ),
  'getter_branch': (
    '''abstract class PlatformHostInterface { String get operatingSystem; } class Service { final PlatformHostInterface host; Service(this.host); bool get renamed => host.operatingSystem == 'windows'; void build() { if (renamed) print('bad'); } }''',
    {'identity-bool', 'platform-branch'},
  ),
  'inherited_callbacks': (
    '''abstract class PlatformHostInterface {} class Host implements PlatformHostInterface { int route(int Function() first, int Function() second) => first(); }''',
    {'callback-dispatch'},
  ),
  'ordinary_accept': (
    '''void which({bool Function(String)? accept}) { if (accept != null) accept('file'); } void visit(int pid) {}''',
    {},
  ),
  'aliased_host': (
    '''abstract class WindowsHostInterface {} typedef Renamed = WindowsHostInterface; void build(Object host) { if (host is Renamed) print('bad'); }''',
    {'platform-branch'},
  ),
  'literal_switch': (
    '''void build(String renamed) { switch(renamed) { case 'windows': print('bad'); } }''',
    {'platform-branch'},
  ),
  'callback_alias': (
    '''typedef Callback = int Function(); abstract class PlatformHostInterface {} class Host implements PlatformHostInterface { final PlatformHostInterface host; Host(this.host); int route(Callback first, Callback second) => first(); }''',
    {'callback-dispatch'},
  ),
  'abi_constants': (
    '''import 'dart:ffi' as native; bool supported(native.Abi input) => input == native.Abi.linuxX64 || input == native.Abi.macosArm64;''',
    {},
  ),
  'descriptor_path': (
    '''import 'dart:io'; abstract class IosBuildPlatformInterface {} class Repository { String iosSdk(String sdk, {required IosBuildPlatformInterface target}) => '/sdk'; } abstract interface class Files { Directory directory(String path); } void verify(Repository repository, IosBuildPlatformInterface target, Files files) { final root = repository.iosSdk('sdk', target: target); if (!files.directory(root).existsSync()) throw StateError(root); }''',
    {},
  ),
  'elf_architecture': (
    '''bool verify(String architecture) { if (architecture == 'arm64') return true; return false; }''',
    {},
  ),
  'ordinary_service_callbacks': (
    '''abstract class PlatformHostInterface {} class Runner<T extends PlatformHostInterface> { bool pollUntil(bool Function() ready, bool Function() expired) => ready() || expired(); }''',
    {},
  ),
  'unrelated_visitor': ('''class TreeVisitor { void visit(int pid) {} }''', {}),
  'architecture_dispatch': (
    '''abstract class PlatformHostInterface { String get architecture; } void build(PlatformHostInterface host) { if (host.architecture == 'arm64') print('compiler'); }''',
    {'platform-branch'},
  ),
  'assigned_discriminator': (
    '''abstract class PlatformHostInterface { String get operatingSystem; } void build(PlatformHostInterface host) { bool renamed = false; renamed = host.operatingSystem == 'windows'; if (renamed) print('bad'); }''',
    {'platform-branch'},
  ),
  'sdk_validation': (
    '''abstract class IosBuildPlatformInterface { String get sdkName; } void verify(String requested, IosBuildPlatformInterface target) { if(requested != target.sdkName) throw FormatException('not installed'); }''',
    {},
  ),
  'sdk_dispatch': (
    '''abstract class IosBuildPlatformInterface { String get sdkName; } void build(IosBuildPlatformInterface target) { if(target.sdkName == 'iphoneos') print('sign'); }''',
    {'platform-branch'},
  ),
  'hidden_detector_method': (
    '''import 'package:cli_kit/src/composition/native_host.dart'; class Service { Object build() => detectPlatformHostSnapshot(); }''',
    {'hidden-detection', 'composition-edge'},
  ),
  'detector_tearoff': (
    '''import 'package:cli_kit/src/composition/native_host.dart'; final hidden = detectPlatformHostSnapshot;''',
    {'hidden-detection', 'composition-edge'},
  ),
  'collection_control': (
    '''abstract class PlatformHostInterface { String get operatingSystem; } List<String> args(PlatformHostInterface host) => [if(host.operatingSystem == 'windows') '/c' else '-c'];''',
    {'platform-branch'},
  ),
  'renamed_transform': (
    '''abstract class PlatformHostInterface { String get operatingSystem; } void build(PlatformHostInterface host) { final renamed=host.operatingSystem.toLowerCase(); if(renamed.startsWith('win')) print('compiler'); }''',
    {'platform-branch'},
  ),
  'ordinary_path_transform': (
    '''void check(String path) { final normalized=path.toLowerCase(); if(normalized.startsWith('/sdk')) print('path'); }''',
    {},
  ),
  'while_control': (
    '''abstract class PlatformHostInterface { String get operatingSystem; } void build(PlatformHostInterface host) { while(host.operatingSystem.startsWith('win')) { print('compiler'); break; } }''',
    {'platform-branch'},
  ),
  'for_control': (
    '''abstract class PlatformHostInterface { String get operatingSystem; } void build(PlatformHostInterface host) { for(;host.operatingSystem.startsWith('win');) { print('compiler'); break; } }''',
    {'platform-branch'},
  ),
  'do_control': (
    '''abstract class PlatformHostInterface { String get operatingSystem; } void build(PlatformHostInterface host) { do { print('compiler'); } while(host.operatingSystem.startsWith('win')); }''',
    {'platform-branch'},
  ),
  'if_case_control': (
    '''abstract class WindowsHostInterface {} void build(Object host) { if(host case WindowsHostInterface()) print('compiler'); }''',
    {'platform-branch'},
  ),
  'snapshot_abi_dispatch': (
    '''import 'dart:ffi'; class NativeHostSnapshot { final Abi abi; NativeHostSnapshot(this.abi); } void build(NativeHostSnapshot snapshot) { if(snapshot.abi == Abi.windowsX64) print('windows tool'); }''',
    {'platform-branch'},
  ),
  'renamed_object_dispatch': (
    '''abstract class PlatformHostInterface {} abstract class WindowsHostInterface implements PlatformHostInterface {} abstract class LinuxHostInterface implements PlatformHostInterface {} abstract class Choices { int first(WindowsHostInterface host); int second(LinuxHostInterface host); } class WindowsHost implements WindowsHostInterface { int route(Choices choices)=>choices.first(this); } class LinuxHost implements LinuxHostInterface { int route(Choices choices)=>choices.second(this); }''',
    {'callback-dispatch', 'visitor'},
  ),
  'callback_record': (
    r'''abstract class PlatformHostInterface {} class Host implements PlatformHostInterface { int route((int Function(),int Function()) callbacks)=>callbacks.$1(); }''',
    {'callback-dispatch'},
  ),
  'callback_list': (
    '''abstract class PlatformHostInterface {} class Host implements PlatformHostInterface { int route(List<int Function()> callbacks)=>callbacks.first(); }''',
    {'callback-dispatch'},
  ),
  'amb_stream_default': (
    '''import 'dart:io' as native; class Service { final IOSink output; Service({IOSink? output}):output=output??native.stdout; }''',
    {'ambient-detection'},
  ),
  'callback_object_fields': (
    '''abstract class PlatformHostInterface {} class Choices { final int Function() first, second; Choices(this.first,this.second); } class Host implements PlatformHostInterface { int route(Choices choices) => choices.first(); }''',
    {'callback-dispatch'},
  ),
  'callback_constructor_storage': (
    '''abstract class PlatformHostInterface {} class Host implements PlatformHostInterface { final int Function() first, second; Host(this.first,this.second); int route() => first(); }''',
    {'callback-dispatch'},
  ),
  'ordinary_callback_holder': (
    '''class Choices { final int Function() first, second; Choices(this.first,this.second); int route() => first(); }''',
    {},
  ),
  'single_injected_platform_factory': (
    '''abstract class PlatformHostInterface {} class Host implements PlatformHostInterface { final int Function() factory; Host(this.factory); int route() => factory(); }''',
    {},
  ),
  'process_owned_streams': (
    '''import 'dart:io'; void drain(Process process, ProcessResult result) { process.stdout.listen((_) {}); process.stderr.listen((_) {}); process.stdin.close(); result.stdout.toString(); result.stderr.toString(); }''',
    <String>{},
  ),
  'injected_stream_shadow': (
    '''import 'dart:io'; void write(IOSink stdout) { stdout.write('message'); }''',
    {},
  ),
  'amb_directory': (
    '''import 'dart:io' as native; String path()=>native.Directory.current.path;''',
    {'ambient-detection'},
  ),
  'ordinary_flags': (
    '''void build(bool debug, bool ipa, bool pub) { if (debug) print(ipa); if (pub) print('pub'); }''',
    {},
  ),
  'aliased_platform': (
    '''import 'dart:io' as runtime; void build() { final renamed = runtime.Platform.isWindows; final chosen = renamed; if (chosen) print('bad'); }''',
    {'ambient-detection', 'platform-branch', 'identity-bool'},
  ),
  'aliased_abi': (
    '''import 'dart:ffi' as native; Object build() => native.Abi.current();''',
    {'ambient-detection'},
  ),
  'renamed_getter': (
    '''abstract class PlatformHostInterface { String get operatingSystem; } class Service { final PlatformHostInterface host; Service(this.host); bool get compatible => host.operatingSystem == 'windows'; }''',
    {'identity-bool'},
  ),
  'renamed_branch': (
    '''abstract class PlatformHostInterface { String get operatingSystem; } void build(PlatformHostInterface host) { final label = host.operatingSystem; final second = label; if (second == 'linux') print('bad'); }''',
    {'platform-branch'},
  ),
  'visitor': ('''class HostVisitor { void visitWindows() {} }''', {'visitor'}),
  'accept': (
    '''abstract class PlatformHostInterface {} class Host implements PlatformHostInterface { void accept(Object callback) {} }''',
    {'visitor'},
  ),
  'callbacks': (
    '''abstract class PlatformHostInterface {} class Host implements PlatformHostInterface { PlatformHostInterface host; Host(this.host); R choose<R>(R Function() first, R Function() second) => first(); }''',
    {'callback-dispatch'},
  ),
};
