#!/usr/bin/env bash
# =============================================================================
# xcross Compose Build Spike — de-risk experiment
# =============================================================================
# Proves or disproves three unknowns for the xcross compose redesign:
#
#   U-XCOMPILE-FLAG  Can `./gradlew :shared:compileKotlinIosArm64
#                    -Pkotlin.native.enableKlibsCrossCompilation=true` produce a
#                    klib on Linux for a Compose UI project?
#
#   U-DEPS-ENUM      Can a Gradle init-script enumerate the iosArm64 main
#                    compilation's transitive dependency klib absolute paths?
#
#   U-XINCLUDE       Can konanc link a framework from that klib via
#                    `-Xinclude <shared.klib> -library <dep.klib>...`, and does
#                    the resulting Shared.h export MainViewControllerKt?
#
# Required env:
#   JAVA_HOME          — JDK 21 home
#   XCROSS_LD64LLD     — x86_64 ld64.lld path (set by setup-compose-toolchain)
#   LX_KN              — K/N linux-x86_64 root (2.4.0)
#   KONAN_DATA_DIR     — ~/.konan
#   GITHUB_WORKSPACE   — repo root (for dart run + package:xcross)
#
# HostManager gate nuance (read before interpreting results):
#   konanc's HostManager.isEnabled() hard-codes "no Apple targets on Linux".
#   This is a JVM bytecode check — it is NOT bypassed by -Xoverride-konan-
#   properties or any Gradle flag. The jar patch (Stage 1 of ComposePacker)
#   rewrites HostManager.class and ObjCExportKt.class inside
#   kotlin-native-compiler-embeddable.jar to return `true` for all targets.
#   This script applies the SAME patch by invoking xcross's own
#   patchKotlinNativeJar() function via a tiny Dart helper, so the result is
#   byte-for-byte identical to what ComposePacker would produce.
#   If the jar patch fails (e.g. package resolution issues), the script falls
#   back to running konanc un-patched, captures the exact HostManager error,
#   and marks the unknowns accordingly. That outcome is itself a valid finding.
# =============================================================================
set -euxo pipefail

# ── Colour-free PASS/FAIL banners (CI-safe) ──────────────────────────────────
PASS="PASS"
FAIL="FAIL"
XCOMPILE_RESULT="$FAIL"
DEPS_COUNT=0
DEPS_RESULT="$FAIL"
XINCLUDE_LINK_RESULT="$FAIL"
XINCLUDE_ENTRY_RESULT="$FAIL"

WORKSPACE="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set}"
JAVA_HOME="${JAVA_HOME:?JAVA_HOME must be set}"
XCROSS_LD64LLD="${XCROSS_LD64LLD:?XCROSS_LD64LLD must be set}"
LX_KN="${LX_KN:?LX_KN must be set}"
KONAN_DATA_DIR="${KONAN_DATA_DIR:-$HOME/.konan}"
# Module name within the KMP project that contains the iosArm64 target.
MODULE="${MODULE:-shared}"

# ── Resolve Darwin SDK paths ──────────────────────────────────────────────────
DARWIN_SDK="$HOME/.swiftpm/swift-sdks/darwin.artifactbundle"
IPHONE_SDK=""
for _sdk in "$DARWIN_SDK"/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS*.sdk; do
  if [[ -d "$_sdk" ]]; then
    IPHONE_SDK="$_sdk"
    break
  fi
done

echo ""
echo "===== SPIKE CONFIG ====="
echo "WORKSPACE:        $WORKSPACE"
echo "JAVA_HOME:        $JAVA_HOME"
echo "XCROSS_LD64LLD:   $XCROSS_LD64LLD"
echo "LX_KN:            $LX_KN"
echo "KONAN_DATA_DIR:   $KONAN_DATA_DIR"
echo "DARWIN_SDK:       $DARWIN_SDK"
echo "IPHONE_SDK:       ${IPHONE_SDK:-NOT FOUND — U-XINCLUDE will fail}"
echo "========================"

# ── A. Copy example_kmp to writable temp dir ─────────────────────────────────
echo ""
echo "===== SETUP A: Copy examples/example_kmp ====="
KMP_DIR=/tmp/kmp_spike
rm -rf "$KMP_DIR"
cp -r "$WORKSPACE/examples/example_kmp" "$KMP_DIR"
# Ensure gradlew is executable (git may strip +x on some runners).
chmod +x "$KMP_DIR/gradlew"
echo "Copied to $KMP_DIR"
ls -la "$KMP_DIR/"

# ── PREREQUISITE: HostManager jar patch ──────────────────────────────────────
#
# ComposePacker Stage 1 calls patchKotlinNativeJar() from Dart. We replicate
# that exactly by writing a tiny Dart entrypoint that imports package:xcross
# and invoking it via `dart run` from the workspace (which has the package
# config from `dart pub get`). This is byte-for-byte identical to Stage 1.
#
# If dart run fails (e.g. network/path issue), we log the error and continue
# with un-patched jars. konanc will then hit the HostManager gate and the
# exact error message (typically "target ios_arm64 is not available") becomes
# the finding — still valuable.
#
echo ""
echo "===== PREREQUISITE: HostManager + ObjCExportKt jar patch ====="

JAR_PATCHED=false
JAR_PATH=""
JAR_PATH="$(find "$LX_KN" -name 'kotlin-native-compiler-embeddable.jar' -print -quit 2>/dev/null || true)"

if [[ -z "$JAR_PATH" ]]; then
  echo "WARNING: kotlin-native-compiler-embeddable.jar not found under $LX_KN"
  echo "  konanc may hit the HostManager gate. Continuing to capture the error."
else
  echo "Found jar: $JAR_PATH"

  # Write the Dart patcher helper into the workspace bin dir (resolved by dart
  # run via the workspace package_config.json from dart pub get).
  PATCH_HELPER="$WORKSPACE/bin/spike_patch_jar.dart"
  cat > "$PATCH_HELPER" << 'DART_EOF'
// Spike helper: apply xcross HostManager + ObjCExportKt jar patch.
// Created at runtime by scripts/compose-spike.sh — not committed.
import 'package:xcross/src/build/host_manager_patcher.dart';
void main(List<String> args) {
  if (args.isEmpty) {
    print('Usage: spike_patch_jar.dart <path/to/kotlin-native-compiler-embeddable.jar>');
    return;
  }
  final jarPath = args[0];
  final result = patchKotlinNativeJar(jarPath);
  if (result) {
    print('PATCH_APPLIED: $jarPath');
  } else {
    print('PATCH_SKIPPED (already patched or no patchable classes): $jarPath');
  }
}
DART_EOF

  echo "Running Dart jar patcher..."
  PATCH_OUT=""
  if PATCH_OUT=$(cd "$WORKSPACE" && dart run bin/spike_patch_jar.dart "$JAR_PATH" 2>&1); then
    echo "Jar patch result: $PATCH_OUT"
    JAR_PATCHED=true
  else
    echo "WARNING: Dart jar patcher failed:"
    echo "$PATCH_OUT"
    echo "  Proceeding with un-patched jar. konanc HostManager error will be the finding."
  fi

  # Clean up the helper (don't leave runtime files in workspace).
  rm -f "$PATCH_HELPER"
fi

echo "JAR_PATCHED=$JAR_PATCHED"

# ── PREREQUISITE: ld wrapper + Apple shims + konan.properties ────────────────
#
# Mirrors ComposePacker Stage 3 (ld wrapper) + Stage 4 (Apple shims) +
# Stage 5 (konan.properties POC_PATCH + runtime sysroot).
# Required for U-XINCLUDE where konanc drives the final link and probes xcrun.
#
echo ""
echo "===== PREREQUISITE: ld wrapper + Apple shims + konan.properties ====="

SPIKE_UNI=/tmp/spike-uni
mkdir -p "$SPIKE_UNI/usr/bin"

# ld wrapper: konanc spawns `linker.linux_x64-ios_arm64` from konan.properties.
# We point it at XCROSS_LD64LLD (stock LLVM x86_64 ld64.lld) — same as Stage 3.
# Expand XCROSS_LD64LLD at write time (not at call time) so the script is self-contained.
cat > "$SPIKE_UNI/usr/bin/ld" << LDEOF
#!/bin/bash
exec "${XCROSS_LD64LLD}" "\$@"
LDEOF
chmod +x "$SPIKE_UNI/usr/bin/ld"
echo "ld wrapper: $SPIKE_UNI/usr/bin/ld → $XCROSS_LD64LLD"

# Apple shims — konanc calls these during framework link (mirrors Stage 4).
sudo mkdir -p /usr/libexec

# PlistBuddy shim: returns a mock Xcode version string.
{
  echo '#!/bin/bash'
  echo 'echo "16.0"'
  echo 'exit 0'
} | sudo tee /usr/libexec/PlistBuddy > /dev/null
sudo chmod +x /usr/libexec/PlistBuddy

# xcode-select shim: returns the Darwin SDK Developer dir.
{
  echo "#!/bin/bash"
  echo "printf '%s/Developer\n' '${DARWIN_SDK}'"
  echo "exit 0"
} | sudo tee /usr/local/bin/xcode-select > /dev/null
sudo chmod +x /usr/local/bin/xcode-select
echo "xcode-select shim installed (→ $DARWIN_SDK/Developer)"

# xcrun shim: dispatch table for tools konanc probes (mirrors Stage 4).
{
  echo '#!/bin/bash'
  echo 'echo "[xcrun-shim] $*" >> /tmp/xcrun-spike.log'
  echo 'case "$*" in'
  echo '  "xcodebuild -version"|"-version") echo "Xcode 16.0"; echo "Build version 16A242d" ;;'
  echo '  "-f ld"|"--find ld") echo '"$SPIKE_UNI"'/usr/bin/ld ;;'
  echo '  "-f clang"|"--find clang") echo /usr/bin/clang ;;'
  echo '  "-f clang++"|"--find clang++") echo /usr/bin/clang++ ;;'
  echo '  "-f strip"|"--find strip") echo /usr/bin/strip ;;'
  echo '  "-f ar"|"--find ar") echo /usr/bin/ar ;;'
  echo '  "-f nm"|"--find nm") echo /usr/bin/nm ;;'
  echo '  "-f dsymutil"|"--find dsymutil") echo '"$DARWIN_SDK"'/toolset/bin/dsymutil ;;'
  echo "  \"--sdk iphoneos --show-sdk-path\") echo '${IPHONE_SDK}' ;;"
  echo "  \"--sdk macosx --show-sdk-path\") echo '${IPHONE_SDK}' ;;"
  echo '  "simctl list runtimes -j") echo "{}" ;;'
  echo '  *) echo /usr/bin/false ;;'
  echo 'esac'
  echo 'exit 0'
} | sudo tee /usr/local/bin/xcrun > /dev/null
sudo chmod +x /usr/local/bin/xcrun
echo "xcrun shim installed"

# konan.properties patch — mirrors Stage 5 (POC_PATCH + runtime sysroot).
# Last-wins append: the SPIKE_PATCH block sets all the stubs, then the
# RUNTIME_PATCH line immediately after overrides targetSysRoot with the real SDK.
KONAN_PROPS="$LX_KN/konan/konan.properties"
if [[ -f "$KONAN_PROPS" ]]; then
  if ! grep -q 'SPIKE_PATCH' "$KONAN_PROPS"; then
    cat >> "$KONAN_PROPS" << PROPS

# SPIKE_PATCH — xcross compose spike: linux_x64 → ios_arm64 cross-build stubs.
# Mirrors ComposePacker Stage 5 (POC_PATCH block + runtime sysroot).
targetSysRoot.ios_arm64 = ${SPIKE_UNI}/usr
targetToolchain.linux_x64-ios_arm64 = ${SPIKE_UNI}/usr
additionalToolsDir.ios_arm64 = ${SPIKE_UNI}/usr
linker.linux_x64-ios_arm64 = ${SPIKE_UNI}/usr/bin/ld
# RUNTIME_PATCH — overrides stub sysroot with real iPhoneOS SDK (last-wins):
targetSysRoot.ios_arm64 = ${IPHONE_SDK}
PROPS
    echo "konan.properties: SPIKE_PATCH appended"
  else
    echo "konan.properties: SPIKE_PATCH already present"
  fi
else
  echo "WARNING: konan.properties not found at $KONAN_PROPS — U-XINCLUDE may fail to link"
fi

# ── U-XCOMPILE-FLAG ──────────────────────────────────────────────────────────
echo ""
echo "===== U-XCOMPILE-FLAG: gradle iosArm64 klib with cross-compile flag ====="
echo "Testing: ./gradlew :shared:compileKotlinIosArm64"
echo "         -Pkotlin.native.enableKlibsCrossCompilation=true --no-daemon"
echo ""
echo "NOTE: This test requires the HostManager jar patch (JAR_PATCHED=$JAR_PATCHED)."
echo "      Without the patch, konanc rejects ios_arm64 on Linux with:"
echo "      'target ios_arm64 is not available on the current host'"
echo "      The error below (if any) IS the finding for this unknown."
echo ""

KLIB_PATH=""
XCOMPILE_EXIT=0
(
  cd "$KMP_DIR"
  ./gradlew :shared:compileKotlinIosArm64 \
    -Pkotlin.native.enableKlibsCrossCompilation=true \
    --no-daemon \
    --stacktrace \
    2>&1
) || XCOMPILE_EXIT=$?

if [[ $XCOMPILE_EXIT -ne 0 ]]; then
  echo ""
  echo "===== U-XCOMPILE-FLAG: gradle exited with code $XCOMPILE_EXIT ====="
  echo "Finding: gradle :shared:compileKotlinIosArm64 FAILED"
  echo "  → Check whether the HostManager patch was applied (JAR_PATCHED=$JAR_PATCHED)"
  echo "  → Check stacktrace above for the root cause"
  XCOMPILE_RESULT="$FAIL (gradle exit=$XCOMPILE_EXIT; JAR_PATCHED=$JAR_PATCHED)"
else
  # KGP 2.x places the compiled klib at this canonical unpacked-dir path.
  # (It is a directory, not a *.klib file — verified against a real 2.4.0 build.)
  KLIB_PATH="$KMP_DIR/$MODULE/build/classes/kotlin/iosArm64/main/klib/$MODULE"
  if [[ ! -e "$KLIB_PATH" ]]; then
    echo "WARNING: gradle exited 0 but klib dir not found at expected path:"
    echo "  $KLIB_PATH"
    echo "Actual build dirs (maxdepth 6):"
    find "$KMP_DIR/$MODULE/build" -maxdepth 6 -type d 2>/dev/null | head -40 || true
    XCOMPILE_RESULT="$FAIL (gradle exit=0 but klib not found at expected path)"
    KLIB_PATH=""
  else
    echo "Found klib: $KLIB_PATH"
    XCOMPILE_RESULT="$PASS (klib=$KLIB_PATH)"
  fi
fi
echo "===== U-XCOMPILE-FLAG: $XCOMPILE_RESULT ====="

# ── U-DEPS-ENUM ──────────────────────────────────────────────────────────────
echo ""
echo "===== U-DEPS-ENUM: enumerate iosArm64 main compilation transitive klib deps ====="

# Write the init script via reflection — PROVEN WORKING approach.
# Typed KGP classes (KotlinMultiplatformExtension, compileDependencyFiles) are
# NOT available on init-script classpath; reflection-based access is required.
# Scoped to $MODULE to avoid registering duplicate tasks on sibling subprojects.
# doLast is lazy: `compileDependencyFiles` is resolved after task graph is ready.
cat << 'INIT_EOF' | sed "s/MODULE_NAME/${MODULE}/g" > /tmp/spike-enum.init.gradle.kts
// spike-enum.init.gradle.kts — generated by compose-spike.sh
// Uses REFLECTION to access KGP types — typed imports unavailable in init scripts.
allprojects {
    if (name != "MODULE_NAME") return@allprojects
    tasks.register("dumpIosDeps") {
        dependsOn("compileKotlinIosArm64")
        doLast {
            val kotlinExt = project.extensions.findByName("kotlin")
                ?: error("[spike] no 'kotlin' extension on project '$name'")
            val targets = kotlinExt.javaClass.getMethod("getTargets").invoke(kotlinExt)
            val findByName = targets.javaClass.methods.first { it.name == "findByName" }
            val target = findByName.invoke(targets, "iosArm64")
                ?: error("[spike] no iosArm64 target in project '$name'")
            val compilations = target.javaClass.getMethod("getCompilations").invoke(target)
            val getByName = compilations.javaClass.methods
                .first { it.name == "getByName" && it.parameterCount == 1 }
            val main = getByName.invoke(compilations, "main")
            val cdf = main.javaClass.methods
                .first { it.name == "getCompileDependencyFiles" }.invoke(main)
            @Suppress("UNCHECKED_CAST")
            val files = cdf.javaClass.getMethod("getFiles").invoke(cdf) as Set<java.io.File>
            val out = java.io.File("/tmp/deps.txt")
            out.writeText(files.joinToString("\n") { it.absolutePath })
            println("[spike:dumpIosDeps] wrote ${files.size} entries to ${out.absolutePath}")
        }
    }
}
INIT_EOF

echo "Init script written to /tmp/spike-enum.init.gradle.kts"
echo ""

DEPS_ENUM_EXIT=0
(
  cd "$KMP_DIR"
  ./gradlew ":$MODULE:dumpIosDeps" \
    --init-script /tmp/spike-enum.init.gradle.kts \
    --no-daemon \
    --no-configuration-cache \
    --console=plain \
    --stacktrace \
    2>&1
) || DEPS_ENUM_EXIT=$?

if [[ $DEPS_ENUM_EXIT -ne 0 ]]; then
  echo ""
  echo "===== U-DEPS-ENUM: gradle exited with code $DEPS_ENUM_EXIT ====="
  DEPS_RESULT="$FAIL (gradle exit=$DEPS_ENUM_EXIT)"
else
  if [[ -f /tmp/deps.txt ]] && grep -q '\.klib' /tmp/deps.txt 2>/dev/null; then
    DEPS_COUNT=$(grep -c '\.klib' /tmp/deps.txt 2>/dev/null || echo 0)
    echo "deps.txt contents ($DEPS_COUNT klib paths):"
    cat /tmp/deps.txt
    DEPS_RESULT="$PASS ($DEPS_COUNT klib paths)"
  else
    echo "WARNING: /tmp/deps.txt not created or contains no .klib paths"
    if [[ -f /tmp/deps.txt ]]; then
      echo "deps.txt (no klib lines):"
      cat /tmp/deps.txt || true
    fi
    DEPS_RESULT="$FAIL (no klib paths in deps.txt)"
  fi
fi
echo "===== U-DEPS-ENUM: $DEPS_RESULT ====="

# ── U-XINCLUDE ───────────────────────────────────────────────────────────────
echo ""
echo "===== U-XINCLUDE: konanc -Xinclude=<shared.klib> -library <deps> → Shared.framework ====="

if [[ -z "$IPHONE_SDK" ]]; then
  echo "SKIP: IPHONE_SDK not resolved — Darwin SDK missing or info.json not found."
  XINCLUDE_LINK_RESULT="$FAIL (IPHONE_SDK not resolved)"
  XINCLUDE_ENTRY_RESULT="$FAIL (IPHONE_SDK not resolved)"
elif [[ -z "$KLIB_PATH" ]]; then
  echo "SKIP: shared klib not found (U-XCOMPILE-FLAG failed)."
  XINCLUDE_LINK_RESULT="$FAIL (no shared klib from U-XCOMPILE-FLAG)"
  XINCLUDE_ENTRY_RESULT="$FAIL (no shared klib from U-XCOMPILE-FLAG)"
elif [[ "$DEPS_RESULT" == "$FAIL"* ]]; then
  echo "SKIP: dep list not available (U-DEPS-ENUM failed)."
  XINCLUDE_LINK_RESULT="$FAIL (no dep list from U-DEPS-ENUM)"
  XINCLUDE_ENTRY_RESULT="$FAIL (no dep list from U-DEPS-ENUM)"
else
  echo "KLIB_PATH: $KLIB_PATH"
  echo "IPHONE_SDK: $IPHONE_SDK"
  echo "Deps to pass as -library:"
  cat /tmp/deps.txt || true
  echo ""

  mkdir -p /tmp/out

  # Build -library args: only *.klib entries that exist on disk.
  # (deps.txt may also contain jar/class paths — konanc only accepts klibs here.)
  LIBARGS=()
  while IFS= read -r f; do
    case "$f" in
      *.klib)
        if [[ -e "$f" ]]; then
          LIBARGS+=(-library "$f")
        else
          echo "WARNING: klib path not on disk, skipping: $f"
        fi
        ;;
    esac
  done < /tmp/deps.txt

  echo "Library args count: ${#LIBARGS[@]}"
  echo ""
  echo "Running konanc -Xinclude ..."
  echo ""

  # NOTE ON HOST MANAGER:
  # -Xoverride-konan-properties does NOT bypass HostManager.isEnabled —
  # that is a JVM bytecode check inside kotlin-native-compiler-embeddable.jar.
  # The jar patch applied above (patchKotlinNativeJar) is the ONLY bypass.
  # If the patch was not applied (JAR_PATCHED=false), konanc will emit:
  #   "error: target ios_arm64 is not available on the current host"
  # That exact error IS the finding — it confirms the jar patch is mandatory.

  KONANC_BIN="$LX_KN/bin/konanc"
  KONANC_EXIT=0
  # -Xoverride-konan-properties supplies the sysroot, linker, and toolchain
  # directly so no konan.properties file patch is needed for these three keys.
  # The HostManager jar patch (applied above) is still required — it is a
  # bytecode gate that -Xoverride-konan-properties cannot bypass.
  "$KONANC_BIN" \
    -target ios_arm64 \
    -p framework \
    -Xadd-light-debug=disable \
    -Xbinary=bundleId=com.example.spike \
    -Xoverride-konan-properties="targetSysRoot.ios_arm64=${IPHONE_SDK};linker.linux_x64-ios_arm64=${XCROSS_LD64LLD};targetToolchain.linux_x64-ios_arm64=${DARWIN_SDK}/toolset" \
    -Xinclude="$KLIB_PATH" \
    "${LIBARGS[@]}" \
    -o /tmp/out/Shared \
    2>&1 || KONANC_EXIT=$?

  echo ""
  echo "konanc exit code: $KONANC_EXIT"

  if [[ $KONANC_EXIT -ne 0 ]]; then
    echo "===== U-XINCLUDE-LINK: FAIL (konanc exit=$KONANC_EXIT) ====="
    XINCLUDE_LINK_RESULT="$FAIL (konanc exit=$KONANC_EXIT; JAR_PATCHED=$JAR_PATCHED)"
    XINCLUDE_ENTRY_RESULT="$FAIL (link step failed)"
  else
    # Check Shared.framework structure.
    if [[ -d /tmp/out/Shared.framework ]]; then
      echo "Shared.framework produced:"
      ls -la /tmp/out/Shared.framework/
      XINCLUDE_LINK_RESULT="$PASS"
    else
      echo "WARNING: konanc exit=0 but /tmp/out/Shared.framework not found"
      ls -la /tmp/out/ 2>/dev/null || true
      XINCLUDE_LINK_RESULT="$FAIL (framework dir not found despite exit=0)"
    fi

    # U-XINCLUDE-ENTRY: verify Shared.h exports MainViewControllerKt.
    # The generated header uses the framework baseName as prefix, so the class
    # appears as `SharedMainViewControllerKt` with factory:
    #   + (UIViewController *)MainViewController;
    SHARED_H="/tmp/out/Shared.framework/Headers/Shared.h"
    if [[ -f "$SHARED_H" ]]; then
      echo ""
      echo "Shared.h found. Checking for MainViewControllerKt and factory:"
      grep -n 'MainViewControllerKt' "$SHARED_H" || true
      grep -n '(UIViewController \*)MainViewController' "$SHARED_H" || true
      echo ""
      MVC_COUNT=$(grep -c 'MainViewControllerKt' "$SHARED_H" 2>/dev/null || echo 0)
      FACTORY_COUNT=$(grep -c '(UIViewController \*)MainViewController' "$SHARED_H" 2>/dev/null || echo 0)
      if [[ "$MVC_COUNT" -gt 0 && "$FACTORY_COUNT" -gt 0 ]]; then
        XINCLUDE_ENTRY_RESULT="$PASS (MainViewControllerKt x${MVC_COUNT} + factory x${FACTORY_COUNT} in Shared.h)"
      elif [[ "$MVC_COUNT" -gt 0 ]]; then
        echo "WARNING: MainViewControllerKt found but factory '(UIViewController *)MainViewController' absent"
        XINCLUDE_ENTRY_RESULT="$FAIL (class present x${MVC_COUNT} but factory absent in Shared.h)"
      else
        echo "WARNING: MainViewControllerKt not found in Shared.h"
        echo "Shared.h head (80 lines):"
        head -80 "$SHARED_H" || true
        XINCLUDE_ENTRY_RESULT="$FAIL (MainViewControllerKt absent from Shared.h)"
      fi
    else
      echo "Shared.h not found at $SHARED_H"
      [[ -d /tmp/out/Shared.framework ]] && ls -la /tmp/out/Shared.framework/ || true
      XINCLUDE_ENTRY_RESULT="$FAIL (Shared.h not found)"
    fi
  fi
fi

# ── SPIKE SUMMARY ─────────────────────────────────────────────────────────────
echo ""
echo "=================================================="
echo "SPIKE SUMMARY"
echo "=================================================="
echo "U-XCOMPILE-FLAG:   $XCOMPILE_RESULT"
echo "U-DEPS-ENUM:       $DEPS_RESULT"
echo "U-XINCLUDE-LINK:   $XINCLUDE_LINK_RESULT"
echo "U-XINCLUDE-ENTRY:  $XINCLUDE_ENTRY_RESULT"
echo "--------------------------------------------------"
echo "HostManager jar patch applied: $JAR_PATCHED"
echo "  → Without the patch, konanc blocks ios_arm64 on Linux at runtime."
echo "    The jar patch (patchKotlinNativeJar in host_manager_patcher.dart)"
echo "    is a hard prerequisite for U-XCOMPILE-FLAG, U-XINCLUDE-LINK,"
echo "    and U-XINCLUDE-ENTRY. If JAR_PATCHED=false above, those FAIL"
echo "    results are attributable to the missing patch, not to the mechanism."
echo "=================================================="
# Always exit 0 so artifacts are uploaded even on failure.
# The 'Assert no FAILs' workflow step reads this log and sets the job red.
exit 0
