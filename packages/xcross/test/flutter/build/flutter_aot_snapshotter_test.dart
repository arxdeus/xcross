import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/flutter_aot_snapshotter.dart';
import 'package:xcross/src/shared/flutter/flutter_version_defines.dart';

void main() {
  test('gen_snapshot arguments match flutter build ios', () {
    expect(
      FlutterAotSnapshotter.arguments(
        appDill: 'app.dill',
        binary: 'App.framework/App',
        objectFile: 'app.o',
      ),
      [
        '--deterministic',
        '--snapshot_kind=app-aot-macho-dylib',
        '--macho=App.framework/App',
        '--macho-object=app.o',
        '--macho-min-os-version=15.0',
        '--macho-rpath=@executable_path/Frameworks,@loader_path/Frameworks',
        '--macho-install-name=@rpath/App.framework/App',
        'app.dill',
      ],
    );
  });

  test('split debug info and obfuscation follow flutter_tools', () {
    final arguments = FlutterAotSnapshotter.arguments(
      appDill: 'app.dill',
      binary: 'App.framework/App',
      objectFile: 'app.o',
      splitDebugInfo: 'symbols',
      obfuscate: true,
    );
    expect(
      arguments,
      containsAllInOrder([
        '--macho-install-name=@rpath/App.framework/App',
        '--dwarf-stack-traces',
        '--resolve-dwarf-paths',
        startsWith('--save-debugging-info=symbols'),
        '--obfuscate',
        'app.dill',
      ]),
    );
    expect(arguments.last, 'app.dill');
    expect(
      arguments.singleWhere((a) => a.startsWith('--save-debugging-info=')),
      endsWith('app.ios-arm64.symbols'),
    );
  });

  test('version defines use the short revisions flutter_tools uses', () {
    expect(
      FlutterVersionDefines.fromJson({
        'frameworkVersion': '3.47.0',
        'channel': 'stable',
        'repositoryUrl': 'https://github.com/flutter/flutter.git',
        'frameworkRevision': '4cf24164269a5ebf0c16a028a00727d0e77bbb05',
        'engineRevision': '5f77625673248ee5846fbcaf5d3e1a3878386fd7',
        'dartSdkVersion': '3.13.0',
      }),
      [
        'FLUTTER_VERSION=3.47.0',
        'FLUTTER_CHANNEL=stable',
        'FLUTTER_GIT_URL=https://github.com/flutter/flutter.git',
        'FLUTTER_FRAMEWORK_REVISION=4cf2416426',
        'FLUTTER_ENGINE_REVISION=5f77625673',
        'FLUTTER_DART_VERSION=3.13.0',
      ],
    );
    expect(FlutterVersionDefines.fromJson({'channel': 'stable'}), isEmpty);
  });
}
