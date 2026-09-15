# pymobiledevice3 (vendored)

Packaging for [`pymobiledevice3`](https://github.com/doronz88/pymobiledevice3),
the Python CLI that `dart_mobile_device` shells out to.

## Why this is vendored rather than taken from nixpkgs

nixpkgs lags several major versions behind upstream, and its copy no longer
builds:

- **`pyimg4` is marked broken** in nixpkgs because it requires `asn1 < 3` while
  nixpkgs ships `asn1` 3.x. Relaxing the bound (the previous workaround here)
  does not fix it — pyimg4's own offline test suite fails 5/7 against asn1 3.x
  (`asn1.core.Error: ... Get <class 'list'>` and `Expected tag of type
  IA5String, got PrintableString`). This packaging pins `asn1` 2.8.0, which
  makes those tests pass.
- **`qh3` 2.x is incompatible**: 2.0 removed `qh3.quic.packet_builder`, which
  pymobiledevice3 imports to clamp the QUIC datagram size to the device MTU.
  Pinned to 1.9.4.
- **Missing dependencies**: `pmd-pytcp` (the no-root userspace tunnel behind
  `--userspace`), `pyiosbackup`, `ASGIMiddlewareStaticFile`, and `asgiwebdav`
  are not in nixpkgs at all.

## Layout

| File | Purpose |
| --- | --- |
| `package.nix` | the `pymobiledevice3` derivation (pin the version + `src.hash` here) |
| `overrides.nix` | Python `packageOverrides`: the pinned versions and the missing packages |
| `qh3.nix`, `asn1.nix` | pinned dependency derivations |
| `pmd-net-addr.nix`, `pmd-net-proto.nix`, `pmd-pytcp.nix` | userspace tunnel stack |
| `pyiosbackup.nix` | backup unpacking |
| `asgimiddlewarestaticfile.nix`, `asgiwebdav.nix` | WebDAV |

The flake wires this in through `pymobiledevice3Overlay` and builds both the
package and a `python313.withPackages` env (`pymobiledevice3Env`), because
`Pymd.tunneldInvocation()` probes for a python that can `import
pymobiledevice3` — a plain interpreter cannot import a `buildPythonPackage`
output.

## Updating

1. Bump `version` in `package.nix`.
2. `nix build .#pymobiledevice3`; copy the `got:` hash from the mismatch error
   into `src.hash`.
3. Diff upstream `pyproject.toml`'s `dependencies` against `package.nix` and
   update `overrides.nix` if a dependency moved or a new one appeared.
4. Re-check the pins in `overrides.nix` (last verified against upstream
   11.12.5).
