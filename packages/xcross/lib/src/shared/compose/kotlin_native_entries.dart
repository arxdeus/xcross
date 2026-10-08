import 'package:meta/meta.dart';

@internal
const String jarMarkerPath = 'META-INF/XCROSS_HOST_MANAGER_PATCHED';

/// JAR-internal path of Kotlin/Native's HostManager class.
@internal
const String hostManagerClassEntry =
    'org/jetbrains/kotlin/konan/target/HostManager.class';

/// JAR-internal path of ObjCExportKt class.
@internal
const String objcExportClassEntry =
    'org/jetbrains/kotlin/backend/konan/objcexport/ObjCExportKt.class';

/// JAR-internal path of Kotlin/Native's AppleConfigurablesImpl class.
@internal
const String appleConfigurablesImplClassEntry =
    'org/jetbrains/kotlin/konan/target/AppleConfigurablesImpl.class';
