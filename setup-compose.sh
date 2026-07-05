#!/usr/bin/env bash
# setup-compose.sh — provision a bare (non-Docker) Linux host for
# `xcross compose` (Kotlin/Compose Multiplatform iOS builds).
#
# Installs/downloads everything the ComposePacker pipeline needs and prints the
# env vars to export. Mirrors Dockerfile.xcross-compose-amd64.
#
# Usage:
#   sudo -E ./setup-compose.sh            # apt installs need root
#   # then follow the printed `export ...` lines (or `source` the env file)
#
# Tunables (env):
#   KN_VERSION   Kotlin/Native version           (default 2.2.20)
#   KONAN_ROOT   where K/N + deps live            (default /opt/konan)
#   ENV_FILE     file to write exports into       (default ./.xcross-compose.env)
set -euo pipefail

KN_VERSION="${KN_VERSION:-2.2.20}"
KONAN_ROOT="${KONAN_ROOT:-/opt/konan}"
ENV_FILE="${ENV_FILE:-$(pwd)/.xcross-compose.env}"
LX_KN="$KONAN_ROOT/kotlin-native-prebuilt-linux-x86_64-$KN_VERSION"
MAVEN="https://repo.maven.apache.org/maven2/org/jetbrains/kotlin/kotlin-native-prebuilt/$KN_VERSION"

err()  { printf 'error: %s\n' "$1" >&2; exit 1; }
info() { printf '\033[1;32m==>\033[0m %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- 0. preflight -----------------------------------------------------------
[ "$(uname -s)" = "Linux" ]  || err "Linux only (got $(uname -s))."
[ "$(uname -m)" = "x86_64" ] || err "x86_64 only — Kotlin/Native konanc has no linux-aarch64 prebuilt (got $(uname -m))."
have curl || err "need curl."
have tar  || err "need tar."

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  have sudo && SUDO="sudo" || err "run as root or install sudo (apt installs need root)."
fi

# --- 1. apt packages: JDK 21, LLVM (clang + lld), build tools ---------------
info "Installing system packages (JDK 21, clang, lld, build tools)..."
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update
$SUDO apt-get install -y --no-install-recommends \
  ca-certificates build-essential clang lld git file curl zip unzip xz-utils \
  openjdk-21-jdk-headless

# --- 2. JAVA_HOME -----------------------------------------------------------
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"
[ -x "$JAVA_HOME/bin/java" ] || JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
[ -x "$JAVA_HOME/bin/java" ] || err "JDK not found after install."
info "JAVA_HOME=$JAVA_HOME"

# --- 3. XCROSS_LD64LLD: real iOS-capable ld64.lld (stock LLVM) --------------
# The swift image's /usr/bin/ld64.lld is Apple-stubbed; find the LLVM one.
find_ld64lld() {
  local c
  for c in /usr/lib/llvm-*/bin/ld64.lld "$(command -v ld64.lld 2>/dev/null || true)"; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}
XCROSS_LD64LLD="$(find_ld64lld)" || err "ld64.lld not found — is 'lld' installed?"
"$XCROSS_LD64LLD" --version >/dev/null || err "ld64.lld not runnable: $XCROSS_LD64LLD"
info "XCROSS_LD64LLD=$XCROSS_LD64LLD"

# --- 4. KONAN_DATA_DIR + LX_KN ---------------------------------------------
KONAN_DATA_DIR="$KONAN_ROOT"
info "Preparing Kotlin/Native root at $KONAN_ROOT ..."
$SUDO mkdir -p "$LX_KN"
$SUDO chown -R "$(id -u):$(id -g)" "$KONAN_ROOT"

# 4a. linux-x86_64 prebuilt (~200 MB), skip if already extracted
if [ -f "$LX_KN/bin/konanc" ]; then
  info "K/N linux-x86_64 already present, skipping download."
else
  info "Downloading K/N linux-x86_64 $KN_VERSION (~200 MB)..."
  curl -fsSL --retry 3 "$MAVEN/kotlin-native-prebuilt-$KN_VERSION-linux-x86_64.tar.gz" \
    | tar -xz --strip-components=1 -C "$LX_KN"
  [ -f "$LX_KN/bin/konanc" ] || err "konanc missing after extract."
fi

# 4b. ios_arm64 overlay from macos-x86_64 prebuilt — the linux tree ships none
if [ -d "$LX_KN/konan/targets/ios_arm64" ]; then
  info "ios_arm64 overlay already present, skipping."
else
  info "Downloading ios_arm64 overlay from macos-x86_64 prebuilt (~250 MB)..."
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  curl -fsSL --retry 3 "$MAVEN/kotlin-native-prebuilt-$KN_VERSION-macos-x86_64.tar.gz" -o "$tmp"
  prefix="$(tar -tzf "$tmp" | head -1 | cut -d/ -f1)"
  mkdir -p "$LX_KN/konan/targets" "$LX_KN/klib/platform"
  tar -xzf "$tmp" -C "$LX_KN" --strip-components=1 \
    "$prefix/konan/targets/ios_arm64" \
    "$prefix/klib/platform/ios_arm64"
  rm -f "$tmp"; trap - EXIT
  [ -d "$LX_KN/konan/targets/ios_arm64" ] || err "ios_arm64 overlay missing after extract."
fi

# 4c. warm konanc's native deps (LLVM x86_64 ~174 MB) via throwaway host compile
if [ -d "$KONAN_ROOT/dependencies" ]; then
  info "konan deps already warmed, skipping."
else
  info "Warming konanc native deps (LLVM ~174 MB)..."
  warm="$(mktemp -d)"; printf 'fun main() {}\n' > "$warm/w.kt"
  KONAN_DATA_DIR="$KONAN_DATA_DIR" JAVA_HOME="$JAVA_HOME" \
    "$LX_KN/bin/konanc" -target linux_x64 -p program -o "$warm/w" "$warm/w.kt" 2>&1 | tail -3 || true
  rm -rf "$warm"
  [ -d "$KONAN_ROOT/dependencies" ] || info "warn: deps dir not created; konanc will fetch on first real build."
fi

# --- 5. gradle check (non-fatal) -------------------------------------------
if have gradle; then
  info "gradle: $(gradle --version 2>/dev/null | awk '/^Gradle/{print $2}')"
else
  info "note: no system 'gradle' — your KMP project's ./gradlew wrapper will be used."
fi

# --- 6. xtool check (non-fatal) --------------------------------------------
have xtool || info "note: 'xtool' not on PATH — needed for install/launch (run 'xtool auth' + 'xtool sdk install <Xcode.xip>')."

# --- 7. write env file + print ---------------------------------------------
cat > "$ENV_FILE" <<EOF
# xcross compose env — source this before 'xcross compose run/build'
export JAVA_HOME="$JAVA_HOME"
export XCROSS_LD64LLD="$XCROSS_LD64LLD"
export KONAN_DATA_DIR="$KONAN_DATA_DIR"
export LX_KN="$LX_KN"
export PATH="\$JAVA_HOME/bin:\$PATH"
EOF

info "Done. Wrote env to: $ENV_FILE"
echo
echo "Activate it in your shell:"
echo "    source \"$ENV_FILE\""
echo
echo "Then build/run from your KMP project:"
echo "    xcross compose run -u <UDID>"
