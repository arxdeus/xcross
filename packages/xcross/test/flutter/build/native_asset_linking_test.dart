import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/native_asset_frameworks.dart';
import 'package:xcross/src/flutter/build/internal/native_asset_linkage.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/runner_shim.dart';
import 'package:xcross/src/flutter/errors.dart';

void main() {
  test(
    'links only native frameworks needed by SwiftPM plugin symbols',
    () async {
      final root = Directory.systemTemp.createTempSync('xcross-native-links-');
      addTearDown(() => root.deleteSync(recursive: true));
      final provider = p.join(root.path, 'flutter_soloud_plugin.framework');
      final unused = p.join(root.path, 'objective_c.framework');
      Directory(provider).createSync();
      Directory(unused).createSync();
      _writeMachO(
        p.join(provider, 'flutter_soloud_plugin'),
        '_clearDartCallbackRegistrationsForEngine',
        undefined: false,
      );
      _writeMachO(
        p.join(unused, 'objective_c'),
        '_unrelated',
        undefined: false,
      );
      final plugin = p.join(root.path, 'libflutter-soloud.dylib');
      _writeMachO(
        plugin,
        '_clearDartCallbackRegistrationsForEngine',
        undefined: true,
      );

      final required = await nativeFrameworksRequiredByPlugins(
        [provider, unused],
        [plugin],
      );
      expect(required, [provider]);
      final arguments = RunnerShim.linkArguments(
        objectPath: 'Runner.o',
        outputPath: 'Runner',
        iosSdk: '/sdk',
        flutterSlice: '/engine',
        subframeworks: '/subframeworks',
        sdkVersion: '26.0',
        deploymentTarget: const IosDeploymentTarget('17.0'),
        nativeAssetFrameworks: required,
      );
      expect(
        arguments,
        containsAllInOrder(['-needed_framework', 'flutter_soloud_plugin']),
      );
      expect(arguments, isNot(contains('objective_c')));
      expect(
        await nativeFrameworksRequiredByPlugins([provider, unused], const []),
        isEmpty,
      );
    },
  );

  test('ignores imports already bound to another dylib', () async {
    final root = Directory.systemTemp.createTempSync('xcross-bound-import-');
    addTearDown(() => root.deleteSync(recursive: true));
    final framework = p.join(root.path, 'unrelated.framework');
    Directory(framework).createSync();
    _writeMachO(p.join(framework, 'unrelated'), '_shared', undefined: false);
    final boundPlugin = p.join(root.path, 'bound.dylib');
    _writeMachO(boundPlugin, '_shared', undefined: true, ordinal: 1);
    final boundBytes = ByteData.sublistView(
      File(boundPlugin).readAsBytesSync(),
    );
    expect(boundBytes.getUint32(24, Endian.little), 0x80);
    expect(boundBytes.getUint16(32 + 24 + 6, Endian.little), 0x100);
    expect(
      await nativeFrameworksRequiredByPlugins([framework], [boundPlugin]),
      isEmpty,
    );

    final flatPlugin = p.join(root.path, 'flat.dylib');
    _writeMachO(flatPlugin, '_shared', undefined: true, ordinal: 0xfe);
    expect(await nativeFrameworksRequiredByPlugins([framework], [flatPlugin]), [
      framework,
    ]);
  });

  test('does not eagerly link frameworks for weak plugin imports', () async {
    final root = Directory.systemTemp.createTempSync('xcross-weak-import-');
    addTearDown(() => root.deleteSync(recursive: true));
    final framework = p.join(root.path, 'optional.framework');
    Directory(framework).createSync();
    _writeMachO(p.join(framework, 'optional'), '_optional', undefined: false);
    final plugin = p.join(root.path, 'plugin.dylib');
    _writeMachO(
      plugin,
      '_optional',
      undefined: true,
      ordinal: 0xfe,
      weakReference: true,
    );
    expect(
      await nativeFrameworksRequiredByPlugins([framework], [plugin]),
      isEmpty,
    );
    _writeMachO(plugin, '_optional', undefined: true, ordinal: 0xfe);
    expect(
      await nativeFrameworksRequiredByPlugins([framework], [plugin]),
      [framework],
    );
  });

  test(
    'uses public export trie aliases but not private nlist symbols',
    () async {
      final root = Directory.systemTemp.createTempSync('xcross-export-trie-');
      addTearDown(() => root.deleteSync(recursive: true));
      final alias = p.join(root.path, 'alias.framework');
      final hidden = p.join(root.path, 'hidden.framework');
      Directory(alias).createSync();
      Directory(hidden).createSync();
      _writeMachO(
        p.join(alias, 'alias'),
        '_needed',
        undefined: false,
        symbolType: 0x0b, // N_INDR | N_EXT
        trieExport: '_needed',
        separateTrieCommand: true,
      );
      _writeMachO(
        p.join(hidden, 'hidden'),
        '_needed',
        undefined: false,
        symbolType: 0x1f, // N_SECT | N_EXT | N_PEXT
        trieExport: '',
      );
      final plugin = p.join(root.path, 'plugin.dylib');
      _writeMachO(plugin, '_needed', undefined: true, ordinal: 0xfe);
      expect(
        await nativeFrameworksRequiredByPlugins([hidden, alias], [plugin]),
        [alias],
      );

      // Older dylibs may lack an export trie; their public N_INDR aliases
      // remain valid while private nlist entries are not usable exports.
      _writeMachO(
        p.join(alias, 'alias'),
        '_needed',
        undefined: false,
        symbolType: 0x0b,
      );
      _writeMachO(
        p.join(hidden, 'hidden'),
        '_needed',
        undefined: false,
        symbolType: 0x1f,
      );
      expect(
        await nativeFrameworksRequiredByPlugins([hidden, alias], [plugin]),
        [alias],
      );
    },
  );

  test('collects only frameworks referenced by the active manifest', () {
    final root = Directory.systemTemp.createTempSync('xcross-hook-products-');
    addTearDown(() => root.deleteSync(recursive: true));
    final output = p.join(root.path, 'assemble');
    final assembled = p.join(output, 'native_assets', 'First.framework');
    final hooked = p.join(
      root.path,
      'build',
      'native_assets',
      'ios',
      'Second.framework',
    );
    Directory(assembled).createSync(recursive: true);
    Directory(hooked).createSync(recursive: true);
    final stale = p.join(output, 'native_assets', 'Stale.framework');
    Directory(stale).createSync(recursive: true);
    final manifest = jsonEncode({
      'native-assets': {
        'ios_arm64': {
          'first': ['absolute', 'First.framework/First'],
          'second': ['relative', 'Second.framework/Second'],
        },
        'ios_x64': {
          'simulator': ['absolute', 'Stale.framework/Stale'],
        },
      },
    });
    final frameworks = collectNativeAssetFrameworks(
      manifest,
      output,
      projectRoot: root.path,
    );
    expect(frameworks, unorderedEquals([assembled, hooked]));
    expect(frameworks, isNot(contains(stale)));
    final arguments = RunnerShim.linkArguments(
      objectPath: 'Runner.o',
      outputPath: 'Runner',
      iosSdk: '/sdk',
      flutterSlice: '/engine',
      subframeworks: '/subframeworks',
      sdkVersion: '26.0',
      deploymentTarget: const IosDeploymentTarget('17.0'),
      nativeAssetFrameworks: frameworks,
    );
    for (final framework in frameworks) {
      expect(
        arguments,
        containsAllInOrder([
          '-F',
          p.dirname(framework),
          '-needed_framework',
          p.basenameWithoutExtension(framework),
        ]),
      );
    }
    expect(arguments, isNot(contains('Stale')));
  });

  test('rejects missing manifest frameworks and prefers current outputs', () {
    final root = Directory.systemTemp.createTempSync('xcross-asset-conflict-');
    addTearDown(() => root.deleteSync(recursive: true));
    final output = p.join(root.path, 'assemble');
    final manifest = jsonEncode({
      'native-assets': {
        'ios_arm64': {
          'asset': ['absolute', 'Shared.framework/Shared'],
        },
      },
    });
    expect(
      () => collectNativeAssetFrameworks(
        manifest,
        output,
        projectRoot: root.path,
      ),
      throwsA(isA<FlutterBuildError>()),
    );
    final current = p.join(output, 'native_assets', 'Shared.framework');
    final stale = p.join(
      root.path,
      'build',
      'native_assets',
      'ios',
      'Shared.framework',
    );
    Directory(current).createSync(recursive: true);
    Directory(stale).createSync(recursive: true);
    File(p.join(current, 'Shared')).writeAsStringSync('current');
    File(p.join(stale, 'Shared')).writeAsStringSync('stale');
    final selected = collectNativeAssetFrameworks(
      manifest,
      output,
      projectRoot: root.path,
    );
    expect(selected, [current]);
    expect(
      File(p.join(selected.single, 'Shared')).readAsStringSync(),
      'current',
    );
  });
}

void _writeMachO(
  String path,
  String symbol, {
  required bool undefined,
  int? ordinal,
  bool weakReference = false,
  int? symbolType,
  String? trieExport,
  bool separateTrieCommand = false,
}) {
  const headerSize = 32;
  const commandSize = 24;
  const dyldCommandSize = 48;
  const exportsCommandSize = 16;
  const symbolSize = 16;
  final strings = [0, ...symbol.codeUnits, 0];
  final trie = trieExport == null
      ? <int>[]
      : trieExport.isEmpty
      ? <int>[0, 0]
      : <int>[
          0,
          1,
          ...trieExport.codeUnits,
          0,
          trieExport.length + 4,
          2,
          0,
          0,
          0,
        ];
  final commandsSize =
      commandSize +
      (trieExport == null
          ? 0
          : separateTrieCommand
          ? exportsCommandSize
          : dyldCommandSize);
  final symbolOffset = headerSize + commandsSize;
  final stringsOffset = symbolOffset + symbolSize;
  final trieOffset = stringsOffset + strings.length;
  final bytes = Uint8List(trieOffset + trie.length);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 0xFEED_FACF, Endian.little);
  data.setUint32(4, 0x0100_000c, Endian.little);
  data.setUint32(12, 0x6, Endian.little);
  data.setUint32(16, trieExport == null ? 1 : 2, Endian.little);
  data.setUint32(20, commandsSize, Endian.little);
  if (ordinal != null) data.setUint32(24, 0x80, Endian.little);
  data.setUint32(headerSize, 0x2, Endian.little);
  data.setUint32(headerSize + 4, commandSize, Endian.little);
  data.setUint32(headerSize + 8, symbolOffset, Endian.little);
  data.setUint32(headerSize + 12, 1, Endian.little);
  data.setUint32(headerSize + 16, stringsOffset, Endian.little);
  data.setUint32(headerSize + 20, strings.length, Endian.little);
  data.setUint32(symbolOffset, 1, Endian.little);
  bytes[symbolOffset + 4] = symbolType ?? (undefined ? 0x01 : 0x0f);
  bytes[symbolOffset + 5] = undefined ? 0 : 1;
  if (ordinal != null) {
    data.setUint16(
      symbolOffset + 6,
      (ordinal << 8) | (weakReference ? 0x40 : 0),
      Endian.little,
    );
  }
  bytes.setRange(stringsOffset, stringsOffset + strings.length, strings);
  if (trieExport != null) {
    const dyld = headerSize + commandSize;
    data.setUint32(
      dyld,
      separateTrieCommand ? 0x80000033 : 0x80000022,
      Endian.little,
    );
    data.setUint32(
      dyld + 4,
      separateTrieCommand ? exportsCommandSize : dyldCommandSize,
      Endian.little,
    );
    data.setUint32(
      dyld + (separateTrieCommand ? 8 : 40),
      trieOffset,
      Endian.little,
    );
    data.setUint32(
      dyld + (separateTrieCommand ? 12 : 44),
      trie.length,
      Endian.little,
    );
    bytes.setRange(trieOffset, bytes.length, trie);
  }
  File(path).writeAsBytesSync(bytes);
}
