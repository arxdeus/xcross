import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/flutter_aot_snapshotter.dart';

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
}
