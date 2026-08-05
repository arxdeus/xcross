# cli_kit

Shared CLI utilities used by [xcross](https://github.com/arxdeus/xcross) and
related tools: status-line logging, process runners, downloads with progress,
and host privilege helpers.

## Install

```sh
dart pub add cli_kit
```

## Usage

```dart
import 'package:cli_kit/cli_kit.dart';

Log.logInfo('Device', 'iPhone 15 Pro');
await Log.logStep('Building', () async {
  await ProcessRunner.runChecked('echo', ['ok']);
});

await Downloader.downloadToFile(
  'https://example.com/file.bin',
  File('file.bin'),
  label: 'file.bin',
);

// POSIX: cache a sudo ticket. Windows: require an elevated shell.
await HostPrivileges.ensureDeviceToolAccess();
```

## API surface

| Type | Role |
| --- | --- |
| `Log` / `Step` / `Glyph` | Status lines, spinners, verbose traces |
| `ProcessRunner` | UTF-8 process run/capture, `which`, polling |
| `Downloader` | HTTP download to file/string with retries |
| `HostPrivileges` / `Sudo` | Device-tool elevation on POSIX and Windows |
| `CliError` | User-facing error (message only, no stack) |

## Related

Part of the [xcross](https://github.com/arxdeus/xcross) monorepo.
