/// Darwin/iOS SDK resolution and Xcode.xip extraction.
library;

export 'src/host/linux/linux_darwin_toolchain_locations.dart';
export 'src/host/macos/macos_darwin_toolchain_locations.dart';
export 'src/host/shared/darwin_toolchain_locations.dart';
export 'src/host/windows/windows_darwin_toolchain_locations.dart';
export 'src/shared/archive/cpio_reader.dart';
export 'src/shared/archive/pbzx_reader.dart';
export 'src/shared/archive/xar_reader.dart';
export 'src/shared/archive/xcode_xip_extractor.dart';
export 'src/shared/errors/errors.dart';
export 'src/shared/sdk/darwin_sdk.dart';
export 'src/shared/sdk/darwin_sdk_repository.dart';
export 'src/shared/tbd/tbd_architecture_rewrite.dart';
export 'src/shared/tbd/tbd_bundle_patch.dart';
export 'src/shared/tbd/tbd_linker_diagnostic.dart';
export 'src/shared/toolchain/darwin_toolchain_resolver.dart';
export 'src/target/iphone/iphone_build_platform.dart';
export 'src/target/iphone/iphone_target.dart';
export 'src/target/shared/ios_build_platform.dart';
export 'src/target/shared/ios_target.dart';
export 'src/target/simulator/simulator_build_platform.dart';
export 'src/target/simulator/simulator_target.dart';
