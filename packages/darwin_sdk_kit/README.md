# darwin_sdk_kit

Resolve and install Darwin/iOS SDK artifact bundles (from `Xcode.xip`) and find
a usable `ld64.lld` on Linux/Windows.

```dart
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';

final sdk = DarwinSdk.current();
final linker = await DarwinSdk.resolveLd64Lld(sdk!);
```
