# NixOS

The xcross flake packages the Linux release for `x86_64-linux` and
`aarch64-linux`, together with everything it runs: a patched swift.org
toolchain, LLVM/LLD, an up-to-date `pymobiledevice3`, and the USB device tools.
Consumer projects supply Flutter (required) and optionally a JDK, and get a
default xcross configuration they can override piece by piece.

Nothing here needs `nix-ld`, an FHS environment, or `xcross setup`.

## Quick start

`flake.nix` in a Flutter project:

```nix
{
  inputs = {
    xcross.url = "github:arxdeus/xcross";
    nixpkgs.follows = "xcross/nixpkgs";
  };

  outputs =
    { nixpkgs, xcross, ... }:
    let
      system = "x86_64-linux"; # or aarch64-linux
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = xcross.lib.mkXcrossShell {
        inherit pkgs;
        flutter = pkgs.flutter;
      };
    };
}
```

```sh
nix develop
xcross sdk install ~/Downloads/Xcode.xip   # once, see below
xcross flutter run
```

With direnv: `printf 'use flake\n' > .envrc && direnv allow`. Commit
`flake.nix` and `flake.lock`.

`nixpkgs.follows = "xcross/nixpkgs"` is recommended: it reuses the package set
xcross is tested with. Without it everything is rebuilt against your nixpkgs,
which also works.

## Host configuration

For USB devices, enable usbmuxd, which also installs the Apple udev rule. USB is
needed for the first pairing even if later runs use Wi-Fi.

```nix
{ services.usbmuxd.enable = true; }
```

## `mkXcrossShell`

```nix
xcross.lib.mkXcrossShell {
  pkgs = ...;             # required: the package set to build in
  flutter = pkgs.flutter; # required: the Flutter SDK
  jdk = pkgs.jdk21;       # optional: JDK 21+, needed for Compose
  xcross = ...;           # optional: a different xcross package
  settings = { ... };     # optional: merged over the default configuration
  packages = [ ... ];     # optional: extra shell packages
  shellHook = "...";      # optional
  # any other attribute is passed to pkgs.mkShell
}
```

The shell contains xcross, xcrun, the Swift toolchain, LLVM/LLD,
`pymobiledevice3`, the device tools, Flutter and the JDK. It exports
`XCROSS_CONFIG`, `FLUTTER_ROOT`, `SWIFT_EXEC`, `SWIFT_EXEC_MANIFEST`, and
`JAVA_HOME` when `jdk` is set. The generated configuration is also available
as `shell.passthru.xcrossConfig`.

To build only the configuration (for example for a home-manager
`home.sessionVariables.XCROSS_CONFIG`), use `xcross.lib.mkXcrossConfig` with the
same arguments minus the shell ones. `xcross.lib.mkXcrossSettings` returns the
merged attribute set.

## Default configuration

Inspect it with `cat "$XCROSS_CONFIG"` (JSON, which is valid YAML). It sets:

| Key | Default | Why |
|---|---|---|
| `roots.xcross` | `<xcross>/bin/xcross` | IDE run configurations, the DAP server and nested runs re-launch this path. It must be the wrapper, not the unwrapped binary under `libexec/`. |
| `roots.flutterSdk` | `flutter` | |
| `roots.javaHome` | `jdk.home` | Only when `jdk` is given. |
| `tools.flutter` | `<flutter>/bin/flutter` | |
| `tools.xcrun` | `<xcross>/bin/xcrun` | Otherwise resolved beside the running binary, which is the unwrapped copy. |
| `toolchains.swift` | the Swift toolchain | |
| `toolchains.llvm` | Swift's clang/lld, LLVM, LLD | Swift's own clang comes first: it is unwrapped and can target iOS. |
| `environment` | `SWIFT_EXEC`, `SWIFT_EXEC_MANIFEST`, `CC`, `CXX`, `FLUTTER_ROOT` | Pins the compilers so an ambient (cc-wrapper) clang is never picked for Apple targets. |
| `excluded_commands` | `config`, `setup`, `update` | These modify host packages, the config file or the installation, all of which Nix owns. |

Mutable data keeps the xcross defaults outside the store: the Darwin SDK under
`${XDG_CONFIG_HOME:-~/.config}/xcross/swift-sdks`, caches under
`${XDG_CACHE_HOME:-~/.cache}/xcross`, Kotlin/Native under `~/.konan`.

## Overriding

`settings` is merged with `lib.recursiveUpdate`: attribute sets merge, lists
and strings replace, and `null` removes a default. Values may reference
environment variables (`$HOME`, `${XDG_DATA_HOME}`), which xcross expands when
it loads the file.

```nix
xcross.lib.mkXcrossShell {
  inherit pkgs;
  flutter = pkgs.flutter;
  jdk = pkgs.jdk21;
  settings = {
    roots = {
      darwinSdk = "$HOME/apple/xcross-darwin.artifactbundle";
      konanData = "$PWD/.konan";
    };
    # Allow `xcross config show` again.
    excluded_commands = [ "setup" "update" ];
    # Drop a default entirely.
    tools.flutter = null;
  };
  packages = [ pkgs.cocoapods ];
}
```

To pin a different Flutter, pass any derivation that contains `bin/flutter`,
for example `flutter = pkgs.flutter338;`.

To try a local xcross build, override the package:

```nix
xcross = xcross.packages.${system}.xcross.overrideAttrs { src = ./xcross-linux-x64.tar.gz; };
```

## Other outputs

| Output | Purpose |
|---|---|
| `packages.<system>.xcross` (`default`) | The wrapped CLI, for `nix run github:arxdeus/xcross` or `environment.systemPackages`. |
| `packages.<system>.swiftToolchain` | The patched swift.org toolchain. |
| `packages.<system>.pymobiledevice3` | pymobiledevice3, see `setup/nix/pymobiledevice3/README.md`. |
| `overlays.default` | Adds `pkgs.xcross`. |
| `devShells.<system>.default` | `mkXcrossShell` with nixpkgs' Flutter and JDK 21. |
| `devShells.<system>.contributor` | Dart, Swift, LLVM and build tools for working on xcross itself. |

The xcross package on its own sets `SWIFT_EXEC`, `CC` and friends with
`--set-default`, so `nix run` works without a configuration file, and an
explicit configuration or environment still wins.

## How the package works on NixOS

- **xcross and xcrun** are Dart AOT executables: an ELF runtime followed by the
  compiled snapshot. Plain `patchelf` moves data the trailing snapshot offset
  points to, and the binary then prints the `dartvm` usage text instead of
  running. `setup/nix/patch-dart-aot.py` patches only the runtime and
  re-appends the snapshot.
- **Swift** is the upstream Ubuntu 24.04 build, patched with
  `autoPatchelfHook`. A clang config file for the Linux triple
  (`bin/<triple>.cfg`) points host compiles and links (SwiftPM manifests and
  plugins) at the store glibc, GCC runtime, loader, and LLD. Apple targets
  don't read it.
- **pymobiledevice3** in nixpkgs is too old for Wi-Fi tunnels (`remotepairing`)
  and its `pyimg4` is marked broken. It is packaged in `setup/nix/pymobiledevice3`.

## Darwin SDK

Download a full `Xcode.xip` (for example from
[xcodereleases.com](https://xcodereleases.com/)) and import it from the shell:

```sh
xcross sdk install ~/Downloads/Xcode.xip
```

The SDK is tied to the Swift toolchain. Re-run `sdk install` when a flake
update changes the Swift version. The SDK is Apple-licensed: keep it out of
the store, binary caches and git.

## Updating

```sh
nix flake update xcross
```

`xcross update` is excluded because the store is read-only. Maintainers bump
the release in `setup/nix/sources.nix`. The `Nix` workflow builds every check
and a consumer shell on both architectures.
