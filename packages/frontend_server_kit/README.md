# frontend_server_kit

Persistent `frontend_server` session driver for incremental kernel compile,
hot reload, and VM Service `compileExpression` — including Flutter targets and
`package:` URI rewriting.

## Install

```sh
dart pub add frontend_server_kit
```

## Usage

Pass absolute paths in `FrontendServerOptions` and a caller-selected process
factory, filesystem and path context. `HostCompilerProcessFactory(runner)`
is the provided host adapter. The package URI loader must share the exact
filesystem and context with the session. The session closes its compiler
transport, while the caller retains ownership of supplied services.

```dart
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:frontend_server_kit/shared/compiler/frontend_server_options.dart';
import 'package:frontend_server_kit/shared/compiler/frontend_server_session.dart';
import 'package:frontend_server_kit/shared/compiler/package_uris.dart';
import 'package:frontend_server_kit/shared/process/compiler_transport.dart';
import 'package:path/path.dart' as p;

Future<void> compileAndReload({
  required FrontendServerOptions options,
  required CompilerProcessFactory processFactory,
  required HostFileSystemInterface fileSystem,
  required p.Context paths,
  required void Function(String) diagnostics,
  required List<String> invalidated,
}) async {
  final session = FrontendServerSession(
    options,
    processFactory: processFactory,
    fileSystem: fileSystem,
    paths: paths,
    packageUriLoader: PackageUriLoader(fileSystem: fileSystem, paths: paths),
    diagnostics: diagnostics,
  );
  try {
    await session.spawn();
    final dill = await session.compile();
    await session.accept();
    diagnostics('compiled: $dill');
    final incremental = await session.recompile(invalidated: invalidated);
    await session.accept();
    diagnostics('incremental: $incremental');
    await session.reset();
    await session.recompile(invalidated: invalidated);
    await session.accept();
  } finally {
    await session.close();
  }
}
```

After successful hot reload, accept the incremental result. Reject it with
`session.reject()` if the runtime cannot apply it. Reset before recompiling
for hot restart to request a full kernel component.

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
