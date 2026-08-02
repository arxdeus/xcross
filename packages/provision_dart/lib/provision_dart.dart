/// Dart port of Provision's ADI (Apple Device Identity) provisioning
/// client, used to authenticate with Apple's private GrandSlam login
/// protocol (Anisette). Ported from https://github.com/Dadoum/Provision
/// (LGPLv2). See NOTICE.md for what was ported vs. original, and for a
/// flagged divergence from upstream's native-library loading strategy.
library provision_dart;

export 'src/adi_bindings.dart' show AdiNativeBindings;
export 'src/adi_client.dart'
    show
        AdiClient,
        AdiClientProvisioningIntermediateMetadata,
        AdiErrorCode,
        AdiException,
        AdiOneTimePassword,
        AdiSynchronizationResult;
export 'src/apk_fetch.dart' show AdiLibraryFetcher, appleMusicApkUrl;
export 'src/loader/loader.dart' show LoadedNativeLibrary, NativeLibraryLoader;
export 'src/loader/loader_posix.dart' show PosixNativeLibraryLoader;
export 'src/loader/loader_windows.dart' show WindowsNativeLibraryLoader;
