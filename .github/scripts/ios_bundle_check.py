#!/usr/bin/env python3
"""Checks icons, Assets.car, launch screen and entitlements of a built iOS app.

Usage:
  ios_bundle_check.py <app|ipa> [--expect-entitlements key ...]
      [--expect-launch-image NAME] [--expect-icon NAME] [--no-private-keys]
      [--no-loose-dylibs] [--expect-device-family 1,2]
      [--expect-framework-file PATH ...]
  ios_bundle_check.py add-entitlements <ios-dir>   (CI fixture helper)
"""
import argparse
import io
import os
import plistlib
import re
import struct
import sys
import zipfile

PRIVATE_KEYS = ("XCrossEntitlements", "XCrossCapabilities")


class Bundle:
    """Read-only view over a .app directory or an .ipa archive."""

    def __init__(self, path):
        self.zip = None
        if os.path.isdir(path):
            self.root = path
            self.names = []
            for d, _, fs in os.walk(path):
                for f in fs:
                    rel = os.path.relpath(os.path.join(d, f), path)
                    self.names.append(rel.replace(os.sep, "/"))
        else:
            self.zip = zipfile.ZipFile(path)
            apps = sorted({m.group(1) for n in self.zip.namelist()
                           if (m := re.match(r"(Payload/[^/]+\.app)/", n))})
            if len(apps) != 1:
                raise ValueError(f"expected one Payload/*.app in ipa, found {apps}")
            self.root = apps[0]
            prefix = self.root + "/"
            self.names = [n[len(prefix):] for n in self.zip.namelist()
                          if n.startswith(prefix) and not n.endswith("/")]

    def has(self, name):
        return name in self.names

    def exists(self, name):
        return (name in self.names or
                any(n.startswith(name + "/") for n in self.names))

    def links(self):
        """(relative path, target) of every symlink; zips store none."""
        if self.zip:
            return []
        found = []
        for d, dirs, fs in os.walk(self.root):
            for f in dirs + fs:
                full = os.path.join(d, f)
                if os.path.islink(full):
                    rel = os.path.relpath(full, self.root).replace(os.sep, "/")
                    found.append((rel, os.readlink(full)))
        return found

    def read(self, name):
        if self.zip:
            return self.zip.read(self.root + "/" + name)
        with open(os.path.join(self.root, *name.split("/")), "rb") as f:
            return f.read()


def png_size(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", data[16:24])


def entitlements_from_macho(data):
    """Returns the entitlements dict embedded in a (thin) arm64 Mach-O."""
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic == 0xBEBAFECA:  # fat, big-endian header
        n = struct.unpack_from(">I", data, 4)[0]
        off, size = struct.unpack_from(">II", data, 8 + 4 * 2)[0:2] if n else (0, 0)
        data = data[off:off + size]
        magic = struct.unpack_from("<I", data, 0)[0]
    if magic != 0xFEEDFACF:
        raise ValueError("not a 64-bit little-endian Mach-O")
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x1D:
            dataoff, datasize = struct.unpack_from("<II", data, off + 8)
            return entitlements_from_superblob(data[dataoff:dataoff + datasize])
        off += size
    raise ValueError("no LC_CODE_SIGNATURE")


def entitlements_from_superblob(blob):
    magic, _length, count = struct.unpack_from(">III", blob, 0)
    if magic != 0xFADE0CC0:
        raise ValueError("bad code signature SuperBlob magic")
    for i in range(count):
        slot, off = struct.unpack_from(">II", blob, 12 + 8 * i)
        if slot == 5:
            bmagic, blen = struct.unpack_from(">II", blob, off)
            if bmagic != 0xFADE7171:
                raise ValueError("bad entitlements blob magic")
            return plistlib.loads(blob[off + 8:off + blen])
    raise ValueError("no entitlements slot in code signature")


def check(path, entitlements=(), launch_image=None, icon=None,
          private_keys_absent=False, expect_bundle_files=(), no_ib_sources=False,
          expect_lf=(), no_loose_dylibs=False, expect_device_family=None,
          expect_framework_file=()):
    errors, notes = [], []
    b = Bundle(path)
    try:
        info = plistlib.loads(b.read("Info.plist"))
    except Exception as e:
        return [f"Info.plist unreadable: {e}"], notes

    if icon:
        files = (info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {})
                 .get("CFBundleIconFiles", []))
        if f"{icon}60x60" not in files:
            errors.append(f"CFBundleIconFiles lacks {icon}60x60: {files}")
        got = info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get(
            "CFBundleIconName")
        top = info.get("CFBundleIconName")
        if icon not in (got, top):
            errors.append(f"CFBundleIconName != {icon}")
        ipad = (info.get("CFBundleIcons~ipad", {}).get("CFBundlePrimaryIcon", {})
                .get("CFBundleIconFiles", []))
        if f"{icon}76x76" not in ipad:
            errors.append(f"CFBundleIcons~ipad lacks {icon}76x76: {ipad}")
        # Exactly what actool writes loose for a deployment target >= 11.
        for name, px in ((f"{icon}60x60@2x.png", 120),
                         (f"{icon}76x76@2x~ipad.png", 152)):
            if not b.has(name):
                errors.append(f"missing {name}")
            elif png_size(b.read(name)) != (px, px):
                errors.append(f"{name} is not a {px}x{px} PNG")
        if b.has(f"{icon}60x60@3x.png"):
            errors.append(f"unexpected {icon}60x60@3x.png (actool omits it)")
        notes.append("icons ok")

    if b.has("Assets.car"):
        if b.read("Assets.car")[:8] != b"BOMStore":
            errors.append("Assets.car is not a BOM file")
    else:
        errors.append("missing Assets.car")

    if launch_image:
        sb = info.get("UILaunchStoryboardName")
        ls = info.get("UILaunchScreen")
        if sb:
            # Native (ibtool) layout: the compiled storyboard lives in the
            # bundle root or a localization directory, as Xcode places it.
            compiled = [n for n in b.names
                        if re.match(rf"(?:[^/]+\.lproj/)?{re.escape(sb)}"
                                    rf"\.storyboardc/", n)]
            needed = {"Info.plist"}
            have = {n.split(".storyboardc/", 1)[1] for n in compiled}
            if not compiled:
                errors.append(f"UILaunchStoryboardName={sb} without compiled storyboard")
            elif not needed <= have or not any(h.endswith(".nib") for h in have):
                errors.append(f"{sb}.storyboardc is incomplete: {sorted(have)}")
            notes.append(f"launch storyboard compiled: {sorted(set(compiled))}")
        elif not isinstance(ls, dict):
            errors.append("missing UILaunchStoryboardName and UILaunchScreen")
        else:
            if ls.get("UIImageName") != launch_image:
                errors.append(f"UILaunchScreen.UIImageName != {launch_image}: {ls}")
            if not isinstance(ls.get("UIColorName"), str) or not ls["UIColorName"]:
                errors.append("UILaunchScreen.UIColorName missing")
        notes.append("launch screen checked")

    if expect_device_family is not None:
        got = info.get("UIDeviceFamily")
        if got != list(expect_device_family):
            errors.append(f"UIDeviceFamily {got} != {list(expect_device_family)}")
    if no_loose_dylibs:
        for n in b.names:
            if n.endswith(".dylib"):
                errors.append(f"{n} is a loose dylib (ITMS-90171)")
    for name in expect_framework_file:
        if not b.has(name):
            errors.append(f"missing {name}")
        elif not b.read(name):
            errors.append(f"{name} is empty")
    errors.extend(check_frameworks(b, notes))

    if private_keys_absent:
        for k in PRIVATE_KEYS:
            if k in info:
                errors.append(f"Info.plist leaks private key {k}")

    if entitlements:
        exe = info.get("CFBundleExecutable", "Runner")
        try:
            ents = entitlements_from_macho(b.read(exe))
            for k in entitlements:
                if k not in ents:
                    errors.append(f"entitlement {k} missing; have {sorted(ents)}")
            notes.append(f"entitlements: {sorted(ents)}")
        except Exception as e:
            errors.append(f"entitlements unreadable in {exe}: {e}")

    errors.extend(check_resource_bundles(b, expect_bundle_files, notes,
                                           no_ib_sources, expect_lf))
    return errors, notes


MACHO_MAGICS = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
                b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}


def check_frameworks(b, notes):
    """Every Frameworks/*.framework is a real FMWK with a Mach-O executable."""
    errors = []
    fws = sorted({m.group(1) for n in b.names
                  if (m := re.match(r"(Frameworks/[^/]+\.framework)/", n))})
    for fw in fws:
        try:
            info = plistlib.loads(b.read(f"{fw}/Info.plist"))
        except Exception as e:
            errors.append(f"{fw}/Info.plist unreadable: {e}")
            continue
        if info.get("CFBundlePackageType") != "FMWK":
            errors.append(f"{fw} Info.plist is not an FMWK")
        exe = info.get("CFBundleExecutable")
        if not exe or not b.has(f"{fw}/{exe}"):
            errors.append(f"{fw} executable {exe!r} missing")
        elif b.read(f"{fw}/{exe}")[:4] not in MACHO_MAGICS:
            errors.append(f"{fw}/{exe} is not a Mach-O")
    notes.append(f"frameworks: {len(fws)}")
    return errors


def check_resource_bundles(b, expect_bundle_files, notes, no_ib_sources=False,
                           expect_lf=()):
    """Top-level `*.bundle` resource bundles must look like Xcode's: a BNDL
    Info.plist and no symlink that leaves the bundle or dangles."""
    errors = []
    bundles = sorted({n.split("/", 1)[0] for n in b.names
                      if "/" in n and n.split("/", 1)[0].endswith(".bundle")})
    for bundle in bundles:
        if not b.has(f"{bundle}/Info.plist"):
            errors.append(f"{bundle} has no Info.plist")
            continue
        try:
            info = plistlib.loads(b.read(f"{bundle}/Info.plist"))
        except Exception as e:
            errors.append(f"{bundle}/Info.plist unreadable: {e}")
            continue
        if info.get("CFBundlePackageType") != "BNDL":
            errors.append(f"{bundle} Info.plist is not a BNDL")
        if not info.get("CFBundleIdentifier"):
            errors.append(f"{bundle} Info.plist has no CFBundleIdentifier")
    for link, target in b.links():
        top = link.split("/", 1)[0]
        resolved = os.path.normpath(os.path.join(os.path.dirname(link), target))
        resolved = resolved.replace(os.sep, "/")
        inside = (not os.path.isabs(target) and
                  (resolved == top or resolved.startswith(top + "/")))
        if top.endswith(".bundle") and not inside:
            errors.append(f"{link} links outside its bundle: {target}")
        elif not b.exists(resolved):
            errors.append(f"{link} is a dangling link: {target}")
    if no_ib_sources:
        for n in b.names:
            if n.split("/", 1)[0] in bundles and n.endswith((".xib", ".storyboard")):
                errors.append(f"{n} is uncompiled Interface Builder source")
    dir_nibs = {}
    for n in b.names:
        top = n.split("/", 1)[0]
        if top not in bundles:
            continue
        m = re.match(r"(.*?\.nib)/(.+)", n)
        if m:
            dir_nibs.setdefault(m.group(1), []).append(m.group(2))
        elif n.endswith(".nib"):
            data = b.read(n)
            if not data:
                errors.append(f"{n} is empty")
            elif not data.startswith(b"NIBArchive"):
                errors.append(f"{n} lacks the NIBArchive magic")
    for nib, inner in sorted(dir_nibs.items()):
        if not any(i == "runtime.nib" or re.fullmatch(r"objects-.*\.nib", i)
                   for i in inner):
            errors.append(f"{nib} has no runtime.nib or objects-*.nib")
    for name in expect_bundle_files:
        if not b.has(name):
            errors.append(f"missing {name}")
        elif not b.read(name):
            errors.append(f"{name} is empty")
    if expect_lf:
        # Upstream packages ship these as LF; a Windows checkout with
        # core.autocrlf would turn them into CRLF, which Xcode never does.
        for n in expect_lf:
            if b.has(n) and b"\r\n" in b.read(n):
                errors.append(f"{n} has CRLF line endings")
    notes.append(f"resource bundles: {len(bundles)}")
    return errors


FIXTURE = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>aps-environment</key>
\t<string>development</string>
\t<key>com.apple.developer.associated-domains</key>
\t<array>
\t\t<string>applinks:example.com</string>
\t</array>
</dict>
</plist>
"""


def add_entitlements(ios_dir):
    with open(os.path.join(ios_dir, "Runner", "Runner.entitlements"), "w") as f:
        f.write(FIXTURE)
    pbx = os.path.join(ios_dir, "Runner.xcodeproj", "project.pbxproj")
    with open(pbx) as f:
        text = f.read()
    # Runner target configs are the ones with the app bundle identifier.
    pat = re.compile(r"(\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = [^;]*;\n)")
    def sub(m):
        line = m.group(1)
        if ".RunnerTests" in line:
            return line
        return "\t\t\t\tCODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;\n" + line
    new = pat.sub(sub, text)
    if new == text:
        raise SystemExit("::error::no Runner build configuration patched")
    with open(pbx, "w") as f:
        f.write(new)


def main(argv):
    if argv and argv[0] == "add-entitlements":
        add_entitlements(argv[1])
        return 0
    p = argparse.ArgumentParser()
    p.add_argument("path")
    p.add_argument("--expect-entitlements", nargs="*", default=[])
    p.add_argument("--expect-launch-image")
    p.add_argument("--expect-icon")
    p.add_argument("--no-private-keys", action="store_true")
    p.add_argument("--expect-bundle-file", nargs="*", default=[])
    p.add_argument("--no-ib-sources", action="store_true")
    p.add_argument("--expect-lf", nargs="*", default=[])
    p.add_argument("--no-loose-dylibs", action="store_true")
    p.add_argument("--expect-device-family",
                   type=lambda v: [int(x) for x in v.split(",")])
    p.add_argument("--expect-framework-file", nargs="*", default=[])
    a = p.parse_args(argv)
    errors, notes = check(a.path, a.expect_entitlements, a.expect_launch_image,
                          a.expect_icon, a.no_private_keys,
                          a.expect_bundle_file, a.no_ib_sources, a.expect_lf,
                          a.no_loose_dylibs, a.expect_device_family,
                          a.expect_framework_file)
    for n in notes:
        print(n)
    for e in errors:
        print(f"::error::{a.path}: {e}")
    print("FAILED" if errors else "OK")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
