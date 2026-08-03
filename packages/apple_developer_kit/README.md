# apple_developer_kit

Apple Developer tooling for Dart: GrandSlam / Anisette login, App Store Connect
provisioning, in-process codesigning, and the ADI (Provision) client.

```dart
import 'package:apple_developer_kit/apple_developer_kit.dart';

final store = GrandSlamSessionStore();
```

ADI code is derived from [Dadoum/Provision](https://github.com/Dadoum/Provision)
(LGPLv2); see `NOTICE.md` and `ADI_LICENSE`.
