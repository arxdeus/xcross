# frontend_server_kit

Persistent `frontend_server` session driver for incremental kernel compile,
hot reload, and VM Service `compileExpression` — including Flutter targets,
custom Dart/AOT runtimes, and `package:` URI rewriting.

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
  ),
);
await session.spawn();
await session.compile();
await session.accept();
```
