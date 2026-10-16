# xcross release archive, made runnable from the Nix store.
#
# `bin/xcross` and `bin/xcrun` are Dart AOT executables. They are rewritten by
# ./patch-dart-aot.py so they use the Nix dynamic loader without corrupting the
# appended snapshot, then wrapped so every launch (terminal, IDE, DAP, nested
# xcross) sees the toolchain environment below.
{
  lib,
  stdenv,
  makeWrapper,
  patchelf,
  python3,
  autoPatchelfHook,
  fetchurl,
  version,
  sources,
  swiftToolchain,
  swiftCompiler,
  runtimePackages,
  licenses,
}:
stdenv.mkDerivation {
  pname = "xcross";
  inherit version;

  src = fetchurl (
    sources.${stdenv.hostPlatform.system}
      or (throw "xcross: no release archive for ${stdenv.hostPlatform.system}")
  );
  # The archive has bin/, lib/ and THIRD_PARTY_LICENSES/ at its root.
  sourceRoot = ".";

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
    patchelf
    python3
  ];

  # lib/libsysv_abi_bridge.so only needs libc.
  buildInputs = [ stdenv.cc.libc ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  # The Dart executables are handled by patch-dart-aot.py; autoPatchelf would
  # corrupt their appended snapshots, so it only runs on lib/ in postFixup.
  dontAutoPatchelf = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin" "$out/libexec/xcross/bin" "$out/share/licenses/xcross"
    cp -r lib "$out/libexec/xcross/lib"
    if [ -d THIRD_PARTY_LICENSES ]; then
      cp -r THIRD_PARTY_LICENSES/. "$out/share/licenses/xcross/"
    fi
    ${lib.concatMapStringsSep "\n" (license: ''
      install -m 0644 ${license.file} "$out/share/licenses/xcross/${license.name}"
    '') licenses}

    for executable in xcross xcrun; do
      python3 ${./patch-dart-aot.py} \
        "bin/$executable" \
        "$out/libexec/xcross/bin/$executable" \
        "$(cat $NIX_CC/nix-support/dynamic-linker)"
    done

    runHook postInstall
  '';

  postFixup = ''
    autoPatchelf "$out/libexec/xcross/lib"

    # xcross runs xcrun for itself and for SwiftPM/native-asset hooks that put
    # their own tools first, so xcrun appends the runtime PATH instead of
    # prepending it.
    for executable in xcross xcrun; do
      pathMode=--prefix
      if [ "$executable" = xcrun ]; then
        pathMode=--suffix
      fi
      makeWrapper "$out/libexec/xcross/bin/$executable" "$out/bin/$executable" \
        "$pathMode" PATH : ${lib.makeBinPath runtimePackages} \
        --set-default SWIFT_EXEC ${swiftCompiler} \
        --set-default SWIFT_EXEC_MANIFEST ${swiftCompiler} \
        --set-default CC ${swiftToolchain}/bin/clang \
        --set-default CXX ${swiftToolchain}/bin/clang++
    done
  '';

  passthru = {
    inherit swiftToolchain swiftCompiler runtimePackages;
  };

  meta = {
    description = "Build, run, and hot-reload Flutter and Compose iOS apps from Linux";
    homepage = "https://github.com/arxdeus/xcross";
    license = lib.licenses.mit;
    mainProgram = "xcross";
    platforms = builtins.attrNames sources;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
