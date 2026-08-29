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

  outputs =
    inputs@{ nixpkgs, ... }:
    let
      version = "1.3.2";
      swiftVersion = "6.3.3";
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      releaseFor =
        system: if system == "x86_64-linux" then inputs.xcross-linux-x64 else inputs.xcross-linux-arm64;
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [
            (final: prev: {
              python313 = prev.python313.override {
                packageOverrides = pyFinal: pyPrev: {
                  pyimg4 = pyPrev.pyimg4.overridePythonAttrs (old: {
                    pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "asn1" ];
                    doCheck = false;
                    meta = old.meta // {
                      broken = false;
                    };
                  });
                };
              };
              python313Packages = final.python313.pkgs;
            })
          ];
        };
      outputsFor =
        system:
        let
          pkgs = pkgsFor system;
          swiftToolchainUrls =
            {
              x86_64-linux = {
                url = "https://download.swift.org/swift-${swiftVersion}-release/ubuntu2404/swift-${swiftVersion}-RELEASE/swift-${swiftVersion}-RELEASE-ubuntu24.04.tar.gz";
                hash = "sha256-2oJypf3czWWxUp7Q5S4EUm4urdQjfVjWIg7+uXPGzRk=";
              };
              aarch64-linux = {
                url = "https://download.swift.org/swift-${swiftVersion}-release/ubuntu2404-aarch64/swift-${swiftVersion}-RELEASE/swift-${swiftVersion}-RELEASE-ubuntu24.04-aarch64.tar.gz";
                hash = "sha256-RxJjlUKWU/p2jTcGVYduwbaPapXHiE9eTxeXABQcm38=";
              };
            }
            .${system};

          swiftToolchain = pkgs.stdenv.mkDerivation {
            pname = "swift-toolchain-official";
            version = swiftVersion;

            src = pkgs.fetchurl { inherit (swiftToolchainUrls) url hash; };

            nativeBuildInputs = [ pkgs.autoPatchelfHook ];
            buildInputs = [
              pkgs.stdenv.cc.cc.lib
              pkgs.zlib
              pkgs.ncurses
              pkgs.libxml2_13
              pkgs.libedit
              pkgs.curl
              pkgs.libuuid
              pkgs.python312 # note: needs to be 3.12 specifically, matching libpython3.12.so.1.0
              pkgs.sqlite
            ];

            dontConfigure = true;
            dontBuild = true;
            autoPatchelfIgnoreMissingDeps = [ "libedit.so.2" ]; # TODO: find actual packages
            installPhase = ''
              runHook preInstall
              mkdir -p $out
              cp -r usr/* $out/
              runHook postInstall
            '';

            meta = {
              description = "Official Swift toolchain from swift.org";
              homepage = "https://swift.org";
              license = pkgs.lib.licenses.asl20;
              platforms = [
                "x86_64-linux"
                "aarch64-linux"
              ];
            };
          };
          runtimeDeps = with pkgs; [
            flutter
            swiftToolchain
            python313
            python313Packages.pymobiledevice3
            usbmuxd
            libimobiledevice
            usbutils
            pkg-config
            gnupg
          ];
          xcross = pkgs.stdenvNoCC.mkDerivation {
            pname = "xcross";
            inherit version;
            src = releaseFor system;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            dontBuild = true;
            dontFixup = true;

            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin" "$out/lib/xcross" "$out/share/licenses/xcross"
              cp -r bin lib "$out/lib/xcross/"
              install -m 0644 ${./LICENSE} "$out/share/licenses/xcross/LICENSE"
              install -m 0644 ${./packages/apple_developer_kit/ADI_LICENSE} \
                "$out/share/licenses/xcross/provision-dart.txt"

              for executable in xcross xcrun; do
                makeWrapper "$out/lib/xcross/bin/$executable" "$out/bin/$executable" \
                  --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps}
                cmp "$src/bin/$executable" "$out/lib/xcross/bin/$executable"
              done
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
          userPackages = [ xcross ] ++ runtimeDeps;
          contributorPackages =
            userPackages
            ++ (with pkgs; [
              dart
              cmake
              ninja
              git
              unzip
              xz
            ]);
          smokeCheck =
            pkgs.runCommand "xcross-smoke-check"
              {
                nativeBuildInputs = [ xcross ];
              }
              ''
                test -x ${xcross}/bin/xcross
                test -x ${xcross}/bin/xcrun
                test -d ${xcross}/lib/xcross/lib
                ${xcross}/bin/xcross --help | grep -F "Usage: xcross" >/dev/null
                ${xcross}/bin/xcross --version | grep -F "xcross ${version}" >/dev/null
                ${xcross}/bin/xcrun 2>&1 | grep -F "xcrun: no Darwin SDK installed" >/dev/null
                touch "$out"
              '';
        in
        {
          inherit
            pkgs
            xcross
            userPackages
            contributorPackages
            smokeCheck
            ;
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          output = outputsFor system;
        in
        {
          inherit (output) xcross;
          default = output.xcross;
        }
      );

      apps = forAllSystems (
        system:
        let
          output = outputsFor system;
        in
        {
          xcross = {
            type = "app";
            program = "${output.xcross}/bin/xcross";
          };
          default = {
            type = "app";
            program = "${output.xcross}/bin/xcross";
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          output = outputsFor system;
        in
        {
          default = output.pkgs.mkShell {
            packages = output.userPackages;
            FLUTTER_ROOT = "${output.pkgs.flutter}";
          };
          contributor = output.pkgs.mkShell {
            packages = output.contributorPackages;
            FLUTTER_ROOT = "${output.pkgs.flutter}";
          };
        }
      );

      checks = forAllSystems (system: {
        smoke = (outputsFor system).smokeCheck;
      });
    };
}
