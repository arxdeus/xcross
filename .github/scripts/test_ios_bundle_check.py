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
