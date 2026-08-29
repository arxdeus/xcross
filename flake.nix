{
  description = "xcross Linux development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    xcross-linux-x64 = {
      url = "https://github.com/arxdeus/xcross/releases/download/v1.3.2/xcross-linux-x64.tar.gz";
      flake = false;
    };

    xcross-linux-arm64 = {
      url = "https://github.com/arxdeus/xcross/releases/download/v1.3.2/xcross-linux-arm64.tar.gz";
      flake = false;
    };
  };

  outputs = inputs@{ nixpkgs, ... }:
    let
      version = "1.3.2";
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      releaseFor = system:
        if system == "x86_64-linux"
        then inputs.xcross-linux-x64
        else inputs.xcross-linux-arm64;
      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [
          (final: prev: {
            python313 = prev.python313.override {
              packageOverrides = pyFinal: pyPrev: {
                pyimg4 = pyPrev.pyimg4.overridePythonAttrs (old: {
                  pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "asn1" ];
                  doCheck = false;
                  meta = old.meta // { broken = false; };
                });
              };
            };
            python313Packages = final.python313.pkgs;
          })
        ];
      };
      outputsFor = system:
        let
          pkgs = pkgsFor system;
          xcross = pkgs.stdenv.mkDerivation {
            pname = "xcross";
            inherit version;
            src = releaseFor system;

            nativeBuildInputs = [ pkgs.patchelf pkgs.python3 ];

            dontBuild = true;
            dontPatchELF = true;
            dontStrip = true;

            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin" "$out/lib" "$out/share/licenses/xcross"
              cp -r bin/. "$out/bin/"
              cp -r lib/. "$out/lib/"
              install -m 0644 ${./LICENSE} "$out/share/licenses/xcross/LICENSE"
              install -m 0644 ${./packages/apple_developer_kit/ADI_LICENSE} \
                "$out/share/licenses/xcross/provision-dart.txt"

              for executable in xcross xcrun; do
                python3 - "$out/bin/$executable" "$TMPDIR/$executable.snapshot" <<'PY'
import pathlib
import struct
import sys

binary = pathlib.Path(sys.argv[1])
snapshot = pathlib.Path(sys.argv[2])
data = binary.read_bytes()
offset = struct.unpack_from("<Q", data, len(data) - 16)[0]
if offset <= 0 or offset >= len(data) - 16:
    raise ValueError(f"invalid Dart snapshot offset: {offset}")
snapshot.write_bytes(data[offset:])
binary.write_bytes(data[:offset])
PY
                patchelf \
                  --set-interpreter "$(cat "$NIX_CC/nix-support/dynamic-linker")" \
                  --set-rpath '$ORIGIN/../lib:${pkgs.lib.getLib pkgs.stdenv.cc.cc}/lib' \
                  "$out/bin/$executable"
                python3 - "$out/bin/$executable" "$TMPDIR/$executable.snapshot" <<'PY'
import pathlib
import struct
import sys

binary = pathlib.Path(sys.argv[1])
snapshot = pathlib.Path(sys.argv[2]).read_bytes()
runtime = binary.read_bytes()
offset = (len(runtime) + 65535) & ~65535
combined = runtime + bytes(offset - len(runtime)) + snapshot
combined = combined[:-16] + struct.pack("<Q", offset) + combined[-8:]
binary.write_bytes(combined)
PY
              done
              patchelf --set-rpath '$ORIGIN' "$out/lib/libsysv_abi_bridge.so"
              runHook postInstall
            '';

            meta = {
              description = "Build, run, and hot-reload Flutter iOS apps from Linux";
              homepage = "https://github.com/arxdeus/xcross";
              license = pkgs.lib.licenses.mit;
              mainProgram = "xcross";
              platforms = systems;
            };
          };
          userPackages = with pkgs; [
            xcross
            flutter
            swift
            llvmPackages.clang
            llvmPackages.llvm
            llvmPackages.lld
            python313
            python313Packages.pymobiledevice3
            usbmuxd
            libimobiledevice
            usbutils
            pkg-config
            zlib
            gcc
            libxml2
            ncurses
            z3
            gnupg
            glibc
            curl
            openssl
          ];
          contributorPackages = userPackages ++ (with pkgs; [
            dart
            cmake
            ninja
            git
            unzip
            xz
          ]);
          smokeCheck = pkgs.runCommand "xcross-smoke-check" {
            nativeBuildInputs = [ xcross ];
          } ''
            test -x ${xcross}/bin/xcross
            test -x ${xcross}/bin/xcrun
            test -d ${xcross}/lib
            ${xcross}/bin/xcross --help | grep -F "Usage: xcross" >/dev/null
            ${xcross}/bin/xcross --version | grep -F "xcross ${version}" >/dev/null
            ${xcross}/bin/xcrun 2>&1 | grep -F "xcrun: no Darwin SDK installed" >/dev/null
            touch "$out"
          '';
        in {
          inherit pkgs xcross userPackages contributorPackages smokeCheck;
        };
    in {
      packages = forAllSystems (system:
        let output = outputsFor system;
        in {
          inherit (output) xcross;
          default = output.xcross;
        });

      apps = forAllSystems (system:
        let output = outputsFor system;
        in {
          xcross = {
            type = "app";
            program = "${output.xcross}/bin/xcross";
          };
          default = {
            type = "app";
            program = "${output.xcross}/bin/xcross";
          };
        });

      devShells = forAllSystems (system:
        let output = outputsFor system;
        in {
          default = output.pkgs.mkShell {
            packages = output.userPackages;
            FLUTTER_ROOT = "${output.pkgs.flutter}";
          };
          contributor = output.pkgs.mkShell {
            packages = output.contributorPackages;
            FLUTTER_ROOT = "${output.pkgs.flutter}";
          };
        });

      checks = forAllSystems (system: {
        smoke = (outputsFor system).smokeCheck;
      });
    };
}
