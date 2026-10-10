import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from configure_xcode import configure
from prepare_simulator_fixture import prepare_compose
from simulator_smoke import Smoke, app_metadata, install_timeout, select_device


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
        self.root = Path(self.temp.name).resolve()
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
        self.failure_budget = None
        self.failure_output = b"timed out"
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
        self.launchctl = "1234\t0\tUIKitApplication:dev.xcross.smoke[a1b2][rb-legacy]\n"
        self.app_stderr = None
        self.home_screen_polls = 0
        self.home_screen_delay = 0
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
        probe = "print" in args and self.failure != "print"
        if self.failure and self.failure in args and not probe:
            if self.failure_budget is not None:
                self.failure_budget -= 1
                if self.failure_budget < 0:
                    self.failure = None
            if self.failure:
                raise subprocess.TimeoutExpired(args, kwargs["timeout"], output=self.failure_output)
        if self.nonzero and self.nonzero in args:
            return subprocess.CompletedProcess(args, 1, "failure")
        stdout = ""
        code = 0
        if "print" in args:
            self.home_screen_polls += 1
            stdout = "" if self.home_screen_polls <= self.home_screen_delay else "\tstate = running\n"
            code = 0 if stdout else 113
        elif "launchctl" in args:
            stdout = self.launchctl
        elif args[0] == "/usr/bin/uname":
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
            if self.app_stderr is not None:
                stderr = next(arg for arg in args if arg.startswith("--stderr="))
                Path(stderr.split("=", 1)[1]).write_text(self.app_stderr)
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
        lipo = next(args for args, _ in self.calls if "lipo" in args)
        self.assertEqual(lipo, ["/usr/bin/xcrun", "lipo", str(self.app / "Runner"), "-verify_arch", "arm64"])
        self.assert_scoped_cleanup()

    def test_first_launch_waits_within_boot_budget(self):
        self.smoke.boot_timeout = 240
        self.smoke.run()
        launch = next(kwargs for args, kwargs in self.calls if "launch" in args)
        self.assertEqual(launch["timeout"], 240)
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

    def test_hung_launch_is_retried_after_fresh_boots(self):
        for budget in (1, 2):
            with self.subTest(hangs=budget):
                self.calls = []
                self.failure = "launch"
                self.failure_budget = budget
                self.smoke = Smoke(self.app, self.root / f"hangs-{budget}", boot_timeout=7, observe_seconds=2)
                self.smoke.run()
                launches = [args for args, _ in self.calls if "launch" in args]
                self.assertEqual(len(launches), budget + 1)
                boots = [args[2] for args, _ in self.calls if args[2:3] in (["boot"], ["bootstatus"], ["erase"], ["install"])]
                self.assertEqual(boots, ["boot", "bootstatus", "install"] + ["erase", "boot", "bootstatus", "install"] * budget)
                self.assertEqual(len(self.result()["launch_retries"]), budget)
                self.assertTrue(self.result()["passed"])
                for attempt in range(1, budget + 1):
                    self.assertTrue((self.smoke.output / f"launch-attempt-{attempt}-launch.log").is_file())
                delete = [args for args, _ in self.calls if "delete" in args]
                self.assertEqual(delete, [["/usr/bin/xcrun", "simctl", "delete", DEVICE]])

    def test_abort_marker_in_any_retried_attempt_fails(self):
        self.failure = "launch"
        self.failure_budget = 2
        self.smoke.output.mkdir(parents=True, exist_ok=True)
        (self.smoke.output / "launch-attempt-2-app-stderr.log").write_text("Fatal error: synthetic failure\n")
        with self.assertRaisesRegex(RuntimeError, "abort or crash marker"):
            self.smoke.run()

    def test_install_waits_until_home_screen_is_running(self):
        self.home_screen_delay = 3
        self.smoke.run()
        names = [args[2] if args[2] != "spawn" else args[5] for args, _ in self.calls
                 if args[2:3] in (["install"], ["spawn"]) and "list" not in args and "log" not in args]
        self.assertEqual(names[:5], ["print", "print", "print", "print", "install"])
        self.assertTrue(self.result()["passed"])

    def test_home_screen_never_running_fails_before_install(self):
        self.home_screen_delay = 10 ** 6
        with self.assertRaisesRegex(RuntimeError, "home screen not running"):
            self.smoke.run()
        self.assertFalse(any("install" in args for args, _ in self.calls))
        self.assert_scoped_cleanup()

    def test_hung_home_screen_probe_is_retried_until_running(self):
        self.failure = "print"
        self.failure_budget = 2
        self.smoke.run()
        self.assertEqual(len([args for args, _ in self.calls if "print" in args]), 3)
        self.assertTrue(self.result()["passed"])

    def test_launch_hanging_on_every_attempt_fails(self):
        self.failure = "launch"
        with self.assertRaisesRegex(RuntimeError, "timed out"):
            self.smoke.run()
        self.assertEqual(len([args for args, _ in self.calls if "launch" in args]), 3)
        self.assertEqual(len(self.result()["launch_retries"]), 2)
        self.assertFalse(self.result()["passed"])

    def test_hung_launch_with_crash_report_is_not_retried(self):
        self.failure = "launch"
        self.failure_budget = 1
        reports = (self.root / "home/Library/Developer/CoreSimulator/Devices" / DEVICE
                   / "data/Library/Logs/CrashReporter")
        reports.mkdir(parents=True)
        (reports / "Runner-2026.ips").write_text("{}")
        with self.assertRaisesRegex(RuntimeError, "timed out"):
            self.smoke.run()
        self.assertEqual(len([args for args, _ in self.calls if "launch" in args]), 1)
        self.assertEqual(self.result()["launch_retries"], [])

    def test_timed_out_diagnostics_are_recorded_without_failing(self):
        for command in ("launchctl", "screenshot"):
            with self.subTest(command=command):
                self.calls = []
                self.failure = command
                self.smoke = Smoke(self.app, self.root / command, boot_timeout=7, observe_seconds=2)
                self.smoke.run()
                self.assertTrue(self.result()["passed"])
                self.assertEqual(len(self.result()["diagnostic_timeouts"]), 1)
                self.assert_scoped_cleanup()

    def test_timed_out_diagnostic_with_abort_evidence_fails(self):
        self.failure = "launchctl"
        self.app_stderr = "Fatal error: synthetic failure\n"
        with self.assertRaisesRegex(RuntimeError, "abort or crash marker"):
            self.smoke.run()
        self.assertEqual(len(self.result()["diagnostic_timeouts"]), 1)

    def test_launch_without_pid_is_not_success(self):
        self.launch = "launch request accepted"
        with self.assertRaisesRegex(RuntimeError, "did not return an app PID"):
            self.smoke.run()
        self.assert_scoped_cleanup()

    def test_install_failure_cleans_up(self):
        self.failure = "install"
        with self.assertRaises(RuntimeError):
            self.smoke.run()
        self.assert_scoped_cleanup_after_retry()

    def test_install_timeout_scales_with_app_size(self):
        self.assertEqual(install_timeout(0), 300)
        self.assertEqual(install_timeout(246 * 1024 * 1024), 420)
        self.assertEqual(install_timeout(1024 * 1024 * 1024), 900)
        with patch("simulator_smoke.app_size", return_value=246 * 1024 * 1024):
            self.smoke.run()
        install = next(kwargs for args, kwargs in self.calls if "install" in args)
        self.assertEqual(install["timeout"], 420)

    def test_silent_install_timeout_is_retried_once_after_fresh_boot(self):
        self.failure = "install"
        self.failure_budget = 1
        self.smoke.run()
        self.assertEqual(len([args for args, _ in self.calls if "install" in args]), 2)
        boots = [args[2] for args, _ in self.calls if args[2:3] in (["boot"], ["bootstatus"], ["erase"])]
        self.assertEqual(boots, ["boot", "bootstatus", "erase", "boot", "bootstatus"])
        self.assertEqual(len(self.result()["install_retries"]), 1)
        self.assertTrue(self.result()["passed"])
        self.assertTrue((self.smoke.output / "install-attempt-1.log").is_file())
        self.assert_scoped_cleanup_after_retry()

    def test_install_hanging_twice_fails(self):
        self.failure = "install"
        with self.assertRaisesRegex(RuntimeError, "timed out"):
            self.smoke.run()
        self.assertEqual(len([args for args, _ in self.calls if "install" in args]), 2)
        self.assertFalse(self.result()["passed"])
        self.assertEqual(len(self.result()["install_retries"]), 1)

    def test_install_timeout_with_error_output_is_not_retried(self):
        self.failure = "install"
        self.failure_output = b"An error was encountered processing the command"
        with self.assertRaisesRegex(RuntimeError, "timed out"):
            self.smoke.run()
        self.assertEqual(len([args for args, _ in self.calls if "install" in args]), 1)
        self.assertEqual(self.result()["install_retries"], [])
        self.assert_scoped_cleanup()

    def assert_scoped_cleanup_after_retry(self):
        delete = [args for args, _ in self.calls if "delete" in args]
        self.assertEqual(delete, [["/usr/bin/xcrun", "simctl", "delete", DEVICE]])
        self.assertFalse(any("booted" in args or "all" in args for args, _ in self.calls))

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
        self.nonzero = "screenshot"
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

    def test_invalid_code_signature_never_creates_a_simulator(self):
        framework = self.app / "Frameworks/Bad.framework"
        framework.mkdir(parents=True)
        (framework / "Bad").touch()
        (self.app / "Frameworks/libLoose.dylib").touch()
        original = self.fake_run
        for bad in ("/Runner", "/Bad", "/libLoose.dylib"):
            with self.subTest(bad=bad):
                def run(args, **kwargs):
                    if args[0] == "/usr/bin/codesign" and args[-1].endswith(bad):
                        return subprocess.CompletedProcess(args, 1, f"{args[-1]}: invalid signature (code or signature have been modified)\n")
                    return original(args, **kwargs)

                self.run_mock.side_effect = run
                self.calls.clear()
                with self.assertRaisesRegex(RuntimeError, "Invalid code signature: .*" + re.escape(bad)):
                    self.smoke.run()
                self.assertFalse(any("create" in args for args, _ in self.calls))
                self.smoke.output = Path(tempfile.mkdtemp(dir=self.root))
        self.run_mock.side_effect = original
        self.calls.clear()
        self.smoke.run()
        signed = [args[-1] for args, _ in self.calls if args[0] == "/usr/bin/codesign"]
        self.assertEqual(sorted(Path(path).name for path in signed), ["Bad", "Runner", "libLoose.dylib"])

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

    def test_exit_after_observation_grace_fails(self):
        observe = Smoke.observe

        def observe_then_exit(smoke):
            observe(smoke)
            if smoke.observe_seconds:
                self.exit_after = self.process_calls

        patch("simulator_smoke.Smoke.observe", observe_then_exit).start()
        with self.assertRaisesRegex(RuntimeError, "after observation"):
            self.smoke.run()
        self.assertFalse(self.result()["passed"])
        self.assert_scoped_cleanup()

    def test_grace_recheck_waits_before_final_process_check(self):
        sleeps = patch("simulator_smoke.time.sleep").start()
        self.smoke.grace_seconds = 9
        self.smoke.run()
        self.assertIn(unittest.mock.call(9), sleeps.call_args_list)
        self.assertEqual(self.result()["exit_status"], "0")

    def test_abnormal_launchd_exit_status_fails(self):
        for line, message in (
            ("1234\t-6\tUIKitApplication:dev.xcross.smoke[a1b2]\n", "abnormal exit status -6"),
            ("-\t-6\tUIKitApplication:dev.xcross.smoke[a1b2]\n", "no longer the running"),
            ("1234\t0\tUIKitApplication:other.bundle[a1b2]\n", "no launchd job"),
        ):
            with self.subTest(line=line):
                self.launchctl = line
                self.smoke.output = Path(tempfile.mkdtemp(dir=self.root))
                with self.assertRaisesRegex(RuntimeError, message):
                    self.smoke.run()
                self.assertFalse(self.result()["passed"])
                self.assert_scoped_cleanup()
                self.calls.clear()

    def test_abort_markers_in_app_output_or_unified_log_fail(self):
        for stream, text in (
            ("stderr", "*** Terminating app due to uncaught exception 'NSInvalidArgumentException'\n"),
            ("stderr", "dyld[42]: Library not loaded: @rpath/Missing.framework/Missing\n"),
            ("stderr", "dyld[42]: Symbol not found: _swift_task_create\n"),
            ("log", "Runner: Fatal error: Unexpectedly found nil\n"),
            ("log", "Runner: (libsystem_c.dylib) abort() called\n"),
            ("log", "Runner: signal SIGABRT\n"),
        ):
            with self.subTest(text=text):
                self.app_stderr = text if stream == "stderr" else None
                self.ready_output = text if stream == "log" else None
                self.smoke.output = Path(tempfile.mkdtemp(dir=self.root))
                with self.assertRaisesRegex(RuntimeError, "abort or crash marker"):
                    self.smoke.run()
                self.assertTrue(self.result()["abort_markers"])
                self.assert_scoped_cleanup()
                self.calls.clear()

    def test_benign_app_output_passes(self):
        self.app_stderr = "flutter: The Dart VM service is listening\n"
        self.ready_output = "Runner: app started normally\n"
        self.smoke.run()
        self.assertEqual(self.result()["abort_markers"], [])

    def test_crash_report_written_after_exit_is_awaited_and_preserved(self):
        reports = self.root / "home/Library/Logs/DiagnosticReports"
        reports.mkdir(parents=True)
        self.exit_after = 1
        self.smoke.crash_report_wait = 30
        sleeps = []

        def sleep(seconds):
            sleeps.append(seconds)
            if self.process_calls > 1 and len(sleeps) == 4:
                (reports / "Runner-late.ips").write_text(json.dumps({
                    "pid": 1234, "bundleInfo": {"CFBundleIdentifier": self.info["CFBundleIdentifier"]},
                }))

        patch("simulator_smoke.time.sleep", side_effect=sleep).start()
        with self.assertRaisesRegex(RuntimeError, "exited or crashed"):
            self.smoke.run()
        self.assertEqual(len(self.result()["crashes"]), 1)
        self.assertTrue((self.smoke.output / "crashes/0-Runner-late.ips").exists())
        self.assert_scoped_cleanup()

    def test_healthy_run_does_not_wait_for_crash_reports(self):
        self.smoke.crash_report_wait = 1000
        self.smoke.run()
        self.assertLess(self.clock, 200)

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

    def test_crash_report_mtime_slightly_before_start_is_still_captured(self):
        # Linux stamps mtimes from a coarse clock that can trail time.time();
        # a report written right after start must not look like a stale one.
        reports = self.root / "home/Library/Logs/DiagnosticReports"
        reports.mkdir(parents=True)
        report = reports / "Runner-lagged.ips"
        report.write_text(json.dumps({
            "pid": 1234, "bundleInfo": {"CFBundleIdentifier": self.info["CFBundleIdentifier"]},
        }))
        lagged = self.smoke.started - 0.005
        os.utime(report, (lagged, lagged))
        with self.assertRaisesRegex(RuntimeError, "found crashes"):
            self.smoke.run()
        self.assertEqual(len(self.result()["crashes"]), 1)

    def test_crash_report_from_before_the_run_is_ignored(self):
        reports = self.root / "home/Library/Logs/DiagnosticReports"
        reports.mkdir(parents=True)
        report = reports / "Runner-stale.ips"
        report.write_text(json.dumps({
            "pid": 1234, "bundleInfo": {"CFBundleIdentifier": self.info["CFBundleIdentifier"]},
        }))
        stale = self.smoke.started - 60
        os.utime(report, (stale, stale))
        self.smoke.run()
        self.assertEqual(self.result()["crashes"], [])

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
