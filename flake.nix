{
  description = "xcross Linux development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    xcross-linux-x64 = {
      url = "https://github.com/arxdeus/xcross/releases/download/v1.4.0/xcross-linux-x64.tar.gz";
      flake = false;
    };

    xcross-linux-arm64 = {
      url = "https://github.com/arxdeus/xcross/releases/download/v1.4.0/xcross-linux-arm64.tar.gz";
      flake = false;
    };
  };

  outputs =
    inputs@{ nixpkgs, ... }:
    let
      xcrossVersion = "1.4.0";
      swiftVersion = "6.3.3";

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      eachSystem = nixpkgs.lib.genAttrs systems;

      xcrossReleases = {
        x86_64-linux = inputs.xcross-linux-x64;
        aarch64-linux = inputs.xcross-linux-arm64;
      };

      swiftToolchainSources = {
        x86_64-linux = {
          url = "https://download.swift.org/swift-${swiftVersion}-release/ubuntu2404/swift-${swiftVersion}-RELEASE/swift-${swiftVersion}-RELEASE-ubuntu24.04.tar.gz";
          hash = "sha256-2oJypf3czWWxUp7Q5S4EUm4urdQjfVjWIg7+uXPGzRk=";
        };
        aarch64-linux = {
          url = "https://download.swift.org/swift-${swiftVersion}-release/ubuntu2404-aarch64/swift-${swiftVersion}-RELEASE/swift-${swiftVersion}-RELEASE-ubuntu24.04-aarch64.tar.gz";
          hash = "sha256-RxJjlUKWU/p2jTcGVYduwbaPapXHiE9eTxeXABQcm38=";
        };
      };

      pymobiledeviceOverlay = final: previous: {
        python313 = previous.python313.override {
          packageOverrides = pythonFinal: pythonPrevious: {
            pyimg4 = pythonPrevious.pyimg4.overridePythonAttrs (old: {
              pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "asn1" ];
              doCheck = false;
              meta = old.meta // {
                broken = false;
              };
            });
          };
        };
        python313Packages = final.python313.pkgs;
      };

      packagesFor = system:
        import nixpkgs {
          inherit system;
          overlays = [ pymobiledeviceOverlay ];
        };

      environmentFor = system:
        let
          pkgs = packagesFor system;
          xcrossRelease = xcrossReleases.${system};
          swiftToolchainSource = swiftToolchainSources.${system};

          swiftToolchain = pkgs.stdenv.mkDerivation {
            pname = "swift-toolchain";
            version = swiftVersion;
            src = pkgs.fetchurl {
              inherit (swiftToolchainSource) url hash;
            };

            dontConfigure = true;
            dontBuild = true;
            dontFixup = true;

            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              cp -r usr/* "$out/"
              runHook postInstall
            '';
          };

          swiftCompiler = pkgs.writeShellScript "xcross-swiftc" ''
            exec ${swiftToolchain}/bin/swiftc -use-ld=lld "$@"
          '';

          runtimePackages = [
            swiftToolchain
            pkgs.llvmPackages_21.llvm
            pkgs.llvmPackages_21.lld
            pkgs.flutter
            pkgs.jdk
            pkgs.git
            pkgs.python313
            pkgs.python313Packages.pymobiledevice3
            pkgs.usbmuxd
            pkgs.libimobiledevice
            pkgs.usbutils
            pkgs.pkg-config
            pkgs.gnupg
          ];

          runtimeEnvironment = pkgs.writeText "xcross-nix-environment" ''
            export XCROSS_DARWIN_BUNDLE="''${XCROSS_DARWIN_BUNDLE:-''${XDG_CONFIG_HOME:-$HOME/.config}/xcross/swift-sdks/xcross-darwin.artifactbundle}"
            export KONAN_DATA_DIR="''${KONAN_DATA_DIR:-$HOME/.konan}"
          '';

          configTemplate = pkgs.writeText "xcross-nix-config.yaml" (builtins.toJSON {
            roots = {
              darwinSdk = "$XCROSS_DARWIN_BUNDLE";
              flutterSdk = "${pkgs.flutter}";
              xcross = "@out@/bin/xcross";
              javaHome = "${pkgs.jdk.home}";
              konanData = "$KONAN_DATA_DIR";
            };
            toolchains = {
              swift = "${swiftToolchain}/bin";
              llvm = [
                "${swiftToolchain}/bin"
                "${pkgs.llvmPackages_21.llvm}/bin"
                "${pkgs.llvmPackages_21.lld}/bin"
              ];
            };
            excluded_commands = [ "config" "setup" ];
            environment = {
              PATH = map (package: "${package}/bin") runtimePackages;
              SWIFT_EXEC = "${swiftCompiler}";
              SWIFT_EXEC_MANIFEST = "${swiftCompiler}";
              CC = "${swiftToolchain}/bin/clang";
              CXX = "${swiftToolchain}/bin/clang++";
              FLUTTER_ROOT = "${pkgs.flutter}";
            };
          });

          xcross = pkgs.stdenvNoCC.mkDerivation {
            pname = "xcross";
            version = xcrossVersion;
            src = xcrossRelease;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            dontBuild = true;
            dontFixup = true;

            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin" "$out/lib/xcross" "$out/share/licenses/xcross" "$out/share/xcross"
              cp -r bin lib "$out/lib/xcross/"
              substitute ${configTemplate} "$out/share/xcross/config.yaml" \
                --replace-fail '@out@' "$out"
              install -m 0644 ${./LICENSE} "$out/share/licenses/xcross/LICENSE"
              install -m 0644 ${./packages/apple_developer_kit/ADI_LICENSE} \
                "$out/share/licenses/xcross/provision-dart.txt"

              for executable in xcross xcrun; do
                makeWrapper "$out/lib/xcross/bin/$executable" "$out/bin/$executable" \
                  --run "source ${runtimeEnvironment}" \
                  --set XCROSS_CONFIG "$out/share/xcross/config.yaml" \
                  --prefix PATH : ${pkgs.lib.makeBinPath runtimePackages} \
                  --set SWIFT_EXEC ${swiftCompiler} \
                  --set SWIFT_EXEC_MANIFEST ${swiftCompiler} \
                  --set CC ${swiftToolchain}/bin/clang \
                  --set CXX ${swiftToolchain}/bin/clang++
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

          userPackages = [ xcross ] ++ runtimePackages;

          contributorPackages = userPackages ++ [
            pkgs.cmake
            pkgs.ninja
            pkgs.git
            pkgs.unzip
            pkgs.xz
          ];

          shellHook = ''
            source ${runtimeEnvironment}
            export XCROSS_CONFIG=${xcross}/share/xcross/config.yaml
            export FLUTTER_ROOT=${pkgs.flutter}
            export JAVA_HOME=${pkgs.jdk.home}
            export SWIFT_EXEC=${swiftCompiler}
            export SWIFT_EXEC_MANIFEST=${swiftCompiler}
            export CC=${swiftToolchain}/bin/clang
            export CXX=${swiftToolchain}/bin/clang++
          '';

          smokeCheck = pkgs.runCommand "xcross-smoke-check" {
            nativeBuildInputs = [ xcross ];
          } ''
            test -x ${xcross}/bin/xcross
            test -x ${xcross}/bin/xcrun
            test -d ${xcross}/lib/xcross/lib
            cmp ${xcrossRelease}/bin/xcross ${xcross}/lib/xcross/bin/xcross
            cmp ${xcrossRelease}/bin/xcrun ${xcross}/lib/xcross/bin/xcrun
            touch "$out"
          '';
        in
        {
          inherit
            pkgs
            xcross
            userPackages
            contributorPackages
            shellHook
            smokeCheck
            ;
        };
    in
    {
      packages = eachSystem (
        system:
        let
          environment = environmentFor system;
        in
        {
          inherit (environment) xcross;
          default = environment.xcross;
        }
      );

      apps = eachSystem (
        system:
        let
          environment = environmentFor system;
          app = {
            type = "app";
            program = "${environment.xcross}/bin/xcross";
          };
        in
        {
          xcross = app;
          default = app;
        }
      );

      devShells = eachSystem (
        system:
        let
          environment = environmentFor system;
        in
        {
          default = environment.pkgs.mkShell {
            packages = environment.userPackages;
            inherit (environment) shellHook;
          };

          contributor = environment.pkgs.mkShell {
            packages = environment.contributorPackages;
            inherit (environment) shellHook;
          };
        }
      );

      checks = eachSystem (system: {
        smoke = (environmentFor system).smokeCheck;
      });
    };
}
