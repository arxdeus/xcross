import 'package:meta/meta.dart';

@internal
const xcrossComposeRoles = <String, Map<String, String>>{
  'package:xcross/src/shared/compose/apple_toolchain.dart': {
    'CLASS:AppleToolEnvironment': 'internal',
    'CLASS:AppleToolchainStager': 'internal',
    'FUNCTION:_findCompilerRtDarwinDir': 'private',
    'TOP_LEVEL_VARIABLE:_appleToolAliases': 'private',
    'TOP_LEVEL_VARIABLE:_compilerRtLibraryNames': 'private',
  },
  'package:xcross/src/shared/compose/build/compose_app_assembler.dart': {
    'CLASS:ComposeAppAssembler': 'internal',
    'FUNCTION:_copyDirectoryNoSymlinks': 'private',
    'TYPE_ALIAS:ComposeCopyDirectory': 'internal',
    'TYPE_ALIAS:ComposeMakeExecutable': 'internal',
    'TYPE_ALIAS:ComposeRenameDirectory': 'internal',
    'TYPE_ALIAS:ComposeSignSimulator': 'internal',
  },
  'package:xcross/src/shared/compose/build/compose_entitlements.dart': {
    'CLASS:ComposeEntitlements': 'internal',
  },
  'package:xcross/src/shared/compose/build/compose_info_plist.dart': {
    'CLASS:ComposeInfoPlist': 'internal',
  },
  'package:xcross/src/shared/compose/build/compose_pack_operation.dart': {
    'CLASS:ComposePackOperation': 'internal',
    'TYPE_ALIAS:ComposeCurrentDirectory': 'internal',
    'TYPE_ALIAS:ComposeDetectProject': 'internal',
    'TYPE_ALIAS:ComposePackProject': 'internal',
  },
  'package:xcross/src/shared/compose/build/compose_packer.dart': {
    'CLASS:ComposePacker': 'internal',
    'TYPE_ALIAS:ComposeAssembleApp': 'internal',
    'TYPE_ALIAS:ComposeBuildFramework': 'internal',
    'TYPE_ALIAS:ComposeBuildKlib': 'internal',
    'TYPE_ALIAS:ComposeBuildRunner': 'internal',
    'TYPE_ALIAS:ComposeEnsureToolchain': 'internal',
  },
  'package:xcross/src/shared/compose/build/framework_build_stamp.dart': {
    'CLASS:FrameworkBuildStamp': 'internal',
  },
  'package:xcross/src/shared/compose/build/gradle_klib_builder.dart': {
    'CLASS:GradleKlibBuilder': 'internal',
    'CLASS:GradleKlibResult': 'internal',
    'TYPE_ALIAS:GradleRunChecked': 'internal',
  },
  'package:xcross/src/shared/compose/build/konan_configuration.dart': {
    'CLASS:KonanConfiguration': 'internal',
    'CLASS:PreparedKonanConfiguration': 'internal',
    'FUNCTION:_slash': 'private',
    'TOP_LEVEL_VARIABLE:_appleKonanTargets': 'private',
    'TYPE_ALIAS:KonanPatchCompilerJar': 'internal',
    'TYPE_ALIAS:MakeExecutable': 'internal',
  },
  'package:xcross/src/shared/compose/build/kotlin_framework_builder.dart': {
    'CLASS:KotlinFrameworkBuilder': 'internal',
    'TYPE_ALIAS:KotlinNativeRunChecked': 'internal',
    'TYPE_ALIAS:PrepareKonanConfiguration': 'internal',
  },
  'package:xcross/src/shared/compose/build/kotlin_native_caches.dart': {
    'CLASS:KotlinNativeCaches': 'internal',
    'TYPE_ALIAS:KotlinNativeCacheRun': 'internal',
  },
  'package:xcross/src/shared/compose/build/mach_o_validator.dart': {
    'CLASS:MachOValidator': 'internal',
  },
  'package:xcross/src/shared/compose/build/objc_runner_builder.dart': {
    'CLASS:ObjcRunnerBuilder': 'internal',
    'FUNCTION:_iphoneSdk': 'private',
    'FUNCTION:_validateFramework': 'private',
    'TOP_LEVEL_VARIABLE:_iosMinimumVersion': 'private',
    'TYPE_ALIAS:ComposeRunChecked': 'internal',
  },
  'package:xcross/src/shared/compose/build/process_invocation.dart': {
    'CLASS:ProcessInvocation': 'internal',
  },
  'package:xcross/src/shared/compose/build/swift_runner_builder.dart': {
    'CLASS:SwiftRunnerBuilder': 'internal',
    'FUNCTION:_clangBuiltins': 'private',
    'FUNCTION:_iphoneSdk': 'private',
    'FUNCTION:_validateFramework': 'private',
    'FUNCTION:compilerRtIos': 'internal',
    'TOP_LEVEL_VARIABLE:_iosMinimumVersion': 'private',
    'TYPE_ALIAS:SwiftRunnerRunChecked': 'internal',
  },
  'package:xcross/src/shared/compose/compose_build_context.dart': {
    'CLASS:ComposeBuildContext': 'internal',
  },
  'package:xcross/src/shared/compose/compose_directory_publisher.dart': {
    'CLASS:ComposeDirectoryPublisher': 'internal',
  },
  'package:xcross/src/shared/compose/compose_host.dart': {
    'CLASS:ComposeHost': 'internal',
  },
  'package:xcross/src/shared/compose/compose_install_effects.dart': {
    'TYPE_ALIAS:DigestFile': 'internal',
    'TYPE_ALIAS:DownloadToFile': 'internal',
    'TYPE_ALIAS:ExtractArchive': 'internal',
    'TYPE_ALIAS:InstallRoot': 'internal',
    'TYPE_ALIAS:PatchCompilerJar': 'internal',
    'TYPE_ALIAS:RenameDirectory': 'internal',
    'TYPE_ALIAS:RunChecked': 'internal',
  },
  'package:xcross/src/shared/compose/compose_ios_constants.dart': {
    'TOP_LEVEL_VARIABLE:composeDefaultSdkVersion': 'internal',
    'TOP_LEVEL_VARIABLE:composeMinimumIosVersion': 'internal',
    'TOP_LEVEL_VARIABLE:composePlistSdkVersion': 'internal',
  },
  'package:xcross/src/shared/compose/compose_java_resolver.dart': {
    'CLASS:ComposeJava': 'internal',
    'CLASS:ComposeJavaResolver': 'internal',
  },
  'package:xcross/src/shared/compose/compose_process_contracts.dart': {
    'CLASS:ComposeDarwinSdk': 'internal',
    'CLASS:ComposeProcessResult': 'internal',
    'CLASS:RepositoryComposeDarwinSdk': 'internal',
    'TYPE_ALIAS:ComposeRun': 'internal',
    'TYPE_ALIAS:ComposeWhich': 'internal',
    'TYPE_ALIAS:CurrentDarwinSdk': 'internal',
    'TYPE_ALIAS:ResolveLd64Lld': 'internal',
  },
  'package:xcross/src/shared/compose/compose_setup_options.dart': {
    'CLASS:ComposeSetupOptions': 'internal',
    'TOP_LEVEL_VARIABLE:kotlinNativeMavenBase': 'internal',
  },
  'package:xcross/src/shared/compose/compose_simulator_signing.dart': {
    'CLASS:ComposeSimulatorSigning': 'internal',
  },
  'package:xcross/src/shared/compose/gradle_kmp_metadata.dart': {
    'CLASS:ComposeModuleSpec': 'internal',
    'CLASS:GradleKmpMetadataParser': 'internal',
  },
  'package:xcross/src/shared/compose/jvm_binary.dart': {
    'FUNCTION:emitClassU2': 'internal',
    'FUNCTION:emitClassU4': 'internal',
    'FUNCTION:readClassU2': 'internal',
    'FUNCTION:readClassU4': 'internal',
  },
  'package:xcross/src/shared/compose/klib_manifest.dart': {
    'CLASS:KlibManifestReader': 'internal',
    'FUNCTION:_continues': 'private',
    'FUNCTION:_unescape': 'private',
    'FUNCTION:parseJavaProperties': 'internal',
  },
  'package:xcross/src/shared/compose/kmp_entry_discovery.dart': {
    'CLASS:ComposeCandidate': 'internal',
    'CLASS:ComposeEntryResult': 'internal',
    'CLASS:KmpEntryDiscovery': 'internal',
  },
  'package:xcross/src/shared/compose/kmp_project_detector.dart': {
    'CLASS:ComposeIdentity': 'internal',
    'CLASS:KmpProjectDetector': 'internal',
    'FUNCTION:_capitalize': 'private',
    'FUNCTION:_defaultIdentity': 'private',
    'FUNCTION:_nonEmpty': 'private',
  },
  'package:xcross/src/shared/compose/kotlin_class_file.dart': {
    'CLASS:KotlinClassAttribute': 'internal',
    'CLASS:KotlinClassFile': 'internal',
    'CLASS:KotlinClassMember': 'internal',
  },
  'package:xcross/src/shared/compose/kotlin_constant_pool.dart': {
    'CLASS:KotlinConstantPoolData': 'internal',
    'CLASS:KotlinConstantPoolEntry': 'internal',
    'FUNCTION:readKotlinConstantPool': 'internal',
    'TOP_LEVEL_VARIABLE:jvmcpClass': 'internal',
    'TOP_LEVEL_VARIABLE:jvmcpDouble': 'internal',
    'TOP_LEVEL_VARIABLE:jvmcpDynamic': 'internal',
    'TOP_LEVEL_VARIABLE:jvmcpFieldref': 'internal',
    'TOP_LEVEL_VARIABLE:jvmcpFloat': 'internal',
    'TOP_LEVEL_VARIABLE:jvmcpIfMethodref': 'internal',
    'TOP_LEVEL_VARIABLE:jvmcpInteger': 'internal',
    'TOP_LEVEL_VARIABLE:jvmcpInvokeDynamic': 'internal',
    'TOP_LEVEL_VARIABLE:jvmcpLong': 'internal',
    'TOP_LEVEL_VARIABLE:jvmcpMethodHandle': 'internal',
    'TOP_LEVEL_VARIABLE:jvmcpMethodType': 'internal',
    'TOP_LEVEL_VARIABLE:jvmcpMethodref': 'internal',
    'TOP_LEVEL_VARIABLE:jvmcpModule': 'internal',
    'TOP_LEVEL_VARIABLE:jvmcpNameAndType': 'internal',
    'TOP_LEVEL_VARIABLE:jvmcpPackage': 'internal',
    'TOP_LEVEL_VARIABLE:jvmcpString': 'internal',
    'TOP_LEVEL_VARIABLE:jvmcpUtf8': 'internal',
  },
  'package:xcross/src/shared/compose/kotlin_native_cache_plan.dart': {
    'CLASS:KlibCacheNode': 'internal',
    'CLASS:KotlinNativeCachePlan': 'internal',
  },
  'package:xcross/src/shared/compose/kotlin_native_cache_planner.dart': {
    'CLASS:KlibManifestNode': 'internal',
    'CLASS:KotlinNativeCachePlanner': 'internal',
  },
  'package:xcross/src/shared/compose/kotlin_native_class_patches.dart': {
    'FUNCTION:patchAppleConfigurablesImplClassBytes': 'internal',
    'FUNCTION:patchHostManagerClassBytes': 'internal',
    'FUNCTION:patchObjCExportClassBytes': 'internal',
    'TOP_LEVEL_VARIABLE:_aload0': 'private',
    'TOP_LEVEL_VARIABLE:_areturn': 'private',
    'TOP_LEVEL_VARIABLE:_iconst1': 'private',
    'TOP_LEVEL_VARIABLE:_invokeSpecial': 'private',
    'TOP_LEVEL_VARIABLE:_invokeVirtual': 'private',
    'TOP_LEVEL_VARIABLE:_ireturn': 'private',
    'TOP_LEVEL_VARIABLE:_return': 'private',
  },
  'package:xcross/src/shared/compose/kotlin_native_entries.dart': {
    'TOP_LEVEL_VARIABLE:appleConfigurablesImplClassEntry': 'internal',
    'TOP_LEVEL_VARIABLE:hostManagerClassEntry': 'internal',
    'TOP_LEVEL_VARIABLE:jarMarkerPath': 'internal',
    'TOP_LEVEL_VARIABLE:objcExportClassEntry': 'internal',
  },
  'package:xcross/src/shared/compose/models/compose_build_options.dart': {
    'CLASS:ComposeBuildOptions': 'internal',
    'ENUM:ComposeConfiguration': 'internal',
  },
  'package:xcross/src/shared/compose/project/ios_app_config.dart': {
    'CLASS:IosAppConfig': 'internal',
    'CLASS:IosAppConfigLoader': 'internal',
  },
  'package:xcross/src/shared/compose/project/kmp_project.dart': {
    'CLASS:KmpProject': 'internal',
    'ENUM:KmpEntryKind': 'internal',
  },
  'package:xcross/src/shared/compose/toolchain/archive_extractor.dart': {
    'CLASS:ArchiveExtractor': 'internal',
  },
  'package:xcross/src/shared/compose/toolchain/compose_toolchain.dart': {
    'CLASS:ComposeToolchain': 'internal',
  },
  'package:xcross/src/shared/compose/toolchain/compose_toolchain_installer.dart':
      {'CLASS:ComposeToolchainInstaller': 'internal'},
  'package:xcross/src/shared/compose/toolchain/compose_toolchain_resolver.dart':
      {
        'CLASS:ComposeToolchainResolver': 'internal',
        'CLASS:ResolvedToolchain': 'internal',
      },
  'package:xcross/src/shared/compose/toolchain/host_manager_patcher.dart': {
    'CLASS:KotlinNativeJarPatcher': 'internal',
    'FUNCTION:_addUnmodifiedEntry': 'private',
    'FUNCTION:_findEndOfCentralDirectory': 'private',
    'FUNCTION:_le2': 'private',
    'FUNCTION:_le4': 'private',
    'FUNCTION:_rejectDuplicateZipEntries': 'private',
  },
  'package:xcross/src/shared/compose/verified_compose_artifact_acquirer.dart': {
    'CLASS:VerifiedComposeArtifactAcquirer': 'internal',
    'FUNCTION:digestComposeArtifact': 'internal',
  },
  'package:xcross/src/shared/compose/watch/compose_watch_session.dart': {
    'CLASS:ComposeWatchSession': 'internal',
    'TYPE_ALIAS:ComposeRebuild': 'internal',
    'TYPE_ALIAS:ComposeRunSession': 'internal',
  },
  'package:xcross/src/shared/compose/watch/kotlin_source_watcher.dart': {
    'CLASS:KotlinSourceWatcher': 'internal',
  },
};
