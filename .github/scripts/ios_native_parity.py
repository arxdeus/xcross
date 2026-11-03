#!/usr/bin/env python3
"""Diffs a cross-built iOS .app/.ipa against a native (Xcode) reference.

Usage: ios_native_parity.py <native .app|.ipa> <cross .app|.ipa> [--report out.md]

Pure Python 3 stdlib. Uses `xcrun assetutil` for Assets.car only when it is
available (macOS), otherwise compares Assets.car by size.

Exit code: 0 when there are no errors, 1 when errors were found, 2 on usage
problems.
"""

import argparse
import fnmatch
import hashlib
import json
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

ERROR, WARNING, INFO = "error", "warning", "info"
SEVERITIES = (ERROR, WARNING, INFO)

IGNORED_PATTERNS = (
    "_CodeSignature", "_CodeSignature/*", "*/_CodeSignature", "*/_CodeSignature/*",
    "embedded.mobileprovision", "*/embedded.mobileprovision",
    "*.dSYM", "*.dSYM/*", "*/.DS_Store", ".DS_Store",
    "archived-expanded-entitlements.xcent",
)

# Host/toolchain keys that never matter for parity.
ALWAYS_IGNORED_KEYS = {"BuildMachineOSBuild"}
# Only compared when both sides have them.
BOTH_ONLY_KEYS = {"DTXcode", "DTXcodeBuild"}
# SDK identity keys: ignored when the SDKs differ (reported once as info).
SDK_KEYS = {
    "DTCompiler", "DTPlatformBuild", "DTPlatformName", "DTPlatformVersion",
    "DTSDKBuild", "DTSDKName", "CFBundleSupportedPlatforms",
}
CRITICAL_KEYS = {
    "CFBundleIdentifier", "CFBundleExecutable", "CFBundlePackageType",
    "MinimumOSVersion", "UIDeviceFamily", "CFBundleShortVersionString",
    "CFBundleVersion", "CFBundleName", "CFBundleDisplayName", "CFBundleIcons",
    "CFBundleIcons~ipad", "UILaunchStoryboardName", "UIMainStoryboardFile",
    "UIApplicationSceneManifest", "UIRequiredDeviceCapabilities",
    "NSPrincipalClass", "CFBundleURLTypes", "LSRequiresIPhoneOS",
    "UISupportedInterfaceOrientations", "UIBackgroundModes",
}

BYTE_EXACT_EXT = {
    ".xcprivacy": ERROR, ".strings": WARNING, ".stringsdict": WARNING,
    ".nib": WARNING, ".ttf": ERROR, ".otf": ERROR, ".ttc": ERROR,
    ".png": WARNING, ".jpg": WARNING, ".jpeg": WARNING, ".gif": WARNING,
    ".pdf": WARNING, ".json": WARNING, ".bin": WARNING,
}

MH_FILETYPES = {1: "MH_OBJECT", 2: "MH_EXECUTE", 6: "MH_DYLIB", 8: "MH_BUNDLE",
                9: "MH_DYLIB_STUB", 0xB: "MH_KEXT_BUNDLE"}
PLATFORMS = {1: "macos", 2: "ios", 3: "tvos", 4: "watchos", 6: "maccatalyst",
             7: "iossimulator", 8: "tvossimulator", 9: "watchossimulator",
             11: "visionos", 12: "visionossimulator"}
CPU = {0x0100000C: "arm64", 0x01000007: "x86_64", 12: "arm", 7: "i386",
       0x0200000C: "arm64_32"}

LC_LOAD_DYLIB, LC_ID_DYLIB, LC_LOAD_WEAK_DYLIB = 0xC, 0xD, 0x80000018
LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB = 0x8000001F, 0x20
LC_RPATH, LC_CODE_SIGNATURE, LC_SEGMENT_64 = 0x8000001C, 0x1D, 0x19
LC_BUILD_VERSION, LC_VERSION_MIN_IPHONEOS = 0x32, 0x25


class Finding:
    def __init__(self, severity, category, path, message):
        self.severity, self.category, self.path, self.message = (
            severity, category, path, message)

    def __repr__(self):
        return "%s[%s] %s: %s" % (self.severity, self.category, self.path,
                                  self.message)


# ---------------------------------------------------------------- loading

def open_bundle(path, tmp):
    """Returns the .app directory for an .app, .ipa, or .xcarchive."""
    path = os.path.abspath(path)
    if os.path.isdir(path):
        if path.endswith(".xcarchive"):
            apps = os.path.join(path, "Products", "Applications")
            return os.path.join(apps, _single_app(os.listdir(apps), path))
        if path.endswith(".app"):
            return path
        # A directory containing Payload/ (unzipped ipa) or a single .app.
        payload = os.path.join(path, "Payload")
        base = payload if os.path.isdir(payload) else path
        return os.path.join(base, _single_app(os.listdir(base), path))
    if zipfile.is_zipfile(path):
        dest = tempfile.mkdtemp(dir=tmp)
        with zipfile.ZipFile(path) as z:
            for info in z.infolist():
                target = os.path.join(dest, info.filename)
                mode = (info.external_attr >> 16) & 0o170000
                if mode == 0o120000:  # symlink
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                    os.symlink(z.read(info).decode(), target)
                else:
                    z.extract(info, dest)
        payload = os.path.join(dest, "Payload")
        return os.path.join(payload, _single_app(os.listdir(payload), path))
    raise SystemExit("not an .app, .ipa or .xcarchive: %s" % path)


def _single_app(names, where):
    apps = [n for n in names if n.endswith(".app")]
    if len(apps) != 1:
        raise SystemExit("expected one .app in %s, found %s" % (where, apps))
    return apps[0]


def ignored(rel):
    return any(fnmatch.fnmatch(rel, p) for p in IGNORED_PATTERNS)


def inventory(root):
    """Maps relative path -> 'dir' | 'file' | 'link:<target>'."""
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            if ignored(rel):
                continue
            if os.path.islink(full):
                out[rel] = "link:" + os.readlink(full)
            elif os.path.isdir(full):
                out[rel] = "dir"
            else:
                out[rel] = "file"
    return out


def read(root, rel):
    with open(os.path.join(root, rel), "rb") as f:
        return f.read()


def load_plist(data):
    try:
        return plistlib.loads(data)
    except Exception:
        return None


# ---------------------------------------------------------------- Mach-O

def is_macho(data):
    if len(data) < 4:
        return False
    m = data[:4]
    return m in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe",
                 b"\xca\xfe\xba\xbf")


def macho_slices(data):
    """Yields (arch, thin_bytes) for fat or thin Mach-O."""
    magic = data[:4]
    if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        is64 = magic == b"\xca\xfe\xba\xbf"
        n = struct.unpack_from(">I", data, 4)[0]
        off = 8
        for _ in range(n):
            if is64:
                cpu, _sub, o, s = struct.unpack_from(">iiQQ", data, off)
                off += 32
            else:
                cpu, _sub, o, s = struct.unpack_from(">iiII", data, off)
                off += 20
            yield CPU.get(cpu & 0xFFFFFFFF, hex(cpu)), data[o:o + s]
    else:
        cpu = struct.unpack_from("<I", data, 4)[0]
        yield CPU.get(cpu, hex(cpu)), data


def _ver(v):
    s = "%d.%d" % (v >> 16, (v >> 8) & 0xFF)
    return s + (".%d" % (v & 0xFF) if v & 0xFF else "")


def _lc_str(data, off, size, stroff):
    raw = data[off + stroff:off + size]
    return raw.split(b"\0", 1)[0].decode("utf-8", "replace")


def parse_thin(data):
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic not in (0xFEEDFACF, 0xFEEDFACE):
        raise ValueError("not a little-endian Mach-O")
    is64 = magic == 0xFEEDFACF
    filetype, ncmds = struct.unpack_from("<II", data, 12)
    off = 32 if is64 else 28
    info = {"filetype": MH_FILETYPES.get(filetype, hex(filetype)),
            "platform": None, "minos": None, "sdk": None, "install_name": None,
            "dylibs": [], "weak_dylibs": [], "reexport_dylibs": [],
            "rpaths": [], "signed": False, "text_size": 0, "entitlements": None}
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == LC_BUILD_VERSION:
            plat, minos, sdk = struct.unpack_from("<III", data, off + 8)
            info["platform"] = PLATFORMS.get(plat, str(plat))
            info["minos"], info["sdk"] = _ver(minos), _ver(sdk)
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            v, sdk = struct.unpack_from("<II", data, off + 8)
            info["platform"], info["minos"], info["sdk"] = "ios", _ver(v), _ver(sdk)
        elif cmd in (LC_LOAD_DYLIB, LC_ID_DYLIB, LC_LOAD_WEAK_DYLIB,
                     LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB):
            name = _lc_str(data, off, size, struct.unpack_from("<I", data, off + 8)[0])
            key = {LC_ID_DYLIB: None, LC_LOAD_WEAK_DYLIB: "weak_dylibs",
                   LC_REEXPORT_DYLIB: "reexport_dylibs"}.get(cmd, "dylibs")
            if key is None:
                info["install_name"] = name
            else:
                info[key].append(name)
        elif cmd == LC_RPATH:
            info["rpaths"].append(
                _lc_str(data, off, size, struct.unpack_from("<I", data, off + 8)[0]))
        elif cmd == LC_SEGMENT_64:
            segname = data[off + 8:off + 24].split(b"\0", 1)[0]
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            if segname == b"__TEXT":
                for i in range(nsects):
                    s = off + 72 + 80 * i
                    sect = data[s:s + 16].split(b"\0", 1)[0]
                    if sect == b"__text":
                        info["text_size"] = struct.unpack_from("<Q", data, s + 40)[0]
        elif cmd == LC_CODE_SIGNATURE:
            info["signed"] = True
            dataoff, datasize = struct.unpack_from("<II", data, off + 8)
            try:
                info["entitlements"] = entitlements_from_superblob(
                    data[dataoff:dataoff + datasize])
            except Exception as e:  # noqa: BLE001
                info["entitlements_error"] = str(e)
        off += size
    for k in ("dylibs", "weak_dylibs", "reexport_dylibs"):
        info[k] = sorted(info[k])
    info["stub"] = info["text_size"] == 0
    return info


def entitlements_from_superblob(blob):
    """Returns the entitlements plist dict, or None if there is no slot."""
    if len(blob) < 12:
        return None
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
    return None


def macho_summary(data):
    return {arch: parse_thin(thin) for arch, thin in macho_slices(data)}


# ---------------------------------------------------------------- compare

class Comparer:
    def __init__(self, native, cross, use_assetutil=True):
        self.native, self.cross = native, cross
        self.findings = []
        self.stats = {}
        self.use_assetutil = use_assetutil and shutil.which("xcrun") is not None
        self.sdk_differs = False

    def add(self, severity, category, path, message):
        self.findings.append(Finding(severity, category, path, message))

    def run(self):
        ninv, cinv = inventory(self.native), inventory(self.cross)
        self.stats["native_entries"], self.stats["cross_entries"] = len(ninv), len(cinv)
        self.sdk_differs = self._detect_sdk_difference()
        self.compare_inventory(ninv, cinv)
        common = sorted(p for p in ninv if p in cinv)
        main_exe = self._main_executable()
        counted = {"plist": 0, "bytes": 0, "macho": 0, "assets": 0}
        for rel in common:
            if ninv[rel] != cinv[rel]:
                self.add(ERROR, "inventory", rel, "entry kind differs: native %s, cross %s"
                         % (ninv[rel], cinv[rel]))
                continue
            if ninv[rel] != "file":
                continue
            nd, cd = read(self.native, rel), read(self.cross, rel)
            base = os.path.basename(rel)
            ext = os.path.splitext(rel)[1].lower()
            if base == "Info.plist" or ext == ".plist" and base != "Info.plist":
                counted["plist"] += 1
                self.compare_plist(rel, nd, cd, is_info=base == "Info.plist")
            elif base == "Assets.car":
                counted["assets"] += 1
                self.compare_assets(rel, nd, cd)
            elif is_macho(nd) or is_macho(cd):
                counted["macho"] += 1
                self.compare_macho(rel, nd, cd, rel == main_exe)
            elif ext in BYTE_EXACT_EXT or base == "PkgInfo" or ".storyboardc/" in rel \
                    or ".nib/" in rel:
                counted["bytes"] += 1
                sev = BYTE_EXACT_EXT.get(ext, WARNING)
                if base == "PkgInfo":
                    sev = ERROR
                if nd != cd:
                    self.add(sev, "bytes", rel, "content differs (native %d B %s, cross %d B %s)"
                             % (len(nd), _sha(nd), len(cd), _sha(cd)))
            elif nd != cd:
                counted["bytes"] += 1
                self.add(INFO, "bytes", rel, "content differs (native %d B, cross %d B)"
                         % (len(nd), len(cd)))
        self.stats.update(counted)
        return self.findings

    def _main_executable(self):
        try:
            p = load_plist(read(self.native, "Info.plist")) or {}
            return p.get("CFBundleExecutable")
        except OSError:
            return None

    def _detect_sdk_difference(self):
        try:
            n = load_plist(read(self.native, "Info.plist")) or {}
            c = load_plist(read(self.cross, "Info.plist")) or {}
        except OSError:
            return False
        keys = ("DTSDKName", "DTSDKBuild", "DTPlatformName")
        differs = any(n.get(k) != c.get(k) for k in keys)
        if differs:
            self.add(INFO, "toolchain", "Info.plist", "SDKs differ (native %s, cross %s); "
                     "DT* SDK keys and CFBundleSupportedPlatforms are ignored"
                     % ({k: n.get(k) for k in keys}, {k: c.get(k) for k in keys}))
        return differs

    def compare_inventory(self, ninv, cinv):
        missing = sorted(set(ninv) - set(cinv))
        extra = sorted(set(cinv) - set(ninv))
        for rel in _collapse(missing):
            self.add(ERROR, "inventory", rel, "missing in cross build")
        for rel in _collapse(extra):
            self.add(WARNING, "inventory", rel, "extra in cross build")
        self.stats["missing"], self.stats["extra"] = len(missing), len(extra)

    def compare_plist(self, rel, nd, cd, is_info):
        n, c = load_plist(nd), load_plist(cd)
        if n is None or c is None:
            if nd != cd:
                self.add(WARNING, "plist", rel, "unparsable plist differs")
            return
        if not isinstance(n, dict) or not isinstance(c, dict):
            if n != c:
                self.add(WARNING, "plist", rel, "plist differs")
            return
        for key in sorted(set(n) | set(c)):
            if key in ALWAYS_IGNORED_KEYS:
                continue
            if key in BOTH_ONLY_KEYS and not (key in n and key in c):
                continue
            if self.sdk_differs and key in SDK_KEYS:
                continue
            nv, cv = n.get(key, _MISSING), c.get(key, _MISSING)
            if nv == cv:
                continue
            if key in CRITICAL_KEYS:
                sev = ERROR
            elif key.startswith("DT") or key in SDK_KEYS:
                sev = INFO
            else:
                sev = WARNING if is_info else INFO
            self.add(sev, "plist", rel, "%s: native %s, cross %s"
                     % (key, _short(nv), _short(cv)))

    def compare_assets(self, rel, nd, cd):
        if nd == cd:
            return
        if self.use_assetutil:
            ni, ci = _assetutil(self.native, rel), _assetutil(self.cross, rel)
            if ni is not None and ci is not None:
                na, ca = _asset_index(ni), _asset_index(ci)
                for k in sorted(set(na) - set(ca)):
                    self.add(ERROR, "assets", rel, "asset missing in cross: %s" % k)
                for k in sorted(set(ca) - set(na)):
                    self.add(WARNING, "assets", rel, "extra asset in cross: %s" % k)
                for k in sorted(set(na) & set(ca)):
                    if na[k] != ca[k]:
                        diff = {sk: (na[k].get(sk), ca[k].get(sk))
                                for sk in sorted(set(na[k]) | set(ca[k]))
                                if na[k].get(sk) != ca[k].get(sk)}
                        self.add(WARNING, "assets", rel, "asset %s differs (native, cross): %s"
                                 % (k, _short(diff)))
                return
        self.add(INFO, "assets", rel, "bytes differ (native %d B, cross %d B); "
                 "assetutil unavailable" % (len(nd), len(cd)))

    def compare_macho(self, rel, nd, cd, is_main):
        if not (is_macho(nd) and is_macho(cd)):
            self.add(ERROR, "macho", rel, "Mach-O on one side only")
            return
        try:
            ns, cs = macho_summary(nd), macho_summary(cd)
        except Exception as e:  # noqa: BLE001
            self.add(WARNING, "macho", rel, "parse failed: %s" % e)
            return
        if sorted(ns) != sorted(cs):
            self.add(ERROR, "macho", rel, "architectures: native %s, cross %s"
                     % (sorted(ns), sorted(cs)))
        for arch in sorted(set(ns) & set(cs)):
            n, c = ns[arch], cs[arch]
            tag = "%s (%s)" % (rel, arch)
            for key, sev in (("filetype", ERROR), ("platform", ERROR), ("minos", ERROR),
                             ("install_name", ERROR), ("stub", ERROR),
                             ("dylibs", ERROR), ("weak_dylibs", ERROR),
                             ("reexport_dylibs", ERROR), ("rpaths", WARNING),
                             ("sdk", INFO)):
                if n[key] != c[key]:
                    if isinstance(n[key], list):
                        miss = sorted(set(n[key]) - set(c[key]))
                        extra = sorted(set(c[key]) - set(n[key]))
                        short = (lambda x: x) if key == "rpaths" else os.path.basename
                        msg = "%s: %d missing %s, %d extra %s" % (
                            key, len(miss), [short(x) for x in miss],
                            len(extra), [short(x) for x in extra])
                    else:
                        msg = "%s: native %s, cross %s" % (key, n[key], c[key])
                    self.add(sev, "macho", tag, msg)
            if is_main:
                self.compare_entitlements(tag, n, c)

    def compare_entitlements(self, tag, n, c):
        ne, ce = n.get("entitlements") or {}, c.get("entitlements") or {}
        self.stats["native_entitlements"] = ne
        self.stats["cross_entitlements"] = ce
        if not n["signed"] or not c["signed"]:
            self.add(WARNING, "entitlements", tag, "code signature: native %s, cross %s"
                     % (n["signed"], c["signed"]))
        for key in sorted(set(ne) | set(ce)):
            nv, cv = ne.get(key, _MISSING), ce.get(key, _MISSING)
            if nv != cv:
                self.add(ERROR, "entitlements", tag, "%s: native %s, cross %s"
                         % (key, _short(nv), _short(cv)))


class _Missing:
    def __repr__(self):
        return "<absent>"


_MISSING = _Missing()


def _sha(b):
    return hashlib.sha256(b).hexdigest()[:12]


def _short(v, limit=300):
    s = repr(v)
    return s if len(s) <= limit else s[:limit] + "..."


def _collapse(paths):
    """Drops children of directories that are themselves listed."""
    out, last = [], None
    for p in paths:
        if last is not None and p.startswith(last + "/"):
            continue
        out.append(p)
        last = p
    return out


def _assetutil(root, rel):
    try:
        out = subprocess.run(["xcrun", "--sdk", "iphoneos", "assetutil", "--info",
                              os.path.join(root, rel)], capture_output=True,
                             timeout=120, check=True).stdout
        return json.loads(out)
    except Exception:  # noqa: BLE001
        return None


_ASSET_VOLATILE = {"Timestamp", "SHA1Digest", "SizeOnDisk", "NameIdentifier", "Authoring Tool",
                   "CoreUIVersion", "DumpToolVersion", "MainVersion", "SchemaVersion",
                   "StorageVersion", "ThinningParameters", "Key Format",
                   "AssetStorageVersion", "Platform", "PlatformVersion"}


def _asset_index(info):
    out = {}
    for entry in info:
        if not isinstance(entry, dict):
            continue
        if "AssetType" not in entry:
            continue
        key = "%s|%s|%s|%s|%s" % (entry.get("AssetType"), entry.get("Name"),
                                  entry.get("Scale"), entry.get("Idiom"),
                                  entry.get("PixelWidth"))
        out[key] = {k: v for k, v in entry.items() if k not in _ASSET_VOLATILE}
    return out


# ---------------------------------------------------------------- report

def render(findings, stats, native_label, cross_label):
    by = {s: [f for f in findings if f.severity == s] for s in SEVERITIES}
    lines = ["# iOS native parity report", "",
             "- native: `%s`" % native_label, "- cross: `%s`" % cross_label, "",
             "## Summary", "",
             "| severity | count |", "|---|---|"]
    for s in SEVERITIES:
        lines.append("| %s | %d |" % (s, len(by[s])))
    lines += ["", "Entries: native %s, cross %s; missing %s, extra %s. Compared: "
              "%s plists, %s Mach-O, %s byte-compared files, %s Assets.car." % (
                  stats.get("native_entries"), stats.get("cross_entries"),
                  stats.get("missing"), stats.get("extra"), stats.get("plist"),
                  stats.get("macho"), stats.get("bytes"), stats.get("assets")), ""]
    cats = {}
    for f in by[ERROR]:
        cats[f.category] = cats.get(f.category, 0) + 1
    if cats:
        lines.append("Errors by category: " + ", ".join(
            "%s %d" % kv for kv in sorted(cats.items(), key=lambda kv: -kv[1])) + ".")
        lines.append("")
    for s in SEVERITIES:
        if not by[s]:
            continue
        lines += ["## %s (%d)" % (s.capitalize(), len(by[s])), ""]
        cat_names = sorted({f.category for f in by[s]})
        for cat in cat_names:
            lines += ["### %s" % cat, ""]
            for f in by[s]:
                if f.category == cat:
                    lines.append("- `%s`: %s" % (f.path, f.message.replace("\n", " ")))
            lines.append("")
    if "native_entitlements" in stats:
        lines += ["## Main executable entitlements", "",
                  "- native: `%s`" % _short(stats["native_entitlements"], 2000),
                  "- cross: `%s`" % _short(stats["cross_entitlements"], 2000), ""]
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("native")
    ap.add_argument("cross")
    ap.add_argument("--report", help="write the markdown report here")
    ap.add_argument("--no-assetutil", action="store_true")
    args = ap.parse_args(argv)
    tmp = tempfile.mkdtemp(prefix="ios_parity_")
    try:
        n = open_bundle(args.native, tmp)
        c = open_bundle(args.cross, tmp)
        comp = Comparer(n, c, use_assetutil=not args.no_assetutil)
        findings = comp.run()
        md = render(findings, comp.stats, args.native, args.cross)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if args.report:
        with open(args.report, "w") as f:
            f.write(md + "\n")
    errors = sum(1 for f in findings if f.severity == ERROR)
    summary = "parity: %d errors, %d warnings, %d info" % (
        errors, sum(1 for f in findings if f.severity == WARNING),
        sum(1 for f in findings if f.severity == INFO))
    print(md if not args.report else summary)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
