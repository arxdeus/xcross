# cli_kit

Shared CLI utilities used by xcross and related tools: status-line logging,
process runners, file downloads with progress, and host privilege helpers.

```dart
import 'package:cli_kit/cli_kit.dart';

Log.logInfo('Hello');
await ProcessRunner.runChecked('echo', ['ok']);
```
