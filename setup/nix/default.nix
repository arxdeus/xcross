# xcross Nix scope for one package set.
#
# Everything here is built from the caller's `pkgs`, so a consumer flake that
# makes its nixpkgs follow `xcross/nixpkgs` reuses the same store paths and
# binary cache, while a consumer that does not still gets a consistent set.
{ pkgs }:
let
  inherit (pkgs) lib;
  sources = import ./sources.nix;
  llvmPackages = pkgs.llvmPackages_21;

  # nixpkgs' pymobiledevice3 is far behind upstream (no `remotepairing`, so no
  # Wi-Fi tunnels); see ./pymobiledevice3/README.md.
  python = pkgs.python313.override {
    self = python;
    packageOverrides = import ./pymobiledevice3/overrides.nix { inherit lib; };
  };
  pymobiledevice3 = python.pkgs.callPackage ./pymobiledevice3/package.nix { };
  # Pymd.tunneldInvocation() looks for a python >= 3.13 that can
  # `import pymobiledevice3`, so ship an interpreter environment, not only the
  # CLI.
  pymobiledevice3Env = python.withPackages (_: [ pymobiledevice3 ]);

  swiftToolchain = pkgs.callPackage ./swift-toolchain.nix {
    inherit (sources.swift) version sources;
  };

  # The Swift driver locates glibc (for `import Glibc` and the C stdlib) under
  # the SDK root, which defaults to `/`. Give host compiles an FHS-shaped view
  # of the store glibc, kernel headers and GCC runtime instead.
  hostSysroot = pkgs.runCommand "xcross-host-sysroot" { } ''
    mkdir -p "$out/usr/include" "$out/usr/lib"
    for dir in ${lib.getDev pkgs.stdenv.cc.libc}/include ${pkgs.linuxHeaders}/include; do
      for entry in "$dir"/*; do
        [ -e "$out/usr/include/$(basename "$entry")" ] || ln -s "$entry" "$out/usr/include/"
      done
    done
    for dir in ${pkgs.stdenv.cc.libc}/lib ${pkgs.stdenv.cc.cc.lib}/lib ${pkgs.stdenv.cc.cc}/lib; do
      for entry in "$dir"/*; do
        [ -e "$out/usr/lib/$(basename "$entry")" ] || ln -s "$entry" "$out/usr/lib/"
      done
    done
    ln -s usr/lib "$out/lib"
    # The driver also resolves swiftrt.o and the runtime under <sdk>/usr/lib.
    for name in swift swift_static; do
      [ -e "${swiftToolchain}/lib/$name" ] && ln -sfn "${swiftToolchain}/lib/$name" "$out/usr/lib/$name"
    done
  '';

  # Host links go through the toolchain's <triple>.cfg (see
  # swift-toolchain.nix). Host (non-Apple) swiftc invocations also get the
  # sysroot above. Apple targets (iOS, simulator), which bring their own
  # -sdk, are passed through untouched.
  swiftcWrapper = pkgs.writeShellScript "swiftc" ''
    # -frontend, -modulewrap and --driver-mode must stay the first argument.
    case "''${1-}" in
      -frontend | -modulewrap | --driver-mode=*) exec ${swiftToolchain}/bin/swiftc "$@" ;;
    esac
    for argument in "$@"; do
      case "$argument" in
        *-apple-* | -sdk) exec ${swiftToolchain}/bin/swiftc "$@" ;;
        @*)
          if [ -f "''${argument#@}" ] && grep -qE -- '-apple-|^-sdk$' "''${argument#@}"; then
            exec ${swiftToolchain}/bin/swiftc "$@"
          fi
          ;;
      esac
    done
    exec ${swiftToolchain}/bin/swiftc -sdk ${hostSysroot} "$@"
  '';

  # SwiftPM finds swift-autolink-extract, libclang and libSwiftScan relative
  # to SWIFT_EXEC, so the wrapper lives in a mirror of the toolchain layout.
  swiftCompilerToolchain = pkgs.runCommand "xcross-swiftc-toolchain" { } ''
    mkdir -p "$out/bin"
    for entry in ${swiftToolchain}/*; do
      [ "$(basename "$entry")" = bin ] || ln -s "$entry" "$out/"
    done
    for entry in ${swiftToolchain}/bin/*; do
      ln -s "$entry" "$out/bin/"
    done
    rm "$out/bin/swiftc"
    install -m 0755 ${swiftcWrapper} "$out/bin/swiftc"
  '';
  swiftCompiler = "${swiftCompilerToolchain}/bin/swiftc";

  # Order matters: the Swift toolchain's clang/lld come first so `clang`
  # resolves to the unwrapped compiler that can target iOS. The wrapped LLVM
  # clang after it supplies the host `cc` for native-asset hooks.
  runtimePackages = [
    swiftCompilerToolchain
    llvmPackages.clang
    llvmPackages.llvm
    llvmPackages.lld
    pymobiledevice3Env
    pkgs.git
    pkgs.gnupg
    pkgs.libimobiledevice
    pkgs.pkg-config
    pkgs.usbmuxd
    pkgs.usbutils
  ];

  xcross = pkgs.callPackage ./xcross.nix {
    inherit (sources.xcross) version sources;
    inherit swiftToolchain swiftCompiler runtimePackages;
    licenses = [
      {
        name = "LICENSE";
        file = ../../LICENSE;
      }
      {
        name = "ADI_LICENSE";
        file = ../../packages/apple_developer_kit/ADI_LICENSE;
      }
    ];
  };

  # Default xcross configuration for a Nix-managed environment.
  #
  # Every immutable path is a store path. Mutable data (the imported Darwin SDK,
  # Kotlin/Native, caches) keeps xcross' defaults under $HOME unless `settings`
  # overrides them. `settings` is merged with lib.recursiveUpdate: attribute
  # sets merge, lists and scalars replace, and `null` removes a default.
  defaultSettings =
    {
      flutter,
      jdk ? null,
      xcross ? scope.xcross,
    }:
    let
      toolchain = xcross.swiftToolchain;
      compiler = xcross.swiftCompiler;
    in
    {
      roots = {
        # The wrapper, not libexec/xcross/bin/xcross: IDE run configurations,
        # the DAP server and nested invocations re-launch this path and must
        # get the toolchain environment.
        xcross = "${xcross}/bin/xcross";
        flutterSdk = "${flutter}";
        javaHome = if jdk == null then null else jdk.home;
      };
      tools = {
        flutter = "${flutter}/bin/flutter";
        # Resolved beside the running binary otherwise, which would be the
        # unwrapped libexec copy.
        xcrun = "${xcross}/bin/xcrun";
      };
      toolchains = {
        swift = "${toolchain}/bin";
        llvm = [
          "${toolchain}/bin"
          "${llvmPackages.llvm}/bin"
          "${llvmPackages.lld}/bin"
        ];
      };
      environment = {
        SWIFT_EXEC = "${compiler}";
        SWIFT_EXEC_MANIFEST = "${compiler}";
        CC = "${toolchain}/bin/clang";
        CXX = "${toolchain}/bin/clang++";
        FLUTTER_ROOT = "${flutter}";
      };
      # These mutate host state or the installation itself, which Nix owns:
      # change the configuration in the flake, dependencies in `packages`, and
      # the version through `nix flake update`.
      excluded_commands = [
        "config"
        "setup"
        "update"
      ];
    };

  pruneNulls =
    value:
    if builtins.isAttrs value then
      lib.mapAttrs (_: pruneNulls) (lib.filterAttrs (_: v: v != null) value)
    else if builtins.isList value then
      map pruneNulls value
    else
      value;

  mkXcrossSettings =
    {
      flutter,
      jdk ? null,
      xcross ? scope.xcross,
      settings ? { },
    }:
    pruneNulls (lib.recursiveUpdate (defaultSettings { inherit flutter jdk xcross; }) settings);

  # A store path to pass as XCROSS_CONFIG. JSON is valid YAML.
  mkXcrossConfig =
    {
      flutter,
      jdk ? null,
      xcross ? scope.xcross,
      settings ? { },
      name ? "xcross-config.yaml",
    }:
    pkgs.writeText name (
      builtins.toJSON (mkXcrossSettings {
        inherit
          flutter
          jdk
          xcross
          settings
          ;
      })
    );

  # A development shell with xcross, its runtime, Flutter, and XCROSS_CONFIG.
  # Unknown arguments are passed to pkgs.mkShell.
  mkXcrossShell =
    {
      flutter,
      jdk ? null,
      xcross ? scope.xcross,
      settings ? { },
      packages ? [ ],
      shellHook ? "",
      ...
    }@args:
    let
      config = mkXcrossConfig {
        inherit
          flutter
          jdk
          xcross
          settings
          ;
      };
      shellArgs = removeAttrs args [
        "flutter"
        "jdk"
        "xcross"
        "settings"
        "packages"
        "shellHook"
      ];
    in
    pkgs.mkShell (
      shellArgs
      // {
        packages = [
          xcross
          flutter
        ]
        ++ lib.optional (jdk != null) jdk
        ++ xcross.runtimePackages
        ++ packages;

        XCROSS_CONFIG = config;
        FLUTTER_ROOT = "${flutter}";
        SWIFT_EXEC = "${xcross.swiftCompiler}";
        SWIFT_EXEC_MANIFEST = "${xcross.swiftCompiler}";

        passthru = (shellArgs.passthru or { }) // {
          xcrossConfig = config;
        };

        inherit shellHook;
      }
      // lib.optionalAttrs (jdk != null) { JAVA_HOME = jdk.home; }
    );

  scope = {
    inherit
      xcross
      swiftToolchain
      swiftCompiler
      pymobiledevice3
      pymobiledevice3Env
      runtimePackages
      llvmPackages
      defaultSettings
      mkXcrossSettings
      mkXcrossConfig
      mkXcrossShell
      ;
  };
in
scope
