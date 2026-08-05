# frontend_server_kit

Persistent `frontend_server` session driver for incremental kernel compile,
hot reload, and VM Service `compileExpression` — including Flutter targets and
`package:` URI rewriting.

## Install

```sh
dart pub add frontend_server_kit
```

## Usage

```dart
import 'package:frontend_server_kit/frontend_server_kit.dart';

final session = FrontendServerSession(
  FrontendServerOptions(
    dart: dartExe,
    frontendServer: snapshotPath,
    sdkRoot: patchedSdkRoot,
    packageConfig: packageConfigPath,
    entrypoint: entrypointPath,
    outputDill: outputDillPath,
    // target: 'flutter', // default
    // dartDefines: ['FOO=bar'],
  ),
);

await session.spawn();
final dill = await session.compile();
await session.accept();

// Hot reload: recompile invalidated sources, then accept or reject.
final incremental = await session.recompile(
  invalidated: ['file:///…/lib/main.dart'],
);
await session.accept();

// Hot restart needs a full kernel component next:
await session.reset();
await session.recompile(invalidated: [/* … */]);
await session.accept();

await session.close();
```

`PackageUris` maps local file paths to `package:` URIs via
`.dart_tool/package_config.json` so breakpoints and recompiles match the
kernel's import URIs across hosts.

## Scope

- Spawns and drives one long-lived `frontend_server` over stdin/stdout.
- Serializes `compile` / `recompile` / `compileExpression` so DevTools evaluate
  cannot interleave with a reload.
- Does **not** locate Flutter or the frontend_server snapshot for you — pass
  absolute paths in `FrontendServerOptions`.

## Related

Part of the [xcross](https://github.com/arxdeus/xcross) monorepo.
