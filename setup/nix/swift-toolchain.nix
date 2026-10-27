# The upstream swift.org Linux toolchain, patched to run from the Nix store.
#
# nixpkgs' own `swift` lags behind the release xcross requires (6.4+) and is
# split into separately wrapped components, while xcross needs the complete
# upstream toolchain: the swift driver, SwiftPM, and the sibling clang/lld that
# match the Darwin SDK built by `xcross sdk install`.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  curl,
  libedit,
  libuuid,
  libxml2_13,
  ncurses,
  python312,
  sqlite,
  zlib,
  version,
  sources,
}:
let
  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "xcross: no Swift toolchain for ${stdenv.hostPlatform.system}");
  hostTriple = stdenv.hostPlatform.config;
in
stdenv.mkDerivation {
  pname = "swift-toolchain";
  inherit version;

  src = fetchurl { inherit (source) url hash; };

  nativeBuildInputs = [ autoPatchelfHook ];

  buildInputs = [
    stdenv.cc.cc.lib
    curl
    libedit
    libuuid
    libxml2_13
    ncurses
    # lldb links libpython3.12.so.1.0 from Ubuntu 24.04.
    python312
    sqlite
    zlib
  ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  # Ubuntu names libedit's soname libedit.so.2; nixpkgs ships libedit.so.0.
  autoPatchelfIgnoreMissingDeps = [ "libedit.so.2" ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r usr/* "$out/"
    runHook postInstall
  '';

  # The toolchain's clang (also the Swift link driver) expects Ubuntu's glibc,
  # GCC runtime and /lib loader. A config file named after the Linux triple is
  # loaded by clang, swiftc's link step and the Swift ClangImporter for host
  # targets only, so Apple targets (iOS, simulator) are unaffected.
  postFixup = ''
    cat > "$out/bin/${hostTriple}.cfg" <<EOF
    --gcc-toolchain=${stdenv.cc.cc}
    -B${stdenv.cc.libc}/lib
    -idirafter ${lib.getDev stdenv.cc.libc}/include
    -fuse-ld=lld
    -L${stdenv.cc.libc}/lib
    -L${stdenv.cc.cc.lib}/lib
    -Wl,--dynamic-linker=$(cat ${stdenv.cc}/nix-support/dynamic-linker)
    -Wl,-rpath,${stdenv.cc.cc.lib}/lib
    -Wno-unused-command-line-argument
    EOF

    find "$out" -type f -executable -print0 | while IFS= read -r -d "" file; do
      if patchelf --print-needed "$file" 2>/dev/null | grep -qx libedit.so.2; then
        patchelf --replace-needed libedit.so.2 libedit.so.0 "$file"
      fi
    done
  '';

  meta = {
    description = "Swift ${version} toolchain from swift.org, patched for Nix";
    homepage = "https://www.swift.org";
    license = lib.licenses.asl20;
    platforms = builtins.attrNames sources;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
