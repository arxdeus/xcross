import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/cli/ide/subcommands/idea_command.dart';
import 'package:xcross/src/cli/ide/subcommands/vscode_command.dart';
import 'package:xcross/src/cli/ide/subcommands/vscode_json_merge.dart';
import 'package:xcross/src/util/errors.dart';

void main() {
  group('stripJsonc / parseJsonc', () {
    test('strips line and block comments outside strings', () {
      const raw = '''
{
  // line comment
  "a": 1, /* block */
  "url": "http://example.com" // keep // in string above
}
''';
      expect(parseJsonc(raw), {'a': 1, 'url': 'http://example.com'});
    });

    test('strips trailing commas in objects and arrays', () {
      expect(parseJsonc('{\n  "a": 1,\n  "b": false,\n}\n'), {
        'a': 1,
        'b': false,
      });
      expect(parseJsonc('[1, 2, ]'), [1, 2]);
      expect(parseJsonc('{"a": 1, // trailing\n}'), {'a': 1});
      // Comma inside a string must survive.
      expect(parseJsonc('{"x": "a,b"}'), {'x': 'a,b'});
    });
  });

  group('mergeLaunchDoc', () {
    test('creates a fresh document', () {
      final doc = mergeLaunchDoc(null);
      expect(doc['version'], '0.2.0');
      final configs = doc['configurations']! as List;
      expect(configs, hasLength(1));
      expect(configs.single, {...xcrossLaunchFields(), 'args': <Object?>[]});
    });

    test('appends beside foreign configs and preserves their content', () {
      final doc = mergeLaunchDoc({
        'version': '0.2.0',
        'configurations': [
          {'name': 'Flutter', 'type': 'dart', 'request': 'launch'},
        ],
      });
      final configs = doc['configurations']! as List;
      expect(configs, hasLength(2));
      expect(configs.first, {
        'name': 'Flutter',
        'type': 'dart',
        'request': 'launch',
      });
      expect((configs.last as Map)['xcross'], true);
    });

    test('preserves args on an existing xcross entry', () {
      final doc = mergeLaunchDoc({
        'version': '0.2.0',
        'configurations': [
          {
            'name': 'xcross: iOS device',
            'type': 'dart',
            'xcross': true,
            'args': ['--udid', 'ABC'],
            'extra': true,
          },
        ],
      });
      final entry = (doc['configurations']! as List).single as Map;
      expect(entry['args'], ['--udid', 'ABC']);
      expect(entry['extra'], true);
      expect(entry['program'], 'lib/main.dart');
      expect(entry['debuggerType'], 'flutter');
    });

    test('matches by name when xcross flag is missing', () {
      final doc = mergeLaunchDoc({
        'configurations': [
          {'name': 'xcross: iOS device', 'type': 'dart'},
        ],
      });
      final entry = (doc['configurations']! as List).single as Map;
      expect(entry['xcross'], true);
      expect(entry['args'], <Object?>[]);
    });
  });

  group('mergeSettingsDoc', () {
    test('upserts DAP keys without wiping siblings', () {
      expect(
        mergeSettingsDoc({'editor.fontSize': 14, dapPathSetting: 'stale'}),
        {
          'editor.fontSize': 14,
          dapPathSetting: dapPathValue,
          promptErrorsSetting: false,
        },
      );
    });
  });

  group('VscodeCommand upsert', () {
    late Directory temp;
    late Directory previous;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('xcross-ide-vscode-');
      previous = Directory.current;
      Directory.current = temp;
    });

    tearDown(() {
      Directory.current = previous;
      temp.deleteSync(recursive: true);
    });

    test(
      'creates launch.json and settings.json, then skips when current',
      () async {
        await VscodeCommand().run();
        final launch = File(p.join(temp.path, '.vscode', 'launch.json'));
        final settings = File(p.join(temp.path, '.vscode', 'settings.json'));
        final shim = File(p.join(temp.path, '.vscode', 'xcross_dap.dart'));
        expect(shim.existsSync(), isTrue);
        expect(launch.existsSync(), isTrue);
        expect(settings.existsSync(), isTrue);

        final launchBefore = launch.readAsStringSync();
        final settingsBefore = settings.readAsStringSync();
        await VscodeCommand().run();
        expect(launch.readAsStringSync(), launchBefore);
        expect(settings.readAsStringSync(), settingsBefore);
      },
    );

    test('merges into existing files and fixes stale DAP path', () async {
      final vscode = Directory(p.join(temp.path, '.vscode'))..createSync();
      File(p.join(vscode.path, 'launch.json')).writeAsStringSync(
        jsonEncode({
          'version': '0.2.0',
          'configurations': [
            {'name': 'Flutter', 'type': 'dart', 'request': 'launch'},
          ],
        }),
      );
      File(p.join(vscode.path, 'settings.json')).writeAsStringSync(
        jsonEncode({'editor.fontSize': 14, dapPathSetting: 'stale'}),
      );

      await VscodeCommand().run();

      final launch =
          jsonDecode(
                File(p.join(vscode.path, 'launch.json')).readAsStringSync(),
              )
              as Map;
      final configs = launch['configurations'] as List;
      final first = configs.first as Map;
      final last = configs.last as Map;
      expect(configs, hasLength(2));
      expect(first['name'], 'Flutter');
      expect(last['xcross'], true);

      final settings =
          jsonDecode(
                File(p.join(vscode.path, 'settings.json')).readAsStringSync(),
              )
              as Map;
      expect(settings['editor.fontSize'], 14);
      expect(settings[dapPathSetting], dapPathValue);
      expect(settings[promptErrorsSetting], false);
    });

    test('refuses to clobber invalid JSONC', () async {
      final vscode = Directory(p.join(temp.path, '.vscode'))..createSync();
      File(p.join(vscode.path, 'launch.json')).writeAsStringSync('{not json');

      await expectLater(VscodeCommand().run(), throwsA(isA<XcrossError>()));
    });
  });

  group('buildIdeaRunXml', () {
    test('embeds exe, DAPConfiguration, xcross launch, and dart mapping', () {
      final xml = buildIdeaRunXml(r'C:\tools\xcross.exe');
      expect(xml, contains('type="DAPConfiguration"'));
      expect(xml, contains('factoryName="DAPConfiguration"'));
      expect(xml, contains(r'C:\tools\xcross.exe'));
      expect(xml, contains(' flutter dap'));
      expect(xml, contains('&quot;xcross&quot;:true'));
      expect(xml, contains('*.dart'));
      expect(xml, contains(r'$PROJECT_DIR$'));
      expect(xml, contains('debugServerWaitStrategy" value="TIMEOUT"'));
      expect(xml, contains('connectTimeout" value="0"'));
    });

    test('quotes paths with spaces', () {
      final xml = buildIdeaRunXml(r'C:\Program Files\xcross.exe');
      expect(
        xml,
        contains(r'&quot;C:\Program Files\xcross.exe&quot; flutter dap'),
      );
    });
  });

  group('IdeaCommand', () {
    late Directory temp;
    late Directory previous;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('xcross-ide-idea-');
      previous = Directory.current;
      Directory.current = temp;
    });

    tearDown(() {
      Directory.current = previous;
      temp.deleteSync(recursive: true);
    });

    test('writes .run/xcross_ios_device.run.xml once', () async {
      await IdeaCommand().run();
      final file = File(p.join(temp.path, '.run', 'xcross_ios_device.run.xml'));
      expect(file.existsSync(), isTrue);
      final body = file.readAsStringSync();
      expect(body, contains('DAPConfiguration'));
      expect(body, contains('*.dart'));

      final before = body;
      await IdeaCommand().run();
      expect(file.readAsStringSync(), before);
    });
  });
}
