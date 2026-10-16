{
  description = "xcross: build, run, and hot-reload Flutter and Compose iOS apps from Linux";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      eachSystem = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      scopeFor = pkgs: import ./setup/nix { inherit pkgs; };
    in
    {
      # Builders for consumer flakes. Each takes the consumer's `pkgs` so the
      # results live in the consumer's package set:
      #
      #   xcross.lib.mkXcrossShell {
      #     inherit pkgs;
      #     flutter = pkgs.flutter;      # required
      #     jdk = pkgs.jdk21;            # optional, for Compose
      #     settings = { ... };          # optional, merged over the defaults
      #   }
      #
      # See docs/NixOS.md.
      lib = {
        scope = pkgs: scopeFor pkgs;
        mkXcrossShell = { pkgs, ... }@args: (scopeFor pkgs).mkXcrossShell (removeAttrs args [ "pkgs" ]);
        mkXcrossConfig =
          { pkgs, ... }@args: (scopeFor pkgs).mkXcrossConfig (removeAttrs args [ "pkgs" ]);
        mkXcrossSettings =
          { pkgs, ... }@args: (scopeFor pkgs).mkXcrossSettings (removeAttrs args [ "pkgs" ]);
      };

      overlays.default = final: _: {
        xcross = (scopeFor final).xcross;
      };

      packages = eachSystem (
        pkgs:
        let
          scope = scopeFor pkgs;
        in
        {
          inherit (scope)
            xcross
            swiftToolchain
            pymobiledevice3
            ;
          default = scope.xcross;
        }
      );

      apps = eachSystem (pkgs: {
        default = {
          type = "app";
          program = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.xcross;
          meta.description = "xcross CLI";
        };
      });

      devShells = eachSystem (
        pkgs:
        let
          scope = scopeFor pkgs;
        in
        {
          # End-user shell with the default configuration and nixpkgs' Flutter.
          default = scope.mkXcrossShell {
            flutter = pkgs.flutter;
            jdk = pkgs.jdk21;
          };

          # Building xcross itself from this checkout.
          contributor = pkgs.mkShell {
            packages = scope.runtimePackages ++ [
              pkgs.dart
              pkgs.cmake
              pkgs.ninja
              pkgs.unzip
              pkgs.xz
            ];
            SWIFT_EXEC = "${scope.swiftCompiler}";
            SWIFT_EXEC_MANIFEST = "${scope.swiftCompiler}";
          };
        }
      );

      checks = eachSystem (
        pkgs:
        let
          scope = scopeFor pkgs;
          inherit (scope) xcross;
          settings = scope.mkXcrossSettings {
            flutter = pkgs.flutter;
            jdk = pkgs.jdk21;
            settings = {
              roots.javaHome = null;
              tools.custom = "/opt/custom";
              excluded_commands = [ "setup" ];
            };
          };
          config = scope.mkXcrossConfig { flutter = pkgs.flutter; };
        in
        {
          # Merging semantics of `settings`.
          settings =
            assert !(settings.roots ? javaHome);
            assert settings.tools.custom == "/opt/custom";
            assert settings.tools.xcrun == "${xcross}/bin/xcrun";
            assert settings.excluded_commands == [ "setup" ];
            assert settings.environment.FLUTTER_ROOT == "${pkgs.flutter}";
            pkgs.runCommand "xcross-settings-check" { } "touch $out";

          # The patched release runs from the store and accepts its own config.
          xcross =
            pkgs.runCommand "xcross-check"
              {
                nativeBuildInputs = [ xcross ];
                XCROSS_CONFIG = config;
              }
              ''
                export HOME="$TMPDIR"
                version="$(xcross --version 2>&1)"
                printf '%s\n' "$version"
                [[ "$version" == *"xcross ${xcross.version}"* ]]
                xcrun --version 2>&1 | tee /dev/stderr | grep -q 'xcrun version'
                # --help loads and validates XCROSS_CONFIG before listing
                # commands.
                xcross --help > help.txt 2>&1 || { cat help.txt; exit 1; }
                cat help.txt
                if grep -Eq '^[[:space:]]+(config|setup|update)[[:space:]]' help.txt; then
                  echo "excluded commands are still listed" >&2
                  exit 1
                fi
                # The wrapper prepends the runtime: the Swift toolchain's clang
                # must win over any wrapped compiler.
                grep -q '${xcross.swiftToolchain}/bin' ${xcross}/bin/xcross
                touch "$out"
              '';

          swift =
            pkgs.runCommand "xcross-swift-check"
              {
                nativeBuildInputs = scope.runtimePackages;
                SWIFT_EXEC = scope.swiftCompiler;
                SWIFT_EXEC_MANIFEST = scope.swiftCompiler;
              }
              ''
                export HOME="$TMPDIR"
                swift --version 2>&1 | grep -qF 'Swift version ${lib.versions.majorMinor scope.swiftToolchain.version}'
                ${scope.swiftToolchain}/bin/clang --version >/dev/null
                ${scope.swiftToolchain}/bin/ld64.lld --version >/dev/null
                # A host executable exercises the <triple>.cfg wiring: the Nix
                # loader, glibc, the GCC runtime and LLD. `swift build` runs in
                # the consumer shell in CI.
                printf 'import Glibc\nprint("hello \\(getpid() > 0)")\n' > probe.swift
                swiftc probe.swift -o probe
                ./probe | grep -qx 'hello true'
                printf 'int main(void) { return 0; }\n' > probe.c
                ${scope.swiftToolchain}/bin/clang probe.c -o probe-c
                ./probe-c
                touch "$out"
              '';

          pymobiledevice3 = pkgs.runCommand "xcross-pymobiledevice3-check" { } ''
            export HOME="$TMPDIR"
            ${scope.pymobiledevice3Env}/bin/python3 -c 'import pymobiledevice3'
            ${scope.pymobiledevice3Env}/bin/pymobiledevice3 lockdown wifi-connections --help >/dev/null
            touch "$out"
          '';
        }
      );

      formatter = eachSystem (pkgs: pkgs.nixfmt);
    };
}
