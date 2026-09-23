import 'dart:io';

import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/flutter/build/ios_plugins.dart';

void main() {
  test('binary iOS 17 plugin registrant compiles at iOS 15', () {
    if (!Platform.isWindows) {
      markTestSkipped('Windows Swift cross-compiler integration test');
      return;
    }
    final bundle = DarwinSdk.nativeInstallDir();
    if (!DarwinSdk.isValidBundle(bundle)) {
      markTestSkipped('xcross Darwin SDK is not installed');
      return;
    }
    final swiftc = Process.runSync('where.exe', ['swiftc.exe']);
    if (swiftc.exitCode != 0) {
      markTestSkipped('Swift compiler is not installed');
      return;
    }
    final compiler = (swiftc.stdout as String).split(RegExp(r'\r?\n')).first;
    final sdk = DarwinSdk(bundle).iPhoneOSSdk();
    final temp = Directory.systemTemp.createTempSync('xcross-availability-');
    addTearDown(() => temp.deleteSync(recursive: true));

    final pluginRoot = Directory(p.join(temp.path, 'new_plugin'))..createSync();
    final sourceDirectory = Directory(p.join(temp.path, 'native-source'))
      ..createSync(recursive: true);
    File(p.join(pluginRoot.path, 'pubspec.yaml')).writeAsStringSync('''
name: new_plugin
flutter:
  plugin:
    platforms:
      ios:
        pluginClass: NewPlugin
''');
    File(p.join(sourceDirectory.path, 'NewPlugin.swift')).writeAsStringSync('''
import Foundation
import Flutter
@available(iOS 17.0, *)
public class NewPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {}
}
''');
    final binaryInterface = File(
      p.join(
        pluginRoot.path,
        'ios',
        'new_plugin',
        'NewPlugin.xcframework',
        'ios-arm64',
        'NewPlugin.framework',
        'Modules',
        'NewPlugin.swiftmodule',
        'arm64-apple-ios.swiftinterface',
      ),
    )..createSync(recursive: true);
    binaryInterface.writeAsStringSync('''
@available(iOS 17.0, *)
public class NewPlugin: NSObject, FlutterPlugin {}
''');
    File(
      p.join(
        pluginRoot.path,
        'ios',
        'new_plugin',
        'NewPlugin.xcframework',
        'Info.plist',
      ),
    ).writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>AvailableLibraries</key><array><dict>
<key>LibraryIdentifier</key><string>ios-arm64</string>
<key>SupportedPlatform</key><string>ios</string>
<key>SupportedArchitectures</key><array><string>arm64</string></array>
</dict></array></dict></plist>
''');
    File(p.join(temp.path, 'Flutter.swift')).writeAsStringSync('''
import Foundation
@objc public protocol FlutterPluginRegistrar {}
@objc public protocol FlutterPluginRegistry {
    func registrar(forPlugin key: String) -> FlutterPluginRegistrar?
}
@objc public protocol FlutterPlugin {
    static func register(with registrar: FlutterPluginRegistrar)
}
''');
    final plugin = IosPlugin(name: 'new_plugin', packageRoot: pluginRoot.path);
    expect(plugin.pluginClassIosAvailability, '17.0');
    final registrant = File(p.join(temp.path, 'Registrant.swift'))
      ..writeAsStringSync(GeneratedPluginsPackage.registrantSource([plugin]));

    ProcessResult compile(List<String> arguments) => Process.runSync(compiler, [
      '-target',
      'arm64-apple-ios15.0',
      '-sdk',
      sdk,
      '-I',
      temp.path,
      ...arguments,
    ]);

    final flutter = compile([
      '-emit-module',
      '-module-name',
      'Flutter',
      '-emit-module-path',
      p.join(temp.path, 'Flutter.swiftmodule'),
      p.join(temp.path, 'Flutter.swift'),
    ]);
    expect(flutter.exitCode, 0, reason: '${flutter.stdout}${flutter.stderr}');
    final nativePlugin = compile([
      '-emit-module',
      '-module-name',
      'new_plugin',
      '-emit-module-path',
      p.join(temp.path, 'new_plugin.swiftmodule'),
      p.join(sourceDirectory.path, 'NewPlugin.swift'),
    ]);
    expect(
      nativePlugin.exitCode,
      0,
      reason: '${nativePlugin.stdout}${nativePlugin.stderr}',
    );
    final unguarded = File(p.join(temp.path, 'Unguarded.swift'))
      ..writeAsStringSync(
        registrant.readAsStringSync().replaceFirst(
          'if #available(iOS 17.0, *) {',
          'if true {',
        ),
      );
    final rejected = compile(['-typecheck', unguarded.path]);
    expect(rejected.exitCode, isNot(0));
    expect(rejected.stderr, contains('only available in iOS 17.0 or newer'));
    final generated = compile(['-typecheck', registrant.path]);
    expect(
      generated.exitCode,
      0,
      reason: '${generated.stdout}${generated.stderr}',
    );
    final sil = compile(['-emit-sil', '-Onone', registrant.path]);
    expect(sil.exitCode, 0, reason: '${sil.stdout}${sil.stderr}');
    final silSource = sil.stdout as String;
    final functionStart = silSource.indexOf(
      '// xcrossRegisterGeneratedPlugins(_:)',
    );
    expect(functionStart, isNonNegative);
    final functionEnd = silSource.indexOf(
      '} // end sil function',
      functionStart,
    );
    expect(functionEnd, isNonNegative);
    final registrationFunction = silSource.substring(
      functionStart,
      functionEnd,
    );
    expect(registrationFunction, contains('_stdlib_isOSVersionAtLeast'));
    expect(registrationFunction, contains('cond_br'));
  });
}
