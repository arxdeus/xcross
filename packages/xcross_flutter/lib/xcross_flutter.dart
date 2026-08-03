/// Flutter iOS packing and hot reload for xcross.
library;

export 'src/build/flutter_debug_bundler.dart';
export 'src/build/flutter_pack_operation.dart';
export 'src/build/flutter_packer.dart';
export 'src/build/hot_reload_setup.dart';
export 'src/build/info_plist.dart';
export 'src/build/ios_bundle_id.dart';
export 'src/build/ios_engine_cache.dart';
export 'src/build/ios_plugin_package.dart';
export 'src/build/ios_plugins.dart';
export 'src/build/macho_dylib_rewriter.dart';
export 'src/build/runner_shim.dart';
export 'src/constants.dart'
    show
        FlutterDeviceConstants,
        GeneratedPluginsConstants,
        IosDeploymentConstants,
        PlistDefaults,
        flutterArtifactBaseUrl;
export 'src/errors.dart' show FlutterBuildError;
export 'src/hot_reload/dart_vm_service_client.dart' show DartVmServiceClient;
export 'src/hot_reload/hot_reload_controller.dart' show HotReloadController;
export 'src/hot_reload/source_watcher.dart' show SourceWatcher;
export 'src/hot_reload/vm_service_output.dart' show VmServiceOutput;
export 'src/models/flutter/dart_defines.dart';
export 'src/models/flutter/flutter_build_options.dart';
export 'src/models/hot_reload_config.dart' show HotReloadConfig;
export 'src/models/pubspec_info.dart' show PubspecInfo;
