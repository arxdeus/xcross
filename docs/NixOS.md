# NixOS

xcross provides Linux packages and development shells for `x86_64-linux` and
`aarch64-linux`. A project consuming the xcross flake should own the xcross
configuration because Flutter, Java, writable cache locations, and policy such
as disabled commands belong to the project environment, not to the xcross
package.

## Design

The integration has two layers:

- The xcross flake provides the xcross release, Swift, LLVM, device tools,
  Python, and `pymobiledevice3`.
- The consumer flake provides Flutter, Java, `XCROSS_CONFIG`, and writable
  project or user roots.

The xcross package exposes these attributes for composing the consumer config:

- `xcross.packages.${system}.default`
- `xcross.packages.${system}.default.swiftToolchain`
- `xcross.packages.${system}.default.swiftCompiler`
- `xcross.devShells.${system}.default`

Use `inputsFrom` to inherit the xcross runtime dependencies. Make the consumer's
`nixpkgs` input follow `xcross/nixpkgs` so packages and toolchain paths come from
the same pinned package set.

The configuration is immutable in the Nix store, but it may contain environment
references such as `$HOME`. xcross expands those references when it loads the
configuration. This keeps compiler and SDK paths reproducible while keeping
mutable Apple SDK and Kotlin/Native data outside `/nix/store`.

## NixOS host configuration

The Swift release used by xcross is an upstream Linux binary distribution. On
NixOS, enable `nix-ld` so those binaries can use their expected dynamic loader.
Enable the system `usbmuxd` service when connecting iPhones over USB:

```nix
{ ... }:
{
  programs.nix-ld.enable = true;
  services.usbmuxd.enable = true;
}
```

Apply the system configuration before entering the project shell:

```sh
sudo nixos-rebuild switch
```

`services.usbmuxd` also installs the Apple USB udev rule. The service is not
required for a workflow that never uses USB, but USB is normally needed for the
initial device pairing even when later runs use Wi-Fi.

## Consumer flake

Add this `flake.nix` to the Flutter project:

```nix
{
  description = "Flutter iOS development with xcross";

  inputs = {
    xcross.url = "github:arxdeus/xcross";
    nixpkgs.follows = "xcross/nixpkgs";
  };

  outputs =
    { nixpkgs, xcross, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      eachSystem = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = eachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          xcrossPackage = xcross.packages.${system}.default;
          inherit (xcrossPackage) swiftToolchain swiftCompiler;

          xcrossConfig = pkgs.writeText "xcross-config.yaml" (builtins.toJSON {
            roots = {
              darwinSdk = "$XCROSS_DARWIN_BUNDLE";
              flutterSdk = "${pkgs.flutter}";
              xcross = "${xcrossPackage}/bin/xcross";
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

            excluded_commands = [
              "config"
              "setup"
            ];

            environment = {
              SWIFT_EXEC = "${swiftCompiler}";
              SWIFT_EXEC_MANIFEST = "${swiftCompiler}";
              CC = "${swiftToolchain}/bin/clang";
              CXX = "${swiftToolchain}/bin/clang++";
              FLUTTER_ROOT = "${pkgs.flutter}";
            };
          });
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [ xcross.devShells.${system}.default ];

            packages = [
              pkgs.flutter
              pkgs.jdk
            ];

            XCROSS_CONFIG = xcrossConfig;
            FLUTTER_ROOT = "${pkgs.flutter}";
            JAVA_HOME = "${pkgs.jdk.home}";

            shellHook = ''
              export XCROSS_DARWIN_BUNDLE="''${XCROSS_DARWIN_BUNDLE:-''${XDG_CONFIG_HOME:-$HOME/.config}/xcross/swift-sdks/xcross-darwin.artifactbundle}"
              export KONAN_DATA_DIR="''${KONAN_DATA_DIR:-$HOME/.konan}"
            '';
          };
        }
      );
    };
}
```

Run the shell:

```sh
nix develop
```

For automatic activation with direnv:

```sh
printf 'use flake\n' > .envrc
direnv allow
```

Commit both `flake.nix` and `flake.lock` to the project.

## Why the consumer owns the config

`XCROSS_CONFIG` selects the exact configuration file loaded by xcross. Defining
it in the consumer shell has several benefits:

- The project selects its Flutter and Java versions.
- All executable and toolchain paths resolve to the consumer's Nix store paths.
- Writable paths follow the user's home or project policy.
- Multiple projects may use different xcross configurations simultaneously.
- The xcross package remains reusable and does not override an explicit
  consumer configuration.

The example disables `xcross config` and `xcross setup`. Those commands mutate
or install host state and should not manage a declarative Nix environment.
Configuration changes belong in the consumer flake, and dependencies belong in
`packages` or `inputsFrom`.

`xcross sdk install` remains available because importing an Apple SDK is a
separate operation that writes private, non-redistributable data to the
configured `roots.darwinSdk` location.

## Roots

The example configures these roots:

| Root | Value | Mutability |
|---|---|---|
| `flutterSdk` | `${pkgs.flutter}` | Immutable Nix store path |
| `xcross` | `${xcrossPackage}/bin/xcross` | Immutable Nix store path |
| `javaHome` | `${pkgs.jdk.home}` | Immutable Nix store path |
| `darwinSdk` | `$XCROSS_DARWIN_BUNDLE` | Writable user path |
| `konanData` | `$KONAN_DATA_DIR` | Writable user path |

By default, the Darwin artifact bundle is stored at:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/xcross/swift-sdks/xcross-darwin.artifactbundle
```

Kotlin/Native data defaults to:

```text
$HOME/.konan
```

Override either location before entering the shell or through direnv:

```sh
export XCROSS_DARWIN_BUNDLE="$PWD/.xcross/xcross-darwin.artifactbundle"
export KONAN_DATA_DIR="$PWD/.xcross/konan"
nix develop
```

Do not place these writable roots in `/nix/store`.

## Toolchains and dependencies

`inputsFrom = [ xcross.devShells.${system}.default ]` supplies:

- xcross and xcrun
- the matching Swift toolchain
- LLVM and LLD
- Python and `pymobiledevice3`
- `usbmuxd`, `libimobiledevice`, and USB utilities
- Git, pkg-config, and GnuPG

The consumer adds Flutter and Java because those versions are application
choices. Add other project tools to `packages`, for example:

```nix
packages = [
  pkgs.flutter
  pkgs.jdk
  pkgs.cmake
  pkgs.ninja
];
```

The Swift compiler wrapper is intentional. `swiftCompiler` invokes the selected
Swift compiler with LLD, and both `SWIFT_EXEC` and `SWIFT_EXEC_MANIFEST` must
refer to that same wrapper. Keep the Swift and LLVM directories from the xcross
package rather than independently selecting incompatible toolchains.

## Preparing the Darwin SDK

Download a complete `Xcode.xip` from
[xcodereleases.com](https://xcodereleases.com/), then import it from the Nix
shell:

```sh
nix develop
xcross sdk install ~/Downloads/Xcode.xip
```

The resulting Darwin SDK is tied to the configured Swift toolchain. Re-import
the SDK after changing the xcross input or any input that changes
`swiftToolchain`.

The imported SDK is Apple-licensed material. Keep it private and do not commit,
cache publicly, or copy it into a Nix derivation.

## Verification

Inside `nix develop`, verify the selected environment:

```sh
printf '%s\n' "$XCROSS_CONFIG"
test -f "$XCROSS_CONFIG"
test -x "$SWIFT_EXEC"
test "$SWIFT_EXEC" = "$SWIFT_EXEC_MANIFEST"
test -x "$FLUTTER_ROOT/bin/flutter"
xcross --help
```

`xcross --help` should not list `config` or `setup`. Running either command
should report that the command does not exist.

To inspect the generated configuration:

```sh
cat "$XCROSS_CONFIG"
```

The file is JSON, which is valid YAML and is accepted by xcross.

## Updating

Update the pinned xcross and nixpkgs inputs together:

```sh
nix flake update
nix flake check
```

After an update, enter a fresh shell and verify Swift, Flutter, and xcross again.
If the Swift store path changed, rebuild the Darwin SDK with `xcross sdk install`.
Do not use `xcross update` for a Nix-managed installation. Update the flake input
instead.
