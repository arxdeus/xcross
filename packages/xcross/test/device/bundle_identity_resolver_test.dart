import 'package:apple_developer_kit/shared/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/asc_models.dart';
import 'package:test/test.dart';
import 'package:xcross/src/shared/cli/command_prompt.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/target/iphone/device/internal/bundle_identity_resolver.dart';

import 'test_log_output.dart';

void main() {
  const requested = 'com.example.App';
  const prefixed = 'XCR-TEAM.com.example.App';

  Future<String> resolve(
    FakeBundleClient client, {
    CommandPrompt? prompt,
    Map<String, String> environment = const {},
  }) async => (await BundleIdentityResolver(
    client: client,
    log: testLog(),
    prompt: prompt,
    environment: environment,
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
  });

  test('falls back to prefixed when the original id is taken', () async {
    final client = FakeBundleClient(
      registerError: const AppleApiError(409, 'taken'),
    );
    expect(
      await resolve(client, prompt: ScriptedPrompt(['original'])),
      prefixed,
    );
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
