import 'dart:convert';

import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/native_assets_manifest.dart';

void main() {
  test(
    'normalizes target paths without changing identifiers or lookup modes',
    () {
      final source = jsonEncode({
        'format-version': [1, 0, 0],
        'native-assets': {
          for (final target in ['ios_arm64', 'ios_x64'])
            target: {
              r'package:sample/identifier\unchanged': [
                'absolute',
                r'Sample.framework\Sample',
              ],
              'relative': ['relative', r'Other.framework\Other'],
              'process': ['process'],
              'executable': ['executable'],
              'system': ['system', r'unchanged\system'],
            },
          'windows_x64': {
            'sample': ['absolute', r'C:\assets\sample.dll'],
          },
        },
      });
      final result = normalizeIosNativeAssetsManifest(source);
      final targets = (jsonDecode(result) as Map)['native-assets'] as Map;
      for (final target in ['ios_arm64', 'ios_x64']) {
        expect(targets[target], {
          r'package:sample/identifier\unchanged': [
            'absolute',
            'Sample.framework/Sample',
          ],
          'relative': ['relative', 'Other.framework/Other'],
          'process': ['process'],
          'executable': ['executable'],
          'system': ['system', r'unchanged\system'],
        });
      }
      expect(targets['windows_x64'], {
        'sample': ['absolute', r'C:\assets\sample.dll'],
      });
      expect(normalizeIosNativeAssetsManifest(result), result);
    },
  );

  test('preserves already portable manifests including whitespace', () {
    const source = '''
{
  "format-version": [1, 0, 0],
  "native-assets": {"ios_arm64": {"sample": ["absolute", "Sample.framework/Sample"]}}
}''';
    expect(normalizeIosNativeAssetsManifest(source), source);
    const empty = '{"format-version":[1,0,0],"native-assets":{}}';
    expect(normalizeIosNativeAssetsManifest(empty), empty);
  });

  test('leaves unknown or malformed shapes to the manifest validator', () {
    for (final source in [
      '{}',
      '[]',
      '{"native-assets":null}',
      '{"native-assets":{"ios_arm64":null}}',
      '{"native-assets":{"ios_arm64":[]}}',
      '{',
    ]) {
      expect(normalizeIosNativeAssetsManifest(source), source);
    }
  });
}
