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

            nativeBuildInputs = [ pkgs.autoPatchelfHook ];
            buildInputs = [ pkgs.stdenv.cc.cc.lib ];

            dontBuild = true;

            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin" "$out/lib" "$out/share/licenses/xcross"
              cp -r bin/. "$out/bin/"
              cp -r lib/. "$out/lib/"
              install -m 0644 ${./LICENSE} "$out/share/licenses/xcross/LICENSE"
              install -m 0644 ${./packages/apple_developer_kit/ADI_LICENSE} \
                "$out/share/licenses/xcross/provision-dart.txt"
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
            nativeBuildInputs = userPackages;
          } ''
            test -x ${xcross}/bin/xcross
            test -x ${xcross}/bin/xcrun
            test -d ${xcross}/lib
            ${xcross}/bin/xcross --help >/dev/null
            ${xcross}/bin/xcross --version | grep -F ${version} >/dev/null
            for tool in xcross xcrun dart flutter swift swiftc clang clang++ llvm-ar ld64.lld python3 pymobiledevice3 usbmuxd idevice_id pkg-config gpg; do
              command -v "$tool" >/dev/null
            done
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
