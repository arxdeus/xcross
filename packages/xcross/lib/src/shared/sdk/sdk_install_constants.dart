import 'dart:convert';

/// The iOS subset required by Swift's Linux cross-SDK protocol.
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
const sdkIncludedFiles = <String>[
  'Developer/Platforms/iPhoneOS.platform/Info.plist',
  'Developer/Platforms/iPhoneSimulator.platform/Info.plist',
  'Developer/Toolchains/XcodeDefault.xctoolchain/Info.plist',
];

const sdkToolchainRelativePath =
    'Developer/Toolchains/XcodeDefault.xctoolchain';
const sdkSwiftResourcesRelativePath = '$sdkToolchainRelativePath/usr/lib/swift';
const sdkSwiftStaticResourcesRelativePath =
    '$sdkToolchainRelativePath/usr/lib/swift_static';

/// POSIX `st_mode` bits carried by every cpio entry.
const sdkFileTypeMask = 0xF000;
const sdkDirectoryFileType = 0x4000;
const sdkRegularFileType = 0x8000;
const sdkSymbolicLinkFileType = 0xA000;
const sdkAnyExecuteBit = 0x049; // u+x | g+x | o+x

const sdkJsonEncoder = JsonEncoder.withIndent('  ');

/// Records which host Swift toolchain the installed bundle was patched
/// against. The bundle's `swift/clang/include` headers and its Swift
/// resources are only valid for that one toolchain's module ABI: building
/// with a different `swift` fails with "this SDK is not supported by the
/// compiler ... Please select a toolchain which matches the SDK."
const hostToolchainStampName = 'xcross-host-toolchain.json';

/// Windows reports "a DLL this executable needs is missing" as a bare exit
/// code, with no output on either stream.
const sdkStatusDllNotFound = 0xC0000135;

/// The compiler-mismatch diagnostic Swift emits when the bundle was patched
/// against a different toolchain than the one now building.
const swiftSdkMismatchMarker = 'this SDK is not supported by the compiler';

String sdkFirstToolchainLine(String value) => value.split('\n').first.trim();
