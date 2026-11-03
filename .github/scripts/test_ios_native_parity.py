#!/usr/bin/env python3
"""Unit tests for ios_native_parity.py using synthetic bundles."""

import os
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ios_native_parity as P  # noqa: E402


def _lc_dylib(cmd, name):
    s = name.encode() + b"\0"
    s += b"\0" * (-(24 + len(s)) % 8)
    return struct.pack("<IIIIII", cmd, 24 + len(s), 24, 0, 0, 0) + s


def _lc_rpath(path):
    s = path.encode() + b"\0"
    s += b"\0" * (-(12 + len(s)) % 8)
    return struct.pack("<III", P.LC_RPATH, 12 + len(s), 12) + s


def _lc_build(minos=(13, 0), sdk=(18, 0)):
    enc = lambda v: (v[0] << 16) | (v[1] << 8)  # noqa: E731
    return struct.pack("<IIIIII", P.LC_BUILD_VERSION, 24, 2, enc(minos), enc(sdk), 0)


def _lc_text(text_size):
    seg = struct.pack("<II16sQQQQiiII", P.LC_SEGMENT_64, 72 + 80, b"__TEXT",
                      0, 0, 0, 0, 5, 5, 1, 0)
    sect = struct.pack("<16s16sQQIIIIIIII", b"__text", b"__TEXT", 0, text_size,
                       0, 0, 0, 0, 0, 0, 0, 0)
    return seg + sect


def macho(filetype=2, dylibs=(), weak=(), rpaths=(), install=None, minos=(13, 0),
          text=100, entitlements=None):
    cmds = [_lc_build(minos), _lc_text(text)]
    if install:
        cmds.append(_lc_dylib(P.LC_ID_DYLIB, install))
    cmds += [_lc_dylib(P.LC_LOAD_DYLIB, d) for d in dylibs]
    cmds += [_lc_dylib(P.LC_LOAD_WEAK_DYLIB, d) for d in weak]
    cmds += [_lc_rpath(r) for r in rpaths]
    sig = b""
    if entitlements is not None:
        cmds.append(b"")  # placeholder for LC_CODE_SIGNATURE
    ncmds = len(cmds)
    sizeofcmds = sum(len(c) for c in cmds) + (16 if entitlements is not None else 0)
    header_len = 32 + sizeofcmds
    if entitlements is not None:
        ent = plistlib.dumps(entitlements)
        blob = struct.pack(">II", 0xFADE7171, 8 + len(ent)) + ent
        sig = struct.pack(">IIIII", 0xFADE0CC0, 20 + len(blob), 1, 5, 20) + blob
        cmds[-1] = struct.pack("<IIII", P.LC_CODE_SIGNATURE, 16, header_len, len(sig))
    hdr = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, filetype, ncmds,
                      sizeofcmds, 0, 0)
    return hdr + b"".join(cmds) + sig


def fat(thin):
    off = 4096
    hdr = struct.pack(">IIiiIII", 0xCAFEBABE, 1, 0x0100000C, 0, off, len(thin), 14)
    return hdr + b"\0" * (off - len(hdr)) + thin


def write_tree(root, files):
    for rel, data in files.items():
        p = os.path.join(root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data)


def info(**kw):
    d = {"CFBundleIdentifier": "com.example.app", "CFBundleExecutable": "Runner",
         "MinimumOSVersion": "13.0", "UIDeviceFamily": [1, 2],
         "BuildMachineOSBuild": "24A1", "DTSDKName": "iphoneos18.0",
         "DTSDKBuild": "22A1", "DTPlatformName": "iphoneos"}
    d.update(kw)
    return plistlib.dumps(d)


ENT = {"application-identifier": "T.com.example.app", "aps-environment": "production"}


def base_files():
    return {
        "Info.plist": info(),
        "PkgInfo": b"APPL????",
        "Runner": macho(dylibs=["/usr/lib/libSystem.B.dylib",
                                "@rpath/App.framework/App"],
                        rpaths=["@executable_path/Frameworks"], entitlements=ENT),
        "PrivacyInfo.xcprivacy": b"<plist/>",
        "Frameworks/App.framework/App": fat(macho(
            filetype=6, install="@rpath/App.framework/App", text=0)),
        "Frameworks/App.framework/Info.plist": info(CFBundleIdentifier="io.flutter.app"),
        "Base.lproj/LaunchScreen.storyboardc/Info.plist": plistlib.dumps({"a": 1}),
        "Base.lproj/LaunchScreen.storyboardc/01J-lp-oVM-view-Ze5-6b-2t3.nib": b"NIB1",
        "_CodeSignature/CodeResources": b"x",
        "embedded.mobileprovision": b"y",
    }


class ParityTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.native = os.path.join(self.tmp, "n", "Runner.app")
        self.cross = os.path.join(self.tmp, "c", "Runner.app")

    def run_cmp(self, cross_files, native_files=None):
        write_tree(self.native, native_files or base_files())
        write_tree(self.cross, cross_files)
        return P.Comparer(self.native, self.cross, use_assetutil=False).run()

    def test_identical(self):
        f = base_files()
        f.pop("embedded.mobileprovision")
        self.assertEqual(
            [x for x in self.run_cmp(f) if x.severity != P.INFO], [])

    def test_macho_parse(self):
        s = P.macho_summary(fat(macho(filetype=6, install="@rpath/X", text=0,
                                      weak=["/a"])))
        self.assertEqual(list(s), ["arm64"])
        a = s["arm64"]
        self.assertEqual((a["filetype"], a["install_name"], a["stub"], a["minos"],
                          a["platform"], a["weak_dylibs"]),
                         ("MH_DYLIB", "@rpath/X", True, "13.0", "ios", ["/a"]))
        r = P.macho_summary(macho(entitlements=ENT))["arm64"]
        self.assertEqual(r["entitlements"], ENT)
        self.assertFalse(r["stub"])

    def test_differences(self):
        f = base_files()
        f["Info.plist"] = info(MinimumOSVersion="12.0", BuildMachineOSBuild="other",
                               DTSDKName="iphoneos18.0")
        f["Runner"] = macho(dylibs=["/usr/lib/libSystem.B.dylib"], minos=(12, 0),
                            entitlements={"application-identifier": "T.com.example.app"})
        f["PrivacyInfo.xcprivacy"] = b"<plist></plist>"
        del f["Base.lproj/LaunchScreen.storyboardc/01J-lp-oVM-view-Ze5-6b-2t3.nib"]
        f["extra.txt"] = b"e"
        f["Frameworks/App.framework/App"] = fat(macho(
            filetype=6, install="@rpath/App.framework/App", text=50))
        msgs = [(x.severity, x.category, x.path, x.message) for x in self.run_cmp(f)]
        text = "\n".join(map(str, msgs))
        self.assertIn("MinimumOSVersion", text)
        self.assertNotIn("BuildMachineOSBuild", text)
        self.assertIn("aps-environment", text)
        self.assertIn("App.framework/App", text)
        self.assertIn("stub", text)
        self.assertIn("dylibs: 1 missing ['App']", text)
        errs = {(c, p.split(" ")[0]) for s, c, p, _ in msgs if s == P.ERROR}
        self.assertIn(("bytes", "PrivacyInfo.xcprivacy"), errs)
        self.assertIn(("inventory",
                       "Base.lproj/LaunchScreen.storyboardc/01J-lp-oVM-view-Ze5-6b-2t3.nib"),
                      errs)
        self.assertIn(("plist", "Info.plist"), errs)
        self.assertIn(("entitlements", "Runner"), errs)
        self.assertTrue(any(s == P.WARNING and p == "extra.txt" for s, _, p, _ in msgs))

    def test_sdk_keys_ignored_when_sdks_differ(self):
        f = base_files()
        f["Info.plist"] = info(DTSDKName="iphoneos17.0", DTSDKBuild="x",
                               CFBundleSupportedPlatforms=["iPhoneOS"])
        msgs = [x for x in self.run_cmp(f) if x.category == "plist"]
        self.assertEqual(msgs, [])

    def test_ipa_input_and_report(self):
        write_tree(self.native, base_files())
        ipa = os.path.join(self.tmp, "x.ipa")
        with zipfile.ZipFile(ipa, "w") as z:
            for rel, data in base_files().items():
                z.writestr("Payload/Runner.app/" + rel, data)
        out = os.path.join(self.tmp, "r.md")
        rc = P.main([self.native, ipa, "--report", out, "--no-assetutil"])
        self.assertEqual(rc, 0)
        with open(out) as fh:
            self.assertIn("## Summary", fh.read())


if __name__ == "__main__":
    unittest.main()
