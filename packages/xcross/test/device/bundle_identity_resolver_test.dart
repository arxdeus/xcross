import 'dart:io';

import 'package:apple_developer_kit/shared/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/asc_models.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/cli/command_prompt.dart';
import 'package:xcross/src/shared/config/project_settings.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/target/iphone/device/internal/bundle_identity_resolver.dart';

import '../config/project_settings_test.dart' show IoFileSystem;
import 'test_log_output.dart';

void main() {
  const requested = 'com.example.App';
  const prefixed = 'XCR-TEAM.com.example.App';
  late Directory root;
  late ProjectSettings settings;
  setUp(() {
    root = Directory.systemTemp.createTempSync('bundle-identity-');
    settings = ProjectSettings(
      fileSystem: const IoFileSystem(),
      projectRoot: root.path,
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  File projectFile() => File(p.join(root.path, 'xcross_project.yaml'));

  Future<String> resolve(
    FakeBundleClient client, {
    CommandPrompt? prompt,
    Map<String, String> environment = const {},
    bool withSettings = true,
  }) async => (await BundleIdentityResolver(
    client: client,
    log: testLog(),
    prompt: prompt,
    environment: environment,
    settings: withSettings ? settings : null,
  ).resolve(requested: requested, signingIdentityId: 'team-1')).exact;

  test('reuses an original App ID the team owns without asking', () async {
    final prompt = ScriptedPrompt([]);
    final client = FakeBundleClient(owned: {requested});
    expect(await resolve(client, prompt: prompt), requested);
    expect(prompt.asked, isEmpty);
    expect(client.registered, isEmpty);
  });

  test(
    'reuses a prefixed App ID from an earlier build without asking',
    () async {
      final prompt = ScriptedPrompt([]);
      final client = FakeBundleClient(owned: {prefixed});
      expect(await resolve(client, prompt: prompt), prefixed);
      expect(prompt.asked, isEmpty);
    },
  );

  test('asks on the first build and defaults to prefixed', () async {
    final prompt = ScriptedPrompt(['']);
    final client = FakeBundleClient();
    expect(await resolve(client, prompt: prompt), prefixed);
    expect(prompt.asked, hasLength(1));
    expect(
      prompt.written.join(),
      allOf(contains(prefixed), contains(requested)),
    );
    expect(client.registered, isEmpty);
  });

  test('registers the original id when chosen', () async {
    final prompt = ScriptedPrompt(['nope', '2']);
    final client = FakeBundleClient();
    expect(await resolve(client, prompt: prompt), requested);
    expect(prompt.asked, hasLength(2));
    expect(client.registered, [requested]);
    expect(projectFile().readAsStringSync(), 'bundle_id: original\n');
  });

  test('saves prefixed when the original id is taken', () async {
    final client = FakeBundleClient(
      registerError: const AppleApiError(409, 'taken'),
    );
    expect(
      await resolve(client, prompt: ScriptedPrompt(['original'])),
      prefixed,
    );
    expect(projectFile().readAsStringSync(), 'bundle_id: prefixed\n');
  });

  test('surfaces auth failures while registering', () {
    final client = FakeBundleClient(
      registerError: const AppleApiError(401, 'no'),
    );
    expect(
      resolve(client, prompt: ScriptedPrompt(['2'])),
      throwsA(isA<AppleApiError>()),
    );
  });

  test('never asks without a terminal', () async {
    final prompt = ScriptedPrompt([], interactive: false);
    expect(await resolve(FakeBundleClient(), prompt: prompt), prefixed);
    expect(prompt.asked, isEmpty);
    expect(projectFile().existsSync(), isFalse);
  });

  test('the saved choice wins over App IDs on the team', () async {
    projectFile().writeAsStringSync('bundle_id: prefixed\n');
    final prompt = ScriptedPrompt([]);
    final client = FakeBundleClient(owned: {requested});
    expect(await resolve(client, prompt: prompt), prefixed);
    expect(prompt.asked, isEmpty);
  });

  test('a saved original id is registered when missing', () async {
    projectFile().writeAsStringSync('bundle_id: original\n');
    final client = FakeBundleClient();
    expect(await resolve(client, prompt: ScriptedPrompt([])), requested);
    expect(client.registered, [requested]);
  });

  test('rejects an unknown saved choice', () {
    projectFile().writeAsStringSync('bundle_id: maybe\n');
    expect(resolve(FakeBundleClient()), throwsA(isA<XcrossError>()));
  });

  test('XCROSS_BUNDLE_ID wins over the saved choice', () async {
    projectFile().writeAsStringSync('bundle_id: original\n');
    expect(
      await resolve(
        FakeBundleClient(),
        environment: {'XCROSS_BUNDLE_ID': 'prefixed'},
      ),
      prefixed,
    );
  });

  test('asks without saving when the project root is unknown', () async {
    expect(
      await resolve(
        FakeBundleClient(),
        prompt: ScriptedPrompt(['2']),
        withSettings: false,
      ),
      requested,
    );
    expect(projectFile().existsSync(), isFalse);
  });

  test('never asks inside a DAP session', () async {
    final prompt = ScriptedPrompt([]);
    expect(
      await resolve(
        FakeBundleClient(),
        prompt: prompt,
        environment: {'XCROSS_DAP': '1'},
      ),
      prefixed,
    );
    expect(prompt.asked, isEmpty);
  });

  test('XCROSS_BUNDLE_ID forces the choice', () async {
    final prompt = ScriptedPrompt([]);
    final client = FakeBundleClient();
    expect(
      await resolve(
        client,
        prompt: prompt,
        environment: {'XCROSS_BUNDLE_ID': 'original'},
      ),
      requested,
    );
    expect(prompt.asked, isEmpty);
    expect(client.registered, [requested]);
  });

  test('rejects an unknown XCROSS_BUNDLE_ID', () {
    expect(
      resolve(FakeBundleClient(), environment: {'XCROSS_BUNDLE_ID': 'maybe'}),
      throwsA(isA<XcrossError>()),
    );
  });
}

final class ScriptedPrompt implements CommandPrompt {
  ScriptedPrompt(this.answers, {this.interactive = true});
  final List<String> answers;
  final bool interactive;
  final asked = <String>[];
  final written = <String>[];

  @override
  bool get isInteractive => interactive;
  @override
  void write(String value) => written.add(value);
  @override
  String? readLine(String prompt) {
    asked.add(prompt);
    return answers.isEmpty ? null : answers.removeAt(0);
  }

  @override
  String? readSecret(String prompt, {required String valueName}) =>
      throw UnimplementedError();
}

final class FakeBundleClient implements DevelopmentProvisioningClient {
  FakeBundleClient({this.owned = const {}, this.registerError});
  final Set<String> owned;
  final AppleApiError? registerError;
  final registered = <String>[];

  @override
  Future<AscBundleId?> findBundleId(String identifier) async =>
      owned.contains(identifier)
      ? AscBundleId(id: identifier, identifier: identifier, name: identifier)
      : null;

  @override
  Future<AscBundleId> registerBundleId({
    required String identifier,
    required String name,
  }) async {
    if (registerError case final error?) throw error;
    registered.add(identifier);
    return AscBundleId(id: identifier, identifier: identifier, name: name);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected ${invocation.memberName}');
}
