import 'package:meta/meta.dart';

@internal
const appleDeveloperKitRoles = <String, Map<String, String>>{
  'package:apple_developer_kit/composition/apple_host.dart': {
    'FUNCTION:createLinuxAppleHostServices': 'public',
    'FUNCTION:createMacOSAppleHostServices': 'public',
    'FUNCTION:createWindowsAppleHostServices': 'public',
  },
  'package:apple_developer_kit/composition/native_library_loader.dart': {
    'FUNCTION:createLinuxNativeLibraryLoader': 'public',
    'FUNCTION:createMacOSNativeLibraryLoader': 'public',
    'FUNCTION:createWindowsNativeLibraryLoader': 'public',
  },
  'package:apple_developer_kit/host/shared/adi/loader/loader.dart': {
    'CLASS:LoadedNativeLibrary': 'public',
    'CLASS:NativeLibraryLoader': 'public',
  },
  'package:apple_developer_kit/host/shared/apple_host_services.dart': {
    'CLASS:AppleFilePermissions': 'public',
    'CLASS:AppleHostServices': 'public',
    'CLASS:MachineIdentityProvider': 'public',
  },
  'package:apple_developer_kit/shared/adi/adi_client.dart': {
    'CLASS:AdiClientProvisioningIntermediateMetadata': 'public',
    'CLASS:AdiException': 'public',
    'CLASS:AdiOneTimePassword': 'public',
    'ENUM:AdiErrorCode': 'public',
  },
  'package:apple_developer_kit/shared/adi/apk_fetch.dart': {
    'CLASS:AdiLibraryFetcher': 'public',
    'CLASS:AdiLibraryPaths': 'public',
    'CLASS:AdiLibraryResolver': 'public',
    'TOP_LEVEL_VARIABLE:_libraryNames': 'private',
    'TOP_LEVEL_VARIABLE:appleMusicApkUrl': 'public',
  },
  'package:apple_developer_kit/shared/appstoreconnect/appstoreconnect.dart': {
    'CLASS:AscProvisioning': 'public',
    'CLASS:DevelopmentIdentityPaths': 'public',
    'TYPE_ALIAS:ProvisioningProgress': 'public',
  },
  'package:apple_developer_kit/shared/appstoreconnect/asc_capabilities.dart': {
    'CLASS:AscCapabilities': 'public',
  },
  'package:apple_developer_kit/shared/appstoreconnect/asc_client.dart': {
    'CLASS:AppleApiError': 'public',
    'CLASS:AscClient': 'public',
    'CLASS:DevelopmentProvisioningClient': 'public',
  },
  'package:apple_developer_kit/shared/appstoreconnect/asc_config.dart': {
    'CLASS:AscCredentials': 'public',
    'CLASS:AscCredentialsLoader': 'public',
  },
  'package:apple_developer_kit/shared/appstoreconnect/asc_models.dart': {
    'CLASS:AscAppGroup': 'public',
    'CLASS:AscBundleId': 'public',
    'CLASS:AscCertificate': 'public',
    'CLASS:AscDevice': 'public',
    'CLASS:AscProfile': 'public',
    'CLASS:AscProfileRef': 'public',
    'FUNCTION:_attributesOf': 'private',
  },
  'package:apple_developer_kit/shared/appstoreconnect/developer_services_client.dart':
      {'CLASS:DeveloperServicesClient': 'public'},
  'package:apple_developer_kit/shared/appstoreconnect/developer_services_team_discovery_client.dart':
      {
        'CLASS:DeveloperServicesTeam': 'public',
        'CLASS:DeveloperServicesTeamDiscoveryClient': 'public',
      },
  'package:apple_developer_kit/shared/appstoreconnect/provisioning_identifiers.dart':
      {'CLASS:ProvisioningIdentifiers': 'public'},
  'package:apple_developer_kit/shared/errors/errors.dart': {
    'CLASS:AppGroupsUnsupported': 'public',
    'CLASS:AppleError': 'public',
    'CLASS:AppleRateLimitError': 'public',
    'CLASS:CapabilitiesUnsupported': 'public',
  },
  'package:apple_developer_kit/shared/grandslam/anisette/adi_provisioning.dart':
      {
        'CLASS:AdiProvisioning': 'public',
        'TOP_LEVEL_VARIABLE:kAdiMachineDsId': 'internal',
        'TYPE_ALIAS:AdiProvisioningFactory': 'public',
      },
  'package:apple_developer_kit/shared/grandslam/anisette/anisette_data_provider.dart':
      {'CLASS:AnisetteDataProvider': 'public'},
  'package:apple_developer_kit/shared/grandslam/anisette/anisette_provider.dart':
      {'CLASS:AnisetteProvider': 'public'},
  'package:apple_developer_kit/shared/grandslam/anisette/anisette_state.dart': {
    'CLASS:AnisetteState': 'public',
    'CLASS:AnisetteStateStore': 'public',
  },
  'package:apple_developer_kit/shared/grandslam/anisette/grandslam_endpoints.dart':
      {
        'CLASS:GrandSlamEndpoints': 'public',
        'TOP_LEVEL_VARIABLE:_lookupUrl': 'private',
      },
  'package:apple_developer_kit/shared/grandslam/app_token_exchange.dart': {
    'CLASS:DeveloperServicesLoginToken': 'public',
    'CLASS:GrandSlamAppTokenExchange': 'public',
    'TOP_LEVEL_VARIABLE:_aadLength': 'private',
    'TOP_LEVEL_VARIABLE:_ivLength': 'private',
    'TOP_LEVEL_VARIABLE:_sessionKeyLength': 'private',
    'TOP_LEVEL_VARIABLE:_tagLength': 'private',
    'TOP_LEVEL_VARIABLE:kDeveloperServicesAppIdentifier': 'internal',
  },
  'package:apple_developer_kit/shared/grandslam/grandslam_login.dart': {
    'CLASS:GrandSlamAuthError': 'public',
    'CLASS:GrandSlamClient': 'public',
    'TOP_LEVEL_VARIABLE:_srpProtocols': 'private',
    'TOP_LEVEL_VARIABLE:_twoFactorRequiredStatus': 'private',
  },
  'package:apple_developer_kit/shared/grandslam/grandslam_login_data.dart': {
    'CLASS:GrandSlamLoginData': 'public',
  },
  'package:apple_developer_kit/shared/grandslam/grandslam_response.dart': {
    'CLASS:GrandSlamOperationError': 'public',
  },
  'package:apple_developer_kit/shared/grandslam/grandslam_session_store.dart': {
    'CLASS:GrandSlamSession': 'public',
    'CLASS:GrandSlamSessionStore': 'public',
  },
  'package:apple_developer_kit/shared/grandslam/grandslam_two_factor.dart': {
    'CLASS:GrandSlamIncorrectCodeError': 'public',
    'CLASS:GrandSlamTwoFactorCancelledError': 'public',
    'CLASS:GrandSlamTwoFactorRequiredError': 'public',
    'ENUM:GrandSlamTwoFactorMode': 'public',
    'TYPE_ALIAS:FetchTwoFactorCode': 'public',
  },
  'package:apple_developer_kit/shared/http/apple_http_client.dart': {
    'CLASS:AppleHttpClientFactory': 'public',
    'TOP_LEVEL_VARIABLE:_appleIncRootPem': 'private',
  },
  'package:apple_developer_kit/shared/secure/local_cipher.dart': {
    'CLASS:LocalCipher': 'public',
    'CLASS:LocalCipherError': 'public',
  },
  'package:apple_developer_kit/shared/signing/bundle_signer.dart': {
    'CLASS:BundleSigner': 'public',
  },
  'package:apple_developer_kit/shared/signing/signing_asset.dart': {
    'CLASS:SigningAsset': 'public',
    'CLASS:SigningAssetLoader': 'public',
  },
  'package:apple_developer_kit/src/host/linux/adi/linux_memory_allocator.dart':
      {'CLASS:LinuxMemoryAllocator': 'internal'},
  'package:apple_developer_kit/src/host/linux/adi/linux_native_library_loader.dart':
      {'CLASS:LinuxNativeLibraryLoader': 'internal'},
  'package:apple_developer_kit/src/host/linux/linux_machine_identity.dart': {
    'CLASS:LinuxMachineIdentity': 'internal',
  },
  'package:apple_developer_kit/src/host/macos/adi/macos_memory_allocator.dart':
      {'CLASS:MacOSMemoryAllocator': 'internal'},
  'package:apple_developer_kit/src/host/macos/adi/macos_native_library_loader.dart':
      {'CLASS:MacOSNativeLibraryLoader': 'internal'},
  'package:apple_developer_kit/src/host/macos/macos_machine_identity.dart': {
    'CLASS:MacOSMachineIdentity': 'internal',
  },
  'package:apple_developer_kit/src/host/shared/adi/elf/elf_code_preparation.dart':
      {
        'CLASS:ElfCodePreparation': 'internal',
        'CLASS:UnmodifiedElfCodePreparation': 'internal',
      },
  'package:apple_developer_kit/src/host/shared/adi/elf/elf_loaded_library.dart':
      {
        'CLASS:ElfLoadedLibrary': 'internal',
        'TYPE_ALIAS:ExternalSymbolResolver': 'internal',
      },
  'package:apple_developer_kit/src/host/shared/adi/loader/internal/memory_allocator.dart':
      {
        'CLASS:NativeMemoryAllocator': 'internal',
        'CLASS:NativeMemoryBlock': 'internal',
      },
  'package:apple_developer_kit/src/host/shared/adi/loader/internal/memory_allocator_posix.dart':
      {
        'CLASS:PosixMemoryAllocator': 'internal',
        'TOP_LEVEL_VARIABLE:_mapPrivate': 'private',
        'TOP_LEVEL_VARIABLE:_protExec': 'private',
        'TOP_LEVEL_VARIABLE:_protNone': 'private',
        'TOP_LEVEL_VARIABLE:_protRead': 'private',
        'TOP_LEVEL_VARIABLE:_protWrite': 'private',
        'TYPE_ALIAS:_MmapDart': 'private',
        'TYPE_ALIAS:_MprotectDart': 'private',
        'TYPE_ALIAS:_MunmapDart': 'private',
      },
  'package:apple_developer_kit/src/host/shared/adi/loader/internal/native_symbol_stubs.dart':
      {'CLASS:NativeSymbolStubs': 'internal'},
  'package:apple_developer_kit/src/host/shared/adi/loader/internal/posix_loaded_library.dart':
      {'CLASS:PosixLoadedLibrary': 'internal'},
  'package:apple_developer_kit/src/host/shared/adi/loader/internal/sysv_abi_bridge.dart':
      {
        'CLASS:SysvAbiBridge': 'internal',
        'FUNCTION:provisionClearCache': 'internal',
        'FUNCTION:provisionPosixSymbol': 'internal',
        'FUNCTION:provisionSysvWrapExport': 'internal',
        'FUNCTION:provisionSysvWrapImport': 'internal',
        'FUNCTION:provisionWindowsArm64PrepareCode': 'internal',
      },
  'package:apple_developer_kit/src/host/shared/adi/loader/loader_posix.dart': {
    'CLASS:PosixNativeLibraryLoader': 'internal',
  },
  'package:apple_developer_kit/src/host/shared/file_system_file_permissions.dart':
      {'CLASS:FileSystemAppleFilePermissions': 'internal'},
  'package:apple_developer_kit/src/host/windows/adi/loader/internal/memory_allocator_windows.dart':
      {
        'CLASS:WindowsMemoryAllocator': 'internal',
        'TOP_LEVEL_VARIABLE:_memCommit': 'private',
        'TOP_LEVEL_VARIABLE:_memRelease': 'private',
        'TOP_LEVEL_VARIABLE:_memReserve': 'private',
        'TOP_LEVEL_VARIABLE:_pageExecute': 'private',
        'TOP_LEVEL_VARIABLE:_pageExecuteRead': 'private',
        'TOP_LEVEL_VARIABLE:_pageExecuteReadwrite': 'private',
        'TOP_LEVEL_VARIABLE:_pageNoaccess': 'private',
        'TOP_LEVEL_VARIABLE:_pageReadonly': 'private',
        'TOP_LEVEL_VARIABLE:_pageReadwrite': 'private',
        'TYPE_ALIAS:_VirtualAllocDart': 'private',
        'TYPE_ALIAS:_VirtualFreeDart': 'private',
        'TYPE_ALIAS:_VirtualProtectDart': 'private',
      },
  'package:apple_developer_kit/src/host/windows/adi/loader/internal/native_symbol_stubs_windows.dart':
      {
        'CLASS:WindowsNativeSymbolStubs': 'internal',
        'TOP_LEVEL_VARIABLE:_ebadf': 'private',
        'TOP_LEVEL_VARIABLE:_enoent': 'private',
        'TOP_LEVEL_VARIABLE:_statScratchSize': 'private',
      },
  'package:apple_developer_kit/src/host/windows/adi/loader/internal/windows/linux_abi.dart':
      {
        'CLASS:LinuxArm64StatLayout': 'internal',
        'CLASS:LinuxOpenFlags': 'internal',
        'CLASS:LinuxStatLayout': 'internal',
        'CLASS:LinuxTimeval': 'internal',
        'CLASS:LinuxX64StatLayout': 'internal',
        'CLASS:WindowsOpenFlags': 'internal',
        'FUNCTION:linuxStatMode': 'internal',
        'FUNCTION:toWindowsPath': 'internal',
        'FUNCTION:windowsChmodMode': 'internal',
      },
  'package:apple_developer_kit/src/host/windows/adi/loader/internal/windows/windows_adi_abi.dart':
      {'CLASS:WindowsAdiAbi': 'internal'},
  'package:apple_developer_kit/src/host/windows/adi/loader/internal/windows/windows_arm64_code_preparation.dart':
      {'CLASS:WindowsArm64CodePreparation': 'internal'},
  'package:apple_developer_kit/src/host/windows/adi/loader/internal/windows/windows_crt.dart':
      {'CLASS:WindowsCrt': 'internal'},
  'package:apple_developer_kit/src/host/windows/adi/loader/internal/windows_loaded_library.dart':
      {'CLASS:WindowsLoadedLibrary': 'internal'},
  'package:apple_developer_kit/src/host/windows/adi/loader/loader_windows.dart':
      {'CLASS:WindowsNativeLibraryLoader': 'internal'},
  'package:apple_developer_kit/src/host/windows/windows_file_permissions.dart':
      {'CLASS:WindowsAppleFilePermissions': 'internal'},
  'package:apple_developer_kit/src/host/windows/windows_machine_identity.dart':
      {'CLASS:WindowsMachineIdentity': 'internal'},
  'package:apple_developer_kit/src/shared/adi/adi_architecture.dart': {
    'ENUM:AdiArchitecture': 'internal',
  },
  'package:apple_developer_kit/src/shared/adi/adi_bindings.dart': {
    'CLASS:AdiNativeBindings': 'internal',
    'TYPE_ALIAS:ADIDisposeDart': 'internal',
    'TYPE_ALIAS:ADIDisposeNative': 'internal',
    'TYPE_ALIAS:ADIGetLoginCodeDart': 'internal',
    'TYPE_ALIAS:ADIGetLoginCodeNative': 'internal',
    'TYPE_ALIAS:ADILoadLibraryWithPathDart': 'internal',
    'TYPE_ALIAS:ADILoadLibraryWithPathNative': 'internal',
    'TYPE_ALIAS:ADIOTPRequestDart': 'internal',
    'TYPE_ALIAS:ADIOTPRequestNative': 'internal',
    'TYPE_ALIAS:ADIProvisioningDestroyDart': 'internal',
    'TYPE_ALIAS:ADIProvisioningDestroyNative': 'internal',
    'TYPE_ALIAS:ADIProvisioningEndDart': 'internal',
    'TYPE_ALIAS:ADIProvisioningEndNative': 'internal',
    'TYPE_ALIAS:ADIProvisioningEraseDart': 'internal',
    'TYPE_ALIAS:ADIProvisioningEraseNative': 'internal',
    'TYPE_ALIAS:ADIProvisioningStartDart': 'internal',
    'TYPE_ALIAS:ADIProvisioningStartNative': 'internal',
    'TYPE_ALIAS:ADISetAndroidIDDart': 'internal',
    'TYPE_ALIAS:ADISetAndroidIDNative': 'internal',
    'TYPE_ALIAS:ADISetProvisioningPathDart': 'internal',
    'TYPE_ALIAS:ADISetProvisioningPathNative': 'internal',
    'TYPE_ALIAS:ADISynchronizeDart': 'internal',
    'TYPE_ALIAS:ADISynchronizeNative': 'internal',
  },
  'package:apple_developer_kit/src/shared/adi/elf/elf_reader.dart': {
    'CLASS:ElfDynamicSymbolTable': 'internal',
    'CLASS:ElfHashTable': 'internal',
    'CLASS:ElfReader': 'internal',
    'CLASS:ElfRelaTable': 'internal',
    'CLASS:ElfRelocationType': 'internal',
    'CLASS:ElfSectionType': 'internal',
    'CLASS:ElfSegmentFlags': 'internal',
    'CLASS:ElfSegmentType': 'internal',
    'CLASS:GnuHashTable': 'internal',
    'FUNCTION:_readCString': 'private',
  },
  'package:apple_developer_kit/src/shared/adi/elf/internal/elf_image.dart': {
    'CLASS:ElfImage': 'internal',
  },
  'package:apple_developer_kit/src/shared/adi/elf/internal/elf_page_range.dart':
      {'CLASS:ElfPageRange': 'internal'},
  'package:apple_developer_kit/src/shared/adi/elf/internal/elf_symbol_tables.dart':
      {'CLASS:ElfSymbolTables': 'internal'},
  'package:apple_developer_kit/src/shared/appstoreconnect/asc_csr.dart': {
    'CLASS:AscCsr': 'internal',
    'CLASS:AscGeneratedCsr': 'internal',
  },
  'package:apple_developer_kit/src/shared/appstoreconnect/asc_jwt.dart': {
    'CLASS:AscJwt': 'internal',
  },
  'package:apple_developer_kit/src/shared/appstoreconnect/asc_payloads.dart': {
    'CLASS:AscPayloads': 'internal',
  },
  'package:apple_developer_kit/src/shared/appstoreconnect/legacy_app_groups.dart':
      {
        'CLASS:LegacyAppGroups': 'internal',
        'TYPE_ALIAS:LegacyAuthHeaders': 'internal',
        'TYPE_ALIAS:LegacyTeamId': 'internal',
      },
  'package:apple_developer_kit/src/shared/config/config_dir.dart': {
    'FUNCTION:xcrossConfigDir': 'internal',
  },
  'package:apple_developer_kit/src/shared/grandslam/anisette/anisette_headers.dart':
      {
        'CLASS:AnisetteHeaders': 'internal',
        'TOP_LEVEL_VARIABLE:_defaultCountry': 'private',
        'TOP_LEVEL_VARIABLE:_defaultLocale': 'private',
        'TOP_LEVEL_VARIABLE:_defaultTimeZone': 'private',
        'TOP_LEVEL_VARIABLE:anisetteClientInfo': 'internal',
      },
  'package:apple_developer_kit/src/shared/grandslam/anisette/internal/real_adi_provisioning.dart':
      {'CLASS:RealAdiProvisioning': 'internal'},
  'package:apple_developer_kit/src/shared/grandslam/grandslam_operation.dart': {
    'CLASS:GrandSlamOperation': 'internal',
  },
  'package:apple_developer_kit/src/shared/grandslam/internal/grandslam_response_decoder.dart':
      {'CLASS:GrandSlamResponse': 'internal'},
  'package:apple_developer_kit/src/shared/grandslam/internal/srp_challenge.dart':
      {'CLASS:SrpChallenge': 'internal'},
  'package:apple_developer_kit/src/shared/grandslam/srp_client.dart': {
    'CLASS:SrpClient': 'internal',
    'TOP_LEVEL_VARIABLE:_g': 'private',
    'TOP_LEVEL_VARIABLE:_n': 'private',
    'TOP_LEVEL_VARIABLE:_nByteLength': 'private',
  },
  'package:apple_developer_kit/src/shared/secure/secure_file.dart': {
    'CLASS:SecureFile': 'internal',
  },
  'package:apple_developer_kit/src/shared/signing/bundle_inspector.dart': {
    'CLASS:BundleInspector': 'internal',
  },
  'package:apple_developer_kit/src/shared/signing/bundle_paths.dart': {
    'FUNCTION:bundleFail': 'internal',
    'FUNCTION:bundleRelativePath': 'internal',
    'FUNCTION:isWithinOrEqual': 'internal',
    'FUNCTION:pathKey': 'internal',
    'FUNCTION:samePath': 'internal',
  },
  'package:apple_developer_kit/src/shared/signing/bundle_tree.dart': {
    'CLASS:BundleTree': 'internal',
    'TOP_LEVEL_VARIABLE:_appExtensionSuffix': 'private',
    'TOP_LEVEL_VARIABLE:_forbiddenDirectoryNames': 'private',
    'TOP_LEVEL_VARIABLE:_machoMagics': 'private',
    'TOP_LEVEL_VARIABLE:_plugInsDirectory': 'private',
    'TOP_LEVEL_VARIABLE:_unsupportedBundleSuffixes': 'private',
    'TOP_LEVEL_VARIABLE:frameworkSuffix': 'internal',
  },
  'package:apple_developer_kit/src/shared/signing/bytes.dart': {
    'FUNCTION:compareBytes': 'internal',
    'FUNCTION:compareUtf8': 'internal',
  },
  'package:apple_developer_kit/src/shared/signing/code_resources.dart': {
    'CLASS:CodeResourcesBuilder': 'internal',
    'CLASS:SealCandidate': 'internal',
    'FUNCTION:_data': 'private',
    'FUNCTION:_isLocalization': 'private',
    'FUNCTION:_omitFromFiles': 'private',
    'FUNCTION:_omitFromFiles2': 'private',
    'FUNCTION:_rules': 'private',
    'FUNCTION:_rules2': 'private',
    'FUNCTION:sortedPlistMap': 'internal',
    'TOP_LEVEL_VARIABLE:codeResourcesPath': 'internal',
  },
  'package:apple_developer_kit/src/shared/signing/code_signature.dart': {
    'CLASS:CodeDirectoryField': 'internal',
    'CLASS:SignatureSlot': 'internal',
    'FUNCTION:_derInteger': 'private',
    'FUNCTION:_derValue': 'private',
    'FUNCTION:_normalizePlist': 'private',
    'FUNCTION:_padded': 'private',
    'FUNCTION:_paddedBytes': 'private',
    'FUNCTION:be32': 'internal',
    'FUNCTION:buildCodeDirectory': 'internal',
    'FUNCTION:buildDerEntitlements': 'internal',
    'FUNCTION:buildEntitlementsXml': 'internal',
    'FUNCTION:buildRequirements': 'internal',
    'FUNCTION:buildSuperblob': 'internal',
    'FUNCTION:csBlob': 'internal',
    'FUNCTION:entitlementsAllowUnsigned': 'internal',
    'FUNCTION:requireSigningString': 'internal',
    'FUNCTION:sha256Digest': 'internal',
    'FUNCTION:writeU32be': 'internal',
    'FUNCTION:writeU64be': 'internal',
    'TOP_LEVEL_VARIABLE:appleWwdrMarkerOid': 'internal',
    'TOP_LEVEL_VARIABLE:codeDirectoryVersion': 'internal',
    'TOP_LEVEL_VARIABLE:csBlobHeaderLength': 'internal',
    'TOP_LEVEL_VARIABLE:csBlobIndexLength': 'internal',
    'TOP_LEVEL_VARIABLE:csExecsegAllowUnsigned': 'internal',
    'TOP_LEVEL_VARIABLE:csExecsegMainBinary': 'internal',
    'TOP_LEVEL_VARIABLE:csHashTypeSha256': 'internal',
    'TOP_LEVEL_VARIABLE:csMagicBlobWrapper': 'internal',
    'TOP_LEVEL_VARIABLE:csMagicCodeDirectory': 'internal',
    'TOP_LEVEL_VARIABLE:csMagicEmbeddedDerEntitlements': 'internal',
    'TOP_LEVEL_VARIABLE:csMagicEmbeddedEntitlements': 'internal',
    'TOP_LEVEL_VARIABLE:csMagicEmbeddedSignature': 'internal',
    'TOP_LEVEL_VARIABLE:csMagicRequirement': 'internal',
    'TOP_LEVEL_VARIABLE:csMagicRequirements': 'internal',
    'TOP_LEVEL_VARIABLE:csPageSizeLog2': 'internal',
    'TOP_LEVEL_VARIABLE:csSha256Length': 'internal',
    'TOP_LEVEL_VARIABLE:csSuperBlobHeaderLength': 'internal',
    'TOP_LEVEL_VARIABLE:csslotCodeDirectory': 'internal',
    'TOP_LEVEL_VARIABLE:csslotDerEntitlements': 'internal',
    'TOP_LEVEL_VARIABLE:csslotEntitlements': 'internal',
    'TOP_LEVEL_VARIABLE:csslotRequirements': 'internal',
    'TOP_LEVEL_VARIABLE:csslotSignature': 'internal',
    'TOP_LEVEL_VARIABLE:designatedRequirementType': 'internal',
    'TOP_LEVEL_VARIABLE:requirementExprForm': 'internal',
  },
  'package:apple_developer_kit/src/shared/signing/der.dart': {
    'CLASS:Der': 'internal',
    'CLASS:DerReader': 'internal',
    'CLASS:DerTag': 'internal',
    'CLASS:DerValue': 'internal',
  },
  'package:apple_developer_kit/src/shared/signing/internal/bundle_entry.dart': {
    'CLASS:BundleEntry': 'internal',
  },
  'package:apple_developer_kit/src/shared/signing/internal/bundle_plan.dart': {
    'CLASS:BundlePlan': 'internal',
  },
  'package:apple_developer_kit/src/shared/signing/internal/loose_binary.dart': {
    'CLASS:LooseBinary': 'internal',
  },
  'package:apple_developer_kit/src/shared/signing/internal/macho_command_scan.dart':
      {'CLASS:MachOCommandScan': 'internal'},
  'package:apple_developer_kit/src/shared/signing/internal/macho_header.dart': {
    'CLASS:MachOHeader': 'internal',
  },
  'package:apple_developer_kit/src/shared/signing/internal/pem_block.dart': {
    'CLASS:PemBlock': 'internal',
  },
  'package:apple_developer_kit/src/shared/signing/internal/plist_der_entry.dart':
      {'CLASS:PlistDerEntry': 'internal'},
  'package:apple_developer_kit/src/shared/signing/internal/profile_identity.dart':
      {'CLASS:ProfileIdentity': 'internal'},
  'package:apple_developer_kit/src/shared/signing/internal/resolved_bundle.dart':
      {'CLASS:ResolvedBundle': 'internal'},
  'package:apple_developer_kit/src/shared/signing/internal/signature_inputs.dart':
      {'CLASS:SignatureInputs': 'internal'},
  'package:apple_developer_kit/src/shared/signing/macho_format.dart': {
    'CLASS:CodeSignatureCommand': 'internal',
    'CLASS:LoadCommand': 'internal',
    'CLASS:MachHeader64': 'internal',
    'CLASS:MachOLayout': 'internal',
    'CLASS:Section64': 'internal',
    'CLASS:SegmentCommand64': 'internal',
    'FUNCTION:alignUp': 'internal',
    'FUNCTION:checkedAdd': 'internal',
    'FUNCTION:checkedMultiply': 'internal',
    'FUNCTION:machoFail': 'internal',
    'FUNCTION:readFixedString': 'internal',
    'FUNCTION:readU32le': 'internal',
    'FUNCTION:readU64le': 'internal',
    'FUNCTION:requireRange': 'internal',
    'FUNCTION:writeU32le': 'internal',
    'FUNCTION:writeU64le': 'internal',
    'TOP_LEVEL_VARIABLE:cpuTypeArm64': 'internal',
    'TOP_LEVEL_VARIABLE:encryptionCryptIdOffset': 'internal',
    'TOP_LEVEL_VARIABLE:encryptionInfo64Size': 'internal',
    'TOP_LEVEL_VARIABLE:encryptionInfoSize': 'internal',
    'TOP_LEVEL_VARIABLE:fatCigam': 'internal',
    'TOP_LEVEL_VARIABLE:fatMagic': 'internal',
    'TOP_LEVEL_VARIABLE:lcCodeSignature': 'internal',
    'TOP_LEVEL_VARIABLE:lcEncryptionInfo': 'internal',
    'TOP_LEVEL_VARIABLE:lcEncryptionInfo64': 'internal',
    'TOP_LEVEL_VARIABLE:lcSegment': 'internal',
    'TOP_LEVEL_VARIABLE:lcSegment64': 'internal',
    'TOP_LEVEL_VARIABLE:linkeditSegmentName': 'internal',
    'TOP_LEVEL_VARIABLE:machoPageSize': 'internal',
    'TOP_LEVEL_VARIABLE:mhCigam': 'internal',
    'TOP_LEVEL_VARIABLE:mhCigam64': 'internal',
    'TOP_LEVEL_VARIABLE:mhExecute': 'internal',
    'TOP_LEVEL_VARIABLE:mhMagic': 'internal',
    'TOP_LEVEL_VARIABLE:mhMagic64': 'internal',
    'TOP_LEVEL_VARIABLE:nameFieldLength': 'internal',
    'TOP_LEVEL_VARIABLE:sGbZerofill': 'internal',
    'TOP_LEVEL_VARIABLE:sThreadLocalZerofill': 'internal',
    'TOP_LEVEL_VARIABLE:sZerofill': 'internal',
    'TOP_LEVEL_VARIABLE:signatureAlignment': 'internal',
    'TOP_LEVEL_VARIABLE:textSectionName': 'internal',
    'TOP_LEVEL_VARIABLE:textSegmentName': 'internal',
    'TOP_LEVEL_VARIABLE:uint32Max': 'internal',
  },
  'package:apple_developer_kit/src/shared/signing/macho_signer.dart': {
    'CLASS:MachOSigner': 'internal',
  },
  'package:apple_developer_kit/src/shared/signing/plist.dart': {
    'FUNCTION:decodePropertyList': 'internal',
    'TOP_LEVEL_VARIABLE:binaryPlistMagic': 'internal',
  },
  'package:apple_developer_kit/src/shared/signing/provisioning_profile.dart': {
    'CLASS:ProfileCms': 'internal',
    'FUNCTION:_readEncapsulatedPlist': 'private',
    'FUNCTION:_readTrailingFields': 'private',
    'FUNCTION:_validateCertificateShape': 'private',
    'FUNCTION:developerCertificates': 'internal',
    'FUNCTION:parsePlist': 'internal',
    'FUNCTION:parseProfileCms': 'internal',
    'FUNCTION:requiredDate': 'internal',
    'FUNCTION:requiredFirstString': 'internal',
    'FUNCTION:requiredMap': 'internal',
  },
  'package:apple_developer_kit/src/shared/signing/x509.dart': {
    'CLASS:Oid': 'internal',
    'CLASS:ParsedCertificate': 'internal',
    'FUNCTION:_decodePem': 'private',
    'FUNCTION:_parseCertificate': 'private',
    'FUNCTION:_parseRsaPublicKey': 'private',
    'FUNCTION:_withCertificateMetadata': 'private',
    'FUNCTION:buildCertificateChain': 'internal',
    'FUNCTION:bytesEqual': 'internal',
    'FUNCTION:checkValidity': 'internal',
    'FUNCTION:parseCertificatePem': 'internal',
    'FUNCTION:parseChainCertificate': 'internal',
    'FUNCTION:parsePrivateKey': 'internal',
    'TOP_LEVEL_VARIABLE:_embeddedAppleCertificateBase64': 'private',
    'TOP_LEVEL_VARIABLE:_notBeforeSkew': 'private',
  },
  'package:apple_developer_kit/src/shared/adi/adi_client.dart': {
    'CLASS:AdiClient': 'internal',
    'CLASS:AdiSynchronizationResult': 'internal',
  },
  'package:apple_developer_kit/src/shared/grandslam/grandslam_two_factor.dart':
      {
        'CLASS:GrandSlamTwoFactor': 'internal',
        'TOP_LEVEL_VARIABLE:_incorrectCodeErrorCode': 'private',
        'TOP_LEVEL_VARIABLE:_smsPhoneNumberId': 'private',
        'TOP_LEVEL_VARIABLE:_smsPutUrl': 'private',
        'TOP_LEVEL_VARIABLE:_smsValidateUrl': 'private',
        'TOP_LEVEL_VARIABLE:_xcodeVersion': 'private',
      },
  'package:apple_developer_kit/src/shared/http/apple_http_client.dart': {
    'CLASS:AppleHttp': 'internal',
  },
  'package:apple_developer_kit/src/shared/secure/local_cipher.dart': {
    'ENUM:LocalCipherBinding': 'internal',
  },
};
