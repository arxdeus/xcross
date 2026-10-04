import 'dart:io';

import 'package:apple_developer_kit/src/apple_http_client.dart';
import 'package:http/io_client.dart';
import 'package:test/test.dart';

void main() {
  test(
    'uses selected context and transport lazily without native HTTP fallback',
    () {
      HttpOverrides.runZoned(
        () {
          final events = <String>[];
          final context = SecurityContext();
          final transport = RecordingHttpClient();
          final factory = AppleHttpClientFactory(
            createSecurityContext: () {
              events.add('context');
              return context;
            },
            createHttpClient: (selected) {
              events.add('transport');
              expect(selected, same(context));
              return transport;
            },
          );
          expect(events, isEmpty);
          final client = factory.createClient();
          expect(client, isA<IOClient>());
          expect(events, ['context', 'transport']);
          expect(transport.closeForces, isEmpty);
          client.close();
          client.close();
          expect(transport.closeForces, [true]);
        },
        createHttpClient: (_) =>
            throw StateError('Unexpected native HTTP client'),
      );
    },
  );

  test('creates independent selected contexts and transports per client', () {
    final contexts = <SecurityContext>[];
    final transports = <RecordingHttpClient>[];
    final factory = AppleHttpClientFactory(
      createSecurityContext: () {
        final context = SecurityContext();
        contexts.add(context);
        return context;
      },
      createHttpClient: (context) {
        expect(context, same(contexts.last));
        final transport = RecordingHttpClient();
        transports.add(transport);
        return transport;
      },
    );
    final first = factory.createClient();
    final second = factory.createClient();
    expect(contexts, hasLength(2));
    expect(contexts.first, isNot(same(contexts.last)));
    first.close();
    expect(transports.first.closeForces, [true]);
    expect(transports.last.closeForces, isEmpty);
    second.close();
    expect(transports.last.closeForces, [true]);
  });

  test('installs published Apple root without acquiring transport', () {
    final context = SecurityContext();
    final factory = AppleHttpClientFactory(
      createSecurityContext: () => context,
      createHttpClient: (_) => throw StateError('Unexpected transport'),
    );
    expect(factory.createSecurityContext(), same(context));
  });

  test('propagates selected context failure without acquiring transport', () {
    final error = StateError('Context creation failed');
    final factory = AppleHttpClientFactory(
      createSecurityContext: () => throw error,
      createHttpClient: (_) => throw StateError('Unexpected transport'),
    );
    expect(factory.createClient, throwsA(same(error)));
  });

  test('propagates selected transport failure with exact context', () {
    final error = StateError('Transport creation failed');
    final context = SecurityContext();
    final factory = AppleHttpClientFactory(
      createSecurityContext: () => context,
      createHttpClient: (selected) {
        expect(selected, same(context));
        throw error;
      },
    );
    expect(factory.createClient, throwsA(same(error)));
  });
}

final class RecordingHttpClient implements HttpClient {
  final List<bool> closeForces = [];

  @override
  void close({bool force = false}) => closeForces.add(force);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected HTTP operation: ${invocation.memberName}');
}
