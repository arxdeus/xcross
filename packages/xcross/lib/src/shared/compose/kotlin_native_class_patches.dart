import 'dart:typed_data';
import 'package:xcross/src/shared/compose/kotlin_class_file.dart';

const int _iconst1 = 0x04;
const int _aload0 = 0x2a;
const int _invokeSpecial = 0xb7;
const int _invokeVirtual = 0xb6;
const int _ireturn = 0xac;
const int _areturn = 0xb0;
const int _return = 0xb1;

Uint8List patchHostManagerClassBytes(Uint8List classBytes) {
  final cf = KotlinClassFile.parse(classBytes);
  final gtvIdx = cf.findMethodrefIdx(
    'org/jetbrains/kotlin/konan/target/HostManager',
    'getTargetValues',
    '()Ljava/util/List;',
  );
  if (gtvIdx == null) {
    throw StateError(
      'HostManagerPatcher: getTargetValues Methodref not in constant pool',
    );
  }
  cf.replaceMethodCode(
    'isEnabled',
    '(Lorg/jetbrains/kotlin/konan/target/KonanTarget;)Z',
    Uint8List.fromList([_iconst1, _ireturn]),
  );
  cf.replaceMethodCode(
    'getEnabled',
    '()Ljava/util/List;',
    Uint8List.fromList([
      _aload0,
      _invokeVirtual,
      (gtvIdx >> 8) & 0xFF,
      gtvIdx & 0xFF,
      _areturn,
    ]),
  );
  return cf.serialize();
}

/// Patches raw [objcExportClassEntry] bytes by replacing every method whose
/// name contains `generateWorkaroundForSwiftSR10177` and whose descriptor
/// ends with `)V` with a single `return` instruction.
///
/// Returns `null` when no matching method is found (non-fatal: the class may
/// not be present in older Kotlin/Native distributions).
Uint8List? patchObjCExportClassBytes(Uint8List classBytes) {
  final cf = KotlinClassFile.parse(classBytes);
  var patched = false;
  for (final m in cf.methods) {
    final name = cf.utf8At(m.nameIdx);
    if (!name.contains('generateWorkaroundForSwiftSR10177')) continue;
    final descriptor = cf.utf8At(m.descIdx);
    if (!descriptor.endsWith(')V')) {
      // Non-void variant — unexpected; leave untouched.
      continue;
    }
    cf.replaceMethodCode(name, descriptor, Uint8List.fromList([_return]));
    patched = true;
  }
  return patched ? cf.serialize() : null;
}

/// Patches raw [appleConfigurablesImplClassEntry] bytes by rewriting
/// `getDependencies()Ljava/util/List;` to `return super.getDependencies();`.
///
/// `KONAN_USE_INTERNAL_SERVER=1` (required for cross-host compilation with
/// no local Xcode) forces `AppleConfigurablesImpl.getDependencies()` to
/// append the literal `targetSysRoot`/`targetToolchain`/`additionalToolsDir`
/// override VALUES to the dependency list as downloadable dependency names.
/// `DependencyProcessor` then fetches `<basename>.tar.gz` from JetBrains'
/// server for each, which 404s because those basenames are xcross's local
/// SDK shim paths, not real hosted artifacts. The actual absolute-path
/// resolution used during linking (`getAbsoluteTargetSysRoot` etc.) already
/// special-cases absolute paths via `DependencyProcessor.resolve` and does
/// not need this eager prefetch list, so it is safe to drop it.
///
/// Earlier this method's whole body was replaced with `return emptyList()`,
/// which *also* discarded the `super.getDependencies()` call it starts
/// with. That base-class call is what declares the compiler's own LLVM
/// toolchain dependency (`KonanPropertiesLoader.getDependencies()` ==
/// `hostTargetList("dependencies") + compilerDependencies()`, and
/// `compilerDependencies()` resolves `llvmHome.<host>`'s predefined
/// distribution name, e.g. `llvm-21-x86_64-linux-essentials-116` on the
/// real Linux Kotlin/Native 2.4.0 distribution, whose `konan.properties`
/// sets `llvmHome.linux_x64 = $llvm.linux_x64.user`). With that call
/// removed, `DependencyProcessor` never learns this package exists, so any
/// later resolution of `absoluteLlvmHome` (needed while compiling for
/// `ios_arm64`, since `AppleConfigurablesImpl.absoluteTargetToolchain` etc.
/// all route through the shared `DependencyProcessor`) throws
/// `IllegalStateException: llvm-21-x86_64-linux-essentials-116 not declared
/// as dependency` (confirmed against exact-head CI run 31659757134, and by
/// diffing the real Linux/Windows Kotlin/Native 2.4.0 `konan.properties`
/// against the local macOS one, where `llvmHome.linux_x64`/`llvmHome.
/// mingw_x64` default to the `.user` (essentials) variant instead of
/// `.dev`). Keeping `super.getDependencies()` and only dropping the
/// InternalServer-only sdk/toolchain/xcodeAddon addition fixes this while
/// still avoiding the 404s from `6be03f2`.
///
/// Returns `null` when the method is not found (non-fatal: the class may not
/// be present, or its shape may differ, in other Kotlin/Native versions).
Uint8List? patchAppleConfigurablesImplClassBytes(Uint8List classBytes) {
  final cf = KotlinClassFile.parse(classBytes);
  const name = 'getDependencies';
  const descriptor = '()Ljava/util/List;';
  if (cf.findMethod(name, descriptor) == null) return null;

  final superName = cf.superClassName;
  if (superName == null) {
    throw StateError(
      'HostManagerPatcher: AppleConfigurablesImpl has no resolvable '
      'superclass',
    );
  }
  final superGetDependenciesIdx = cf.findMethodrefIdx(
    superName,
    'getDependencies',
    descriptor,
  );
  if (superGetDependenciesIdx == null) {
    throw StateError(
      'HostManagerPatcher: $superName.getDependencies Methodref not in '
      'constant pool',
    );
  }
  cf.replaceMethodCode(
    name,
    descriptor,
    Uint8List.fromList([
      _aload0,
      _invokeSpecial,
      (superGetDependenciesIdx >> 8) & 0xFF,
      superGetDependenciesIdx & 0xFF,
      _areturn,
    ]),
  );
  return cf.serialize();
}

// ── Public JAR-level entry point ──────────────────────────────────────────────

/// Patches [hostManagerClassEntry] (and optionally [objcExportClassEntry] and
/// [appleConfigurablesImplClassEntry]) inside [jarPath] in place so a
/// `linux_x64` host enables all Apple targets.
///
/// Idempotent: if [jarMarkerPath] is already present the function returns
/// `false` without touching the JAR.  Also returns `false` when neither
/// patchable class is found in the JAR.
///
/// Returns `true` after a successful patch and writes [jarMarkerPath] into
/// the JAR.
