import os
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.dirname(__file__))
import ios_bundle_check as c


def png(w, h):
    return b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", w, h) + b"\x08\x06\0\0\0"


def macho(ents):
    xml = plistlib.dumps(ents)
    ent = struct.pack(">II", 0xFADE7171, len(xml) + 8) + xml
    sb_len = 12 + 8 + len(ent)
    sb = struct.pack(">III", 0xFADE0CC0, sb_len, 1) + struct.pack(">II", 5, 20) + ent
    header = struct.pack("<IiiIII", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 16) + b"\0" * 8
    lc = struct.pack("<IIII", 0x1D, 16, 32 + 16, len(sb))
    return header + lc + sb


INFO = {
    "CFBundleExecutable": "Runner",
    "CFBundleIcons": {"CFBundlePrimaryIcon": {
        "CFBundleIconFiles": ["AppIcon60x60"], "CFBundleIconName": "AppIcon"}},
    "CFBundleIcons~ipad": {"CFBundlePrimaryIcon": {
        "CFBundleIconFiles": ["AppIcon60x60", "AppIcon76x76"],
        "CFBundleIconName": "AppIcon"}},
    "UILaunchScreen": {"UIImageName": "LaunchImage", "UIColorName": "LaunchBg"},
}
ENTS = {"aps-environment": "development",
        "com.apple.developer.associated-domains": ["applinks:example.com"]}


def files(info=INFO, car=b"BOMStore....", ents=ENTS):
    return {
        "Info.plist": plistlib.dumps(info),
        "Assets.car": car,
        "AppIcon60x60@2x.png": png(120, 120),
        "AppIcon76x76@2x~ipad.png": png(152, 152),
        "Runner": macho(ents),
    }


class T(unittest.TestCase):
    def app(self, fs):
        d = tempfile.mkdtemp()
        for n, v in fs.items():
            path = os.path.join(d, *n.split("/"))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as f:
                f.write(v)
        return d

    def run_check(self, p):
        return c.check(p, ["aps-environment", "com.apple.developer.associated-domains"],
                       "LaunchImage", "AppIcon", True)[0]

    def test_ok_app_and_ipa(self):
        d = self.app(files())
        self.assertEqual(self.run_check(d), [])
        z = os.path.join(tempfile.mkdtemp(), "a.ipa")
        with zipfile.ZipFile(z, "w") as zf:
            for n, v in files().items():
                zf.writestr("Payload/Runner.app/" + n, v)
        self.assertEqual(self.run_check(z), [])

    def test_native_compiled_launch_storyboard(self):
        info = {k: v for k, v in INFO.items() if k != "UILaunchScreen"}
        info["UILaunchStoryboardName"] = "LaunchScreen"
        fs = files(info)
        sbc = "Base.lproj/LaunchScreen.storyboardc/"
        fs[sbc + "Info.plist"] = b"bplist00"
        fs[sbc + "UIViewController-01J-lp-oVM.nib"] = b"NIBArchive"
        self.assertEqual(self.run_check(self.app(fs)), [])
        del fs[sbc + "UIViewController-01J-lp-oVM.nib"]
        text = "\n".join(self.run_check(self.app(fs)))
        self.assertIn("incomplete", text)

    def test_failures(self):
        info = dict(INFO, XCrossEntitlements={}, UILaunchStoryboardName="LaunchScreen")
        fs = files(info, car=b"nope", ents={"aps-environment": "x"})
        del fs["AppIcon76x76@2x~ipad.png"]
        text = "\n".join(self.run_check(self.app(fs)))
        for s in ("BOM", "~ipad", "XCrossEntitlements",
                  "UILaunchStoryboardName", "associated-domains"):
            self.assertIn(s, text)

    def test_launch_screen_fallback_failures(self):
        info = dict(INFO, UILaunchScreen={"UIImageName": "Other"})
        text = "\n".join(self.run_check(self.app(files(info))))
        for s in ("UIColorName", "UIImageName"):
            self.assertIn(s, text)

    def test_resource_bundles(self):
        fs = files()
        fs["Pkg_T.bundle/Info.plist"] = plistlib.dumps(
            {"CFBundlePackageType": "BNDL", "CFBundleIdentifier": "pkg.T.resources"})
        fs["Pkg_T.bundle/PrivacyInfo.xcprivacy"] = b"<plist/>"
        fs["Bare.bundle/PrivacyInfo.xcprivacy"] = b"<plist/>"
        d = self.app(fs)
        os.symlink("../../WebImage/PrivacyInfo.xcprivacy",
                   os.path.join(d, "Pkg_T.bundle", "Escaping.xcprivacy"))
        errors, _ = c.check(d, expect_bundle_files=[
            "Pkg_T.bundle/PrivacyInfo.xcprivacy", "Gone_T.bundle/PrivacyInfo.xcprivacy"])
        text = "\n".join(errors)
        self.assertIn("Bare.bundle has no Info.plist", text)
        self.assertIn("links outside its bundle", text)
        self.assertIn("missing Gone_T.bundle/PrivacyInfo.xcprivacy", text)
        self.assertNotIn("Pkg_T.bundle has no Info.plist", text)

    def ib_app(self, extra):
        fs = files()
        fs["P_T.bundle/Info.plist"] = plistlib.dumps(
            {"CFBundlePackageType": "BNDL", "CFBundleIdentifier": "p.T"})
        fs.update(extra)
        return fs

    def test_expect_lf(self):
        fs = self.ib_app({
            "P_T.bundle/en.lproj/A.strings": b'"a" = "b";\r\n',
            "P_T.bundle/PrivacyInfo.xcprivacy": b"<plist/>\n",
        })
        d = self.app(fs)
        text = "\n".join(c.check(d, expect_lf=[
            "P_T.bundle/en.lproj/A.strings",
            "P_T.bundle/PrivacyInfo.xcprivacy",
            "P_T.bundle/Missing.strings"])[0])
        self.assertIn("A.strings has CRLF line endings", text)
        self.assertNotIn("PrivacyInfo.xcprivacy has CRLF", text)
        self.assertNotIn("Missing.strings", text)

    def test_ib_sources_and_nibs(self):
        fs = self.ib_app({
            "P_T.bundle/A.nib": b"NIBArchive\x01\x00",
            "P_T.bundle/B.xib": b"<xml/>",
            "P_T.bundle/C.storyboard": b"<xml/>",
            "P_T.bundle/Bad.nib": b"junk",
            "P_T.bundle/Empty.nib": b"",
            "P_T.bundle/Dir.nib/runtime.nib": b"x",
            "P_T.bundle/BadDir.nib/other": b"x",
        })
        d = self.app(fs)
        text = "\n".join(c.check(d, no_ib_sources=True)[0])
        self.assertIn("B.xib is uncompiled", text)
        self.assertIn("C.storyboard is uncompiled", text)
        self.assertIn("Bad.nib lacks the NIBArchive magic", text)
        self.assertIn("Empty.nib is empty", text)
        self.assertIn("BadDir.nib has no runtime.nib", text)
        self.assertNotIn("A.nib", text)
        self.assertNotIn("Dir.nib/", text.replace("BadDir.nib", ""))
        # opt-in: without the flag the xib is tolerated
        self.assertNotIn("uncompiled", "\n".join(c.check(d)[0]))

    def test_ib_checks_in_ipa(self):
        fs = self.ib_app({"P_T.bundle/A.nib": b"NIBArchive\x01",
                          "P_T.bundle/B.xib": b"<xml/>"})
        z = os.path.join(tempfile.mkdtemp(), "a.ipa")
        with zipfile.ZipFile(z, "w") as zf:
            for n, v in fs.items():
                zf.writestr("Payload/Runner.app/" + n, v)
        errors, _ = c.check(z, no_ib_sources=True)
        self.assertEqual([e for e in errors if "Interface Builder" in e],
                         ["P_T.bundle/B.xib is uncompiled Interface Builder source"])

    def both(self, fs):
        d = self.app(fs)
        z = os.path.join(tempfile.mkdtemp(), "a.ipa")
        with zipfile.ZipFile(z, "w") as zf:
            for n, v in fs.items():
                zf.writestr("Payload/Runner.app/" + n, v)
        return d, z

    def test_loose_dylib_family_and_framework_files(self):
        fw = {"Frameworks/A.framework/Info.plist": plistlib.dumps(
                  {"CFBundlePackageType": "FMWK", "CFBundleExecutable": "A"}),
              "Frameworks/A.framework/A": b"\xcf\xfa\xed\xfe" + b"\0" * 8,
              "Frameworks/A.framework/PrivacyInfo.xcprivacy": b"x"}
        good = dict(files(dict(INFO, UIDeviceFamily=[1, 2])), **fw)
        bad = dict(files(dict(INFO, UIDeviceFamily=[1])), **fw)
        bad["Frameworks/libx.dylib"] = b"x"
        bad["Frameworks/A.framework/PrivacyInfo.xcprivacy"] = b""
        kw = dict(no_loose_dylibs=True, expect_device_family=[1, 2],
                  expect_framework_file=["Frameworks/A.framework/PrivacyInfo.xcprivacy",
                                         "Frameworks/B.framework/PrivacyInfo.xcprivacy"])
        for g, b_ in zip(self.both(good), self.both(bad)):
            ge = c.check(g, **kw)[0]
            self.assertEqual(ge, ["missing Frameworks/B.framework/PrivacyInfo.xcprivacy"])
            text = "\n".join(c.check(b_, **kw)[0])
            self.assertIn("libx.dylib is a loose dylib", text)
            self.assertIn("UIDeviceFamily [1] != [1, 2]", text)
            self.assertIn("A.framework/PrivacyInfo.xcprivacy is empty", text)

    def test_framework_structure(self):
        fs = dict(files())
        fs["Frameworks/A.framework/Info.plist"] = plistlib.dumps(
            {"CFBundlePackageType": "APPL", "CFBundleExecutable": "A"})
        fs["Frameworks/A.framework/A"] = b"notmacho"
        fs["Frameworks/B.framework/B"] = b"\xca\xfe\xba\xbe"
        for p in self.both(fs):
            text = "\n".join(c.check(p)[0])
            self.assertIn("A.framework Info.plist is not an FMWK", text)
            self.assertIn("A.framework/A is not a Mach-O", text)
            self.assertIn("B.framework/Info.plist unreadable", text)

    def test_add_entitlements(self):
        d = tempfile.mkdtemp()
        os.makedirs(os.path.join(d, "Runner"))
        os.makedirs(os.path.join(d, "Runner.xcodeproj"))
        pbx = os.path.join(d, "Runner.xcodeproj", "project.pbxproj")
        with open(pbx, "w") as f:
            f.write("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = a.b;\n\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = a.b.RunnerTests;\n")
        c.add_entitlements(d)
        with open(pbx) as f:
            self.assertEqual(f.read().count("CODE_SIGN_ENTITLEMENTS"), 1)


if __name__ == "__main__":
    unittest.main()
