# xcross_flutter

Build Flutter iOS `.app` bundles on Linux/Windows and drive hot reload over a
device tunnel (`dart_mobile_device`).

```dart
import 'package:xcross_flutter/xcross_flutter.dart';

final result = await FlutterPackOperation.pack(...);
```
