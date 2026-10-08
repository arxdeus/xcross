# cli_kit

Shared CLI utilities used by [xcross](https://github.com/arxdeus/xcross) and
related tools: status-line logging, process runners, downloads with progress,
and host privilege helpers.

## Install

```sh
dart pub add cli_kit
```

## Usage

Pass a runner, logging output and privilege service composed for the intended
host. The caller owns their streams. The downloader closes each fresh HTTP
client returned by its factory. POSIX elevation may prompt for sudo, while
Windows requires an elevated shell.

```dart
import 'dart:io';
import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';

Future<void> useCliTools<T extends PlatformHostInterface>({
  required LogOutput output,
  required ProcessRunner<T> runner,
  required HostPrivilegesInterface privileges,
  required HttpClient Function() createClient,
}) async {
  final log = Log(output: output);
  log.logInfo('Device', 'iPhone 15 Pro');
  await log.logStep('Building', () => runner.runChecked('echo', ['ok']));
  final downloader = Downloader(createClient: createClient, log: log);
  await downloader.downloadToFile(
    'https://example.com/file.bin',
    runner.host.fileSystem.file('file.bin'),
    label: 'file.bin',
  );
  await privileges.ensureElevated();
}
```

## API surface

| Type | Role |
| --- | --- |
| `Log` / `Step` / `Glyph` | Status lines, spinners, verbose traces |
| `ProcessRunner` | UTF-8 process run/capture, `which`, polling |
| `Downloader` | HTTP download to file/string with retries |
| `HostPrivilegesInterface` / `PosixPrivileges` / `WindowsPrivileges` | Device-tool elevation on POSIX and Windows |
| `CliError` | User-facing error (message only, no stack) |

## Related

Part of the [xcross](https://github.com/arxdeus/xcross) monorepo.
