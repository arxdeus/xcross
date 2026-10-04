import 'dart:convert';
import 'package:meta/meta.dart';

/// The iOS subset required by Swift's Linux cross-SDK protocol.
@internal
const sdkIncludedRoots = <String>[
  'Developer/Platforms/iPhoneOS.platform/Developer/SDKs',
  'Developer/Platforms/iPhoneOS.platform/Developer/Library/Frameworks',
  'Developer/Platforms/iPhoneOS.platform/Developer/Library/PrivateFrameworks',
  'Developer/Platforms/iPhoneOS.platform/Developer/usr/lib',
  'Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs',
  'Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks',
  'Developer/Platforms/iPhoneSimulator.platform/Developer/Library/PrivateFrameworks',
  'Developer/Platforms/iPhoneSimulator.platform/Developer/usr/lib',
  'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift',
  'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift_static',
  'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang',
  'Developer/Toolchains/XcodeDefault.xctoolchain/usr/include',
];

/// Swift's platform registry needs the descriptors of the imported platform
/// and toolchain as well as their SDK and library subtrees.
@internal
const sdkIncludedFiles = <String>[
  'Developer/Platforms/iPhoneOS.platform/Info.plist',
  'Developer/Platforms/iPhoneSimulator.platform/Info.plist',
  'Developer/Toolchains/XcodeDefault.xctoolchain/Info.plist',
];

@internal
const sdkToolchainRelativePath =
    'Developer/Toolchains/XcodeDefault.xctoolchain';
@internal
const sdkSwiftResourcesRelativePath = '$sdkToolchainRelativePath/usr/lib/swift';
@internal
const sdkSwiftStaticResourcesRelativePath =
    '$sdkToolchainRelativePath/usr/lib/swift_static';

/// POSIX `st_mode` bits carried by every cpio entry.
@internal
const sdkFileTypeMask = 0xF000;
@internal
const sdkDirectoryFileType = 0x4000;
@internal
const sdkRegularFileType = 0x8000;
@internal
const sdkSymbolicLinkFileType = 0xA000;
@internal
const sdkAnyExecuteBit = 0x049; // u+x | g+x | o+x

@internal
const sdkJsonEncoder = JsonEncoder.withIndent('  ');

/// Records which host Swift toolchain the installed bundle was patched
/// against. The bundle's `swift/clang/include` headers and its Swift
/// resources are only valid for that one toolchain's module ABI: building
/// with a different `swift` fails with "this SDK is not supported by the
/// compiler ... Please select a toolchain which matches the SDK."
@internal
const hostToolchainStampName = 'xcross-host-toolchain.json';

/// Windows reports "a DLL this executable needs is missing" as a bare exit
/// code, with no output on either stream.
@internal
const sdkStatusDllNotFound = 0xC0000135;

/// The compiler-mismatch diagnostic Swift emits when the bundle was patched
/// against a different toolchain than the one now building.
@internal
const swiftSdkMismatchMarker = 'this SDK is not supported by the compiler';

@internal
String sdkFirstToolchainLine(String value) => value.split('\n').first.trim();
