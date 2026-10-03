import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from configure_xcode import configure
from prepare_simulator_fixture import FLUTTER_MAIN, FLUTTER_PUBSPEC, prepare_compose, prepare_flutter
from simulator_smoke import Smoke, app_metadata, select_device


DEVICE = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-0"
IPHONE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"


def inventory():
    return {
        "runtimes": [{"identifier": RUNTIME, "version": "26.0", "isAvailable": True}],
        "devicetypes": [{"identifier": IPHONE, "name": "iPhone 17"}],
        "devices": {RUNTIME: [{
            "udid": "existing-device-must-not-be-touched", "name": "iPhone 17",
            "deviceTypeIdentifier": IPHONE, "isAvailable": True,
        }]},
    }


class SelectionTests(unittest.TestCase):
    def test_selects_newest_available_ios_not_unavailable_or_tvos(self):
        data = inventory()
        data["runtimes"].extend([
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-25-0", "version": "25.0", "isAvailable": True},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "isAvailable": False},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-28-0", "version": "28.0", "isAvailable": True},
        ])
        self.assertEqual(select_device(data), (RUNTIME, IPHONE))

    def test_uses_supported_types_without_preexisting_device(self):
        data = inventory()
        data["devices"] = {}
        data["runtimes"][0]["supportedDeviceTypes"] = [{"identifier": IPHONE}]
        self.assertEqual(select_device(data), (RUNTIME, IPHONE))

    def test_falls_back_to_device_name_for_older_inventory(self):
        data = inventory()
        del data["devices"][RUNTIME][0]["deviceTypeIdentifier"]
        self.assertEqual(select_device(data), (RUNTIME, IPHONE))

    def test_rejects_missing_runtime_or_compatible_iphone(self):
        for field in ("runtimes", "devicetypes", "devices"):
            with self.subTest(field=field):
                data = inventory()
                data[field] = {} if field == "devices" else []
                with self.assertRaisesRegex(RuntimeError, "No available iOS runtime"):
                    select_device(data)

    def test_selection_is_deterministic(self):
        data = inventory()
        other = "com.apple.CoreSimulator.SimDeviceType.iPhone-16"
        data["devicetypes"].append({"identifier": other, "name": "iPhone 16"})
        data["devices"][RUNTIME].append({"name": "iPhone 16", "isAvailable": True})
        self.assertEqual(select_device(data), (RUNTIME, other))

        data["devicetypes"].reverse()
        data["devices"][RUNTIME].reverse()
        self.assertEqual(select_device(data), (RUNTIME, other))

    def test_sdk_and_minimum_os_compatibility(self):
        self.assertEqual(select_device(inventory(), "26.0", "18.0"), (RUNTIME, IPHONE))
        for sdk, minimum in (("25.0", None), ("26.0", "26.1"), ("27.0", None)):
            with self.subTest(sdk=sdk, minimum=minimum):
                with self.assertRaisesRegex(RuntimeError, "No available iOS runtime"):
                    select_device(inventory(), sdk, minimum)


class XcodeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get("JCODE_SCRATCH_DIR"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.apps = self.root / "Applications"
        self.apps.mkdir()
        self.versions = {"Xcode_26.0.app": "26.0", "Xcode_26.1.app": "26.1"}
        for name in self.versions:
            (self.apps / name / "Contents/Developer/SDKs/iPhoneSimulator.sdk").mkdir(parents=True)
        self.calls = []
        self.failure = None
        self.mismatch = None
        self.foreign_sdk = None
        self.run_mock = patch("configure_xcode.subprocess.run", side_effect=self.fake_run).start()
        self.addCleanup(patch.stopall)

    def fake_run(self, args, **kwargs):
        self.calls.append((args, kwargs))
        developer = Path(kwargs["env"]["DEVELOPER_DIR"])
        app = developer.parent.parent.name
        if app == self.failure:
            raise subprocess.TimeoutExpired(args, kwargs["timeout"])
        if "--show-sdk-version" in args:
            stdout = "25.0" if app == self.mismatch and "iphoneos" in args else self.versions[app]
        elif "--show-sdk-path" in args:
            stdout = str(self.foreign_sdk or developer / "SDKs/iPhoneSimulator.sdk")
        elif "simctl" in args:
            stdout = json.dumps(inventory())
        else:
            stdout = "Apple Swift version 6.3"
        return subprocess.CompletedProcess(args, 0, stdout, "")

    def test_selects_highest_sdk_with_compatible_runtime_without_mutation(self):
        selected = configure(self.root / "output", self.apps)
        self.assertEqual(selected["sdk_version"], "26.1")
        self.assertEqual(selected["runtime"], RUNTIME)
        self.assertTrue((self.root / "output/selected-xcode.json").exists())
        for args, kwargs in self.calls:
            self.assertEqual(kwargs["timeout"], 60)
            self.assertFalse(any(command in args for command in ("create", "boot", "delete", "sudo")))

    def test_candidate_timeout_or_mismatched_sdk_falls_back(self):
        for field in ("failure", "mismatch"):
            with self.subTest(field=field):
                setattr(self, field, "Xcode_26.1.app")
                selected = configure(self.root / field, self.apps)
                self.assertEqual(selected["sdk_version"], "26.0")
                setattr(self, field, None)

    def test_foreign_sdk_is_rejected_and_failure_evidence_written(self):
        self.foreign_sdk = self.root
        with self.assertRaisesRegex(RuntimeError, "No native Xcode"):
            configure(self.root / "output", self.apps)
        errors = json.loads((self.root / "output/selection-errors.json").read_text())
        self.assertEqual(len(errors), 2)

    def test_no_installed_xcode_fails(self):
        with self.assertRaisesRegex(RuntimeError, "No native Xcode"):
            configure(self.root / "output", self.root / "missing")


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get("JCODE_SCRATCH_DIR"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_flutter_fixture_probes_plugin_and_hook_before_first_frame_marker(self):
        destination = self.root / "flutter"
        prepare_flutter(destination)
        self.assertEqual((destination / "pubspec.yaml").read_text(), FLUTTER_PUBSPEC)
        self.assertEqual((destination / "lib/main.dart").read_text(), FLUTTER_MAIN)
        with (destination / "ios/Flutter/AppFrameworkInfo.plist").open("rb") as source:
            self.assertEqual(plistlib.load(source)["MinimumOSVersion"], "13.0")
        self.assertLess(FLUTTER_MAIN.index("preferences.getInt"), FLUTTER_MAIN.index("runApp"))
        self.assertLess(FLUTTER_MAIN.index("database.select"), FLUTTER_MAIN.index("runApp"))
        self.assertLess(FLUTTER_MAIN.index("runApp"), FLUTTER_MAIN.index("XCROSS_SIMULATOR_NATIVE_FIRST_FRAME_READY"))

    def test_compose_fixture_changes_only_copy_and_excludes_build_outputs(self):
        source = self.root / "source"
        gradle = source / "shared/build.gradle.kts"
        gradle.parent.mkdir(parents=True)
        gradle.write_text("kotlin {\n    iosArm64 {\n        binaries.framework {}\n    }\n}")
        controller = source / "shared/src/iosMain/kotlin/MainViewController.kt"
        controller.parent.mkdir(parents=True)
        controller.write_text(
            "import androidx.compose.ui.window.ComposeUIViewController\n"
            "fun MainViewController() = ComposeUIViewController { App() }\n"
        )
        (source / "build").mkdir()
        (source / "build/stale").touch()
        destination = self.root / "compose"
        prepare_compose(source, destination)
        self.assertIn("iosArm64", gradle.read_text())
        self.assertNotIn("XCROSS_COMPOSE_READY", controller.read_text())
        self.assertIn("iosSimulatorArm64", (destination / "shared/build.gradle.kts").read_text())
        text = (destination / controller.relative_to(source)).read_text()
        self.assertIn('SideEffect { println("XCROSS_COMPOSE_READY") }', text)
        self.assertFalse((destination / "build").exists())
        with self.assertRaisesRegex(RuntimeError, "read-only source"):
            prepare_compose(source, source / "fixture")


class SmokeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get("JCODE_SCRATCH_DIR"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "Test.app"
        self.app.mkdir()
        self.info = {
            "CFBundleIdentifier": "dev.xcross.smoke", "CFBundleExecutable": "Runner",
            "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
        }
        self.write_plist()
        (self.app / "Runner").touch()
        self.smoke = Smoke(self.app, self.root / "artifacts", boot_timeout=7, observe_seconds=2)
        self.calls = []
        self.failure = None
        self.arch = "arm64"
        self.binary_platform = "IOSSIMULATOR"
        self.process = "Ss /simulator/Applications/Test.app/Runner\n"
        self.launch = "dev.xcross.smoke: 1234\n"
        self.process_calls = 0
        self.exit_after = None
        self.recover_device = False
        self.ready_output = None
        self.nonzero = None
        self.screenshot = True
        self.keep_deleted_device = False
        self.run_mock = patch("simulator_smoke.subprocess.run", side_effect=self.fake_run).start()
        self.addCleanup(patch.stopall)
        patch("simulator_smoke.Path.home", return_value=self.root / "home").start()
        patch("simulator_smoke.time.sleep").start()
        self.clock = 0
        patch("simulator_smoke.time.monotonic", side_effect=self.monotonic).start()

    def monotonic(self):
        self.clock += 0.5
        return self.clock

    def write_plist(self):
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))

    def fake_run(self, args, **kwargs):
        self.calls.append((args, kwargs))
        if self.failure and self.failure in args:
            raise subprocess.TimeoutExpired(args, kwargs["timeout"], output=b"timed out")
        if self.nonzero and self.nonzero in args:
            return subprocess.CompletedProcess(args, 1, "failure")
        stdout = ""
        code = 0
        if args[0] == "/usr/bin/uname":
            stdout = self.arch
        elif "vtool" in args:
            stdout = f"platform {self.binary_platform}\n"
        elif "--show-sdk-version" in args:
            stdout = "26.0"
        elif "list" in args:
            data = inventory()
            if self.recover_device:
                data["devices"][RUNTIME].append({"udid": DEVICE, "name": self.smoke.created_name})
            stdout = json.dumps(data)
        elif "create" in args:
            stdout = DEVICE + "\n"
        elif "launch" in args:
            stdout = self.launch
        elif "screenshot" in args and self.screenshot:
            Path(args[-1]).write_bytes(b"png")
        elif "delete" in args and not self.keep_deleted_device:
            self.recover_device = False
        elif args[0] == "/bin/ps":
            self.process_calls += 1
            stdout = self.process
            if self.exit_after and self.process_calls > self.exit_after:
                stdout = ""
            code = 0 if stdout else 1
        elif "log" in args:
            stdout = self.ready_output or ""
        return subprocess.CompletedProcess(args, code, stdout)

    def assert_scoped_cleanup(self):
        shutdown = [args for args, _ in self.calls if "shutdown" in args]
        delete = [args for args, _ in self.calls if "delete" in args]
        self.assertEqual(shutdown, [["/usr/bin/xcrun", "simctl", "shutdown", DEVICE]])
        self.assertEqual(delete, [["/usr/bin/xcrun", "simctl", "delete", DEVICE]])
        self.assertFalse(any("booted" in args or "all" in args for args, _ in self.calls))

    def result(self):
        return json.loads((self.smoke.output / "result.json").read_text())

    def test_success_observes_pid_and_captures_diagnostics(self):
        self.smoke.run()
        self.assertGreater(self.process_calls, 1)
        self.assertTrue(self.result()["passed"])
        self.assertTrue(any("screenshot" in args for args, _ in self.calls))
        self.assertTrue(any("log" in args for args, _ in self.calls))
        boot = next(kwargs for args, kwargs in self.calls if "bootstatus" in args)
        self.assertEqual(boot["timeout"], 7)
        self.assert_scoped_cleanup()

    def test_ready_marker_from_new_unified_log_is_required(self):
        self.smoke.ready_marker = "XCROSS_READY"
        self.ready_output = "app: XCROSS_READY\n"
        self.smoke.run()
        self.assertTrue(self.result()["ready_marker_found"])
        self.assert_scoped_cleanup()

    def test_persistent_pid_without_ready_marker_fails_and_cleans_up(self):
        self.smoke.ready_marker = "XCROSS_READY"
        with self.assertRaisesRegex(RuntimeError, "App-ready marker not observed"):
            self.smoke.run()
        self.assert_scoped_cleanup()

    def test_previous_run_evidence_is_rejected(self):
        (self.smoke.output / "simulator.log").write_text("XCROSS_READY")
        with self.assertRaisesRegex(RuntimeError, "previous run"):
            Smoke(self.app, self.smoke.output, ready_marker="XCROSS_READY")
        self.assertEqual(self.calls, [])

    def test_boot_timeout_still_collects_and_deletes_only_created_device(self):
        self.failure = "bootstatus"
        with self.assertRaisesRegex(RuntimeError, "timed out"):
            self.smoke.run()
        self.assertTrue(any("screenshot" in args for args, _ in self.calls))
        self.assertTrue(any("log" in args for args, _ in self.calls))
        self.assertFalse(self.result()["passed"])
        self.assert_scoped_cleanup()

    def test_successful_launch_but_immediate_exit_fails(self):
        self.process = ""
        with self.assertRaisesRegex(RuntimeError, "exited or crashed"):
            self.smoke.run()
        self.assert_scoped_cleanup()

    def test_process_exiting_during_observation_fails_and_cleans_up(self):
        self.exit_after = 1
        with self.assertRaisesRegex(RuntimeError, "exited or crashed"):
            self.smoke.run()
        self.assertGreater(self.process_calls, 1)
        self.assert_scoped_cleanup()

    def test_create_timeout_recovers_only_unique_job_created_device(self):
        self.failure = "create"
        self.recover_device = True
        with self.assertRaisesRegex(RuntimeError, "timed out"):
            self.smoke.run()
        self.assert_scoped_cleanup()

    def test_create_timeout_without_creation_never_deletes_existing_simulator(self):
        self.failure = "create"
        with self.assertRaisesRegex(RuntimeError, "timed out"):
            self.smoke.run()
        self.assertFalse(any("shutdown" in args or "delete" in args for args, _ in self.calls))

    def test_observation_timeout_cleans_up(self):
        self.failure = "/bin/ps"
        with self.assertRaisesRegex(RuntimeError, "timed out"):
            self.smoke.run()
        self.assert_scoped_cleanup()

    def test_zombie_and_reused_pid_fail(self):
        for process in ("Z /Applications/Test.app/Runner", "Ss /usr/bin/other"):
            with self.subTest(process=process):
                self.process = process
                self.smoke.pid = 1234
                self.smoke.executable = "Runner"
                with self.assertRaisesRegex(RuntimeError, "exited or crashed"):
                    self.smoke.observe()

    def test_launch_without_pid_is_not_success(self):
        self.launch = "launch request accepted"
        with self.assertRaisesRegex(RuntimeError, "did not return an app PID"):
            self.smoke.run()
        self.assert_scoped_cleanup()

    def test_install_failure_cleans_up(self):
        self.failure = "install"
        with self.assertRaises(RuntimeError):
            self.smoke.run()
        self.assert_scoped_cleanup()

    def test_nonzero_install_and_launch_clean_up(self):
        for command in ("install", "launch"):
            with self.subTest(command=command):
                self.nonzero = command
                self.smoke.output = self.root / command
                self.smoke.output.mkdir()
                self.calls.clear()
                with self.assertRaisesRegex(RuntimeError, "Command failed"):
                    self.smoke.run()
                self.assert_scoped_cleanup()

    def test_shutdown_timeout_still_attempts_delete(self):
        self.failure = "shutdown"
        with self.assertRaises(RuntimeError):
            self.smoke.run()
        self.assert_scoped_cleanup()

    def test_screenshot_failure_fails_successful_smoke(self):
        self.failure = "screenshot"
        with self.assertRaisesRegex(RuntimeError, "diagnostics failed"):
            self.smoke.run()
        self.assert_scoped_cleanup()

    def test_missing_screenshot_artifact_fails_and_cleans_up(self):
        self.screenshot = False
        with self.assertRaisesRegex(RuntimeError, "screenshot.png was not created"):
            self.smoke.run()
        self.assert_scoped_cleanup()

    def test_cleanup_failure_cannot_report_success(self):
        self.recover_device = True
        self.keep_deleted_device = True
        with self.assertRaisesRegex(RuntimeError, "still exists after cleanup"):
            self.smoke.run()
        self.assertFalse(self.result()["passed"])
        self.assert_scoped_cleanup()

    def test_invalid_host_never_creates_or_deletes_a_device(self):
        self.arch = "x86_64"
        with self.assertRaisesRegex(RuntimeError, "native macOS ARM64"):
            self.smoke.run()
        self.assertFalse(any("simctl" in args for args, _ in self.calls))

    def test_device_binary_never_creates_a_simulator(self):
        self.binary_platform = "IOS"
        with self.assertRaisesRegex(RuntimeError, "Not an ARM64 iOS Simulator"):
            self.smoke.run()
        self.assertFalse(any("create" in args for args, _ in self.calls))

    def test_missing_arm64_binary_never_creates_a_simulator(self):
        self.nonzero = "lipo"
        with self.assertRaisesRegex(RuntimeError, "Command failed"):
            self.smoke.run()
        self.assertFalse(any("create" in args for args, _ in self.calls))

    def test_embedded_device_framework_is_rejected(self):
        framework = self.app / "Frameworks/Bad.framework"
        framework.mkdir(parents=True)
        (framework / "Bad").touch()
        original = self.fake_run

        def run(args, **kwargs):
            if "vtool" in args and args[-1].endswith("/Bad"):
                return subprocess.CompletedProcess(args, 0, "platform IOS\n")
            return original(args, **kwargs)

        self.run_mock.side_effect = run
        with self.assertRaisesRegex(RuntimeError, "Not an ARM64 iOS Simulator"):
            self.smoke.run()
        self.assertFalse(any("create" in args for args, _ in self.calls))

    def test_device_plist_rejected(self):
        self.info["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
        self.write_plist()
        with self.assertRaisesRegex(RuntimeError, "not a device app"):
            app_metadata(self.app)

    def test_executable_traversal_rejected(self):
        self.info["CFBundleExecutable"] = "../Runner"
        self.write_plist()
        with self.assertRaisesRegex(RuntimeError, "Invalid app executable"):
            app_metadata(self.app)

    def test_new_crash_report_fails_and_is_preserved(self):
        reports = self.root / "home/Library/Logs/DiagnosticReports"
        reports.mkdir(parents=True)
        (reports / "Runner-2026.ips").write_text(
            json.dumps({"bundleID": self.info["CFBundleIdentifier"]}) + "\n"
            + json.dumps({"pid": 1234})
        )
        (reports / "Other-2026.ips").write_text("unrelated")
        with self.assertRaisesRegex(RuntimeError, "found crashes"):
            self.smoke.run()
        self.assertEqual(len(self.result()["crashes"]), 1)
        self.assertTrue((self.smoke.output / "crashes/0-Runner-2026.ips").exists())
        self.assert_scoped_cleanup()

    def test_unrelated_same_executable_global_crashes_are_ignored(self):
        reports = self.root / "home/Library/Logs/DiagnosticReports"
        reports.mkdir(parents=True)
        (reports / "Runner-other.ips").write_text(json.dumps({
            "pid": 9999, "bundleInfo": {"CFBundleIdentifier": self.info["CFBundleIdentifier"]},
        }))
        (reports / "Runner-other.crash").write_text(
            f"Process: Runner [9999]\nIdentifier: {self.info['CFBundleIdentifier']}\n"
        )
        (reports / "Runner-same-pid.ips").write_text(json.dumps({
            "pid": 1234, "bundleInfo": {"CFBundleIdentifier": "unrelated.bundle"},
        }))
        self.smoke.run()
        self.assertEqual(self.result()["crashes"], [])
        self.assertFalse((self.smoke.output / "crashes").exists())
        self.assert_scoped_cleanup()

    def test_created_device_crash_evidence_is_collected_without_pid(self):
        reports = self.root / "home/Library/Developer/CoreSimulator/Devices" / DEVICE / "data/Library/Logs/CrashReporter"
        reports.mkdir(parents=True)
        (reports / "Runner-device.ips").write_text("crash")
        self.failure = "launch"
        with self.assertRaises(RuntimeError):
            self.smoke.run()
        self.assertTrue((self.smoke.output / "crashes/1-Runner-device.ips").exists())
        self.assert_scoped_cleanup()


if __name__ == "__main__":
    unittest.main()
