import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import aot_run_smoke
from aot_run_smoke import AotRun, find_app


MARKER = "XCROSS_APP_READY"
VM_URI = "http://127.0.0.1:54321/AbCdEf123=/"


class FakeProcess:
    def __init__(self, test, args, stdout, stderr, **kwargs):
        self.test = test
        self.args = args
        self.kwargs = kwargs
        self.pid = 4242
        self.returncode = None
        self.polls = 0
        self.terminated = False
        self.launched_executable = Path(args[0]).read_bytes()
        stdout.write(test.stdout)
        stderr.write(test.stderr)
        stdout.flush()
        stderr.flush()

    def poll(self):
        self.polls += 1
        if self.returncode is None and self.test.exit_after is not None and self.polls > self.test.exit_after:
            self.returncode = self.test.exit_code
        return self.returncode

    def terminate(self):
        self.terminated = True
        self.returncode = -15

    def wait(self, timeout=None):
        return self.returncode

    def kill(self):
        self.returncode = -9


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


class FakeOpener:
    def __init__(self, test):
        self.test = test

    def open(self, url, timeout=None):
        self.test.urls.append(url)
        method = url[len(VM_URI):].split("?")[0]
        return FakeResponse(json.dumps({"result": self.test.rpc_results[method]}).encode())


class AotRunTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get("JCODE_SCRATCH_DIR"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.app = self.root / "Runner.app"
        self.app.mkdir()
        self.info = {
            "CFBundleIdentifier": "dev.xcross.aot", "CFBundleExecutable": "Runner",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
        }
        self.write_plist()
        (self.app / "Runner").write_bytes(b"runner")
        for name in ("App", "Flutter"):
            framework = self.app / "Frameworks" / f"{name}.framework"
            framework.mkdir(parents=True)
            (framework / name).write_bytes(name.encode())
        (self.app / "Frameworks/libswift_Concurrency.dylib").write_bytes(b"dylib")
        self.original = self.snapshot(self.app)
        self.output = self.root / "evidence"
        self.calls = []
        self.platforms = {}
        self.machine = "arm64"
        self.symbols = "0000 S _kDartSnapshotData\n0000 S _kDartSnapshotText\n0000 S _kDartVmSnapshotData\n"
        self.stdout = f"flutter: {MARKER}\n"
        self.stderr = ""
        self.exit_after = None
        self.exit_code = 0
        self.processes = []
        self.urls = []
        self.rpc_results = {
            "getVM": {
                "version": "3.9.0", "operatingSystem": "ios", "targetCPU": "arm64",
                "isolates": [{"id": "isolates/1", "name": "main"}, {"id": "isolates/2", "name": "helper"}],
            },
            "getIsolate": {"runnable": True, "rootLib": {"uri": "package:showcase/main.dart"}},
        }
        patch("aot_run_smoke.subprocess.run", side_effect=self.fake_run).start()
        self.popen = patch("aot_run_smoke.subprocess.Popen", side_effect=self.fake_popen).start()
        patch("aot_run_smoke.urllib.request.build_opener", side_effect=lambda *_: FakeOpener(self)).start()
        self.addCleanup(patch.stopall)
        patch("aot_run_smoke.time.sleep").start()
        self.clock = 0
        patch("aot_run_smoke.time.monotonic", side_effect=self.monotonic).start()

    def monotonic(self):
        self.clock += 0.5
        return self.clock

    def write_plist(self):
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))

    @staticmethod
    def snapshot(app):
        return {str(path.relative_to(app)): path.read_bytes() for path in sorted(app.rglob("*")) if path.is_file()}

    def fake_run(self, args, **kwargs):
        self.calls.append(args)
        stdout = ""
        if args[0] == "/usr/bin/uname":
            stdout = self.machine + "\n"
        elif "-show-build" in args:
            binary = Path(args[-1])
            platform = self.platforms.get(binary.name, "IOS")
            stdout = f"{binary} (architecture arm64):\nLoad command 9\n      cmd LC_BUILD_VERSION\n" \
                f"  cmdsize 32\n platform {platform}\n    minos 13.0\n      sdk 18.2\n   ntools 1\n"
        elif "-set-build-version" in args:
            source = Path(args[-1])
            Path(args[args.index("-output") + 1]).write_bytes(source.read_bytes() + b"+maccatalyst")
        elif "nm" in args:
            stdout = self.symbols
        return subprocess.CompletedProcess(args, 0, stdout)

    def fake_popen(self, args, **kwargs):
        process = FakeProcess(self, args, **kwargs)
        self.processes.append(process)
        return process

    def make_run(self, mode="release", **kwargs):
        kwargs.setdefault("launch_timeout", 3)
        kwargs.setdefault("observe_seconds", 2)
        return AotRun(self.app, self.output, mode, MARKER, **kwargs)

    def result(self):
        return json.loads((self.output / "result.json").read_text())

    def assert_fails(self, pattern, mode="release", launched=True):
        run = self.make_run(mode)
        with self.assertRaisesRegex(RuntimeError, pattern):
            run.run()
        result = self.result()
        self.assertFalse(result["passed"])
        self.assertRegex(result["error"], pattern)
        if launched:
            self.assertEqual(len(self.processes), 1)
            self.assertIsNotNone(self.processes[0].returncode)
        else:
            self.popen.assert_not_called()
        self.assertEqual(self.snapshot(self.app), self.original)
        return run, result

    def retarget_calls(self):
        return [args for args in self.calls if "-set-build-version" in args]

    def test_release_success(self):
        run = self.make_run()
        run.run()
        result = self.result()
        self.assertTrue(result["passed"])
        self.assertIsNone(result["error"])
        self.assertTrue(result["ready_marker_found"])
        self.assertIsNone(result["vm_service"])
        self.assertEqual(result["pid"], 4242)
        self.assertEqual(result["failures"], [])
        process = self.processes[0]
        self.assertTrue(process.terminated)
        self.assertEqual(process.launched_executable, b"runner+maccatalyst")
        self.assertEqual(process.kwargs["env"]["OS_ACTIVITY_DT_MODE"], "1")
        self.assertTrue(process.kwargs["start_new_session"])
        self.assertEqual(self.urls, [])
        retargets = self.retarget_calls()
        self.assertEqual(len(retargets), 4)
        for args in retargets:
            self.assertEqual(args[args.index("-set-build-version") + 1:][:3], ["maccatalyst", "13.0", "18.2"])
            self.assertIn("-replace", args)
            self.assertFalse(Path(args[-1]).is_relative_to(self.app))
        self.assertEqual(
            sorted(Path(args[-1]).name for args in retargets),
            ["App", "Flutter", "Runner", "libswift_Concurrency.dylib"],
        )
        signs = [args for args in self.calls if args[0] == "/usr/bin/codesign"]
        self.assertTrue(any("--sign" in args and args[-1].endswith("Runner.app") for args in signs))
        self.assertTrue(any("--verify" in args for args in signs))
        self.assertTrue(all(not Path(args[-1]).is_relative_to(self.app) for args in signs))
        self.assertEqual(self.snapshot(self.app), self.original)
        self.assertFalse(Path(process.kwargs["cwd"]).exists())
        self.assertIn(MARKER, (self.output / "app-stdout.log").read_text())

    def test_profile_success(self):
        self.stderr = f"The Dart VM service is listening on {VM_URI}\n"
        run = self.make_run("profile")
        run.run()
        result = self.result()
        self.assertTrue(result["passed"])
        self.assertEqual(result["vm_service"], VM_URI)
        self.assertEqual(result["root_library"], "package:showcase/main.dart")
        self.assertEqual(self.urls, [VM_URI + "getVM", VM_URI + "getIsolate?isolateId=isolates%2F1"])
        vm = json.loads((self.output / "vm-service.json").read_text())
        self.assertEqual(vm["rootLib"], "package:showcase/main.dart")
        self.assertTrue(vm["runnable"])
        self.assertEqual(vm["targetCPU"], "arm64")
        self.assertTrue(self.processes[0].terminated)

    def test_release_with_vm_service_fails(self):
        self.stderr = f"The Dart VM service is listening on {VM_URI}\n"
        self.assert_fails("serves a VM Service")
        self.assertEqual(self.urls, [])

    def test_profile_without_vm_service_fails(self):
        self.assert_fails("Expected one VM Service URI", "profile")

    def test_profile_with_two_vm_services_fails(self):
        self.stderr = f"The Dart VM service is listening on {VM_URI}\n" \
            "The Dart VM service is listening on http://127.0.0.1:1/x/\n"
        self.assert_fails("Expected one VM Service URI", "profile")

    def test_profile_without_main_isolate_fails(self):
        self.stderr = f"The Dart VM service is listening on {VM_URI}\n"
        self.rpc_results["getVM"]["isolates"] = [{"id": "isolates/2", "name": "helper"}]
        self.assert_fails("Expected one main isolate", "profile")

    def test_profile_non_runnable_isolate_fails(self):
        self.stderr = f"The Dart VM service is listening on {VM_URI}\n"
        self.rpc_results["getIsolate"]["runnable"] = False
        self.assert_fails("Main isolate is not runnable", "profile")

    def test_profile_unexpected_root_library_fails(self):
        self.stderr = f"The Dart VM service is listening on {VM_URI}\n"
        for uri in ("file:///tmp/main.dart", "package:showcase/other.dart", None):
            with self.subTest(uri=uri):
                self.processes.clear()
                self.output = self.root / f"evidence-{len(self.urls)}"
                self.rpc_results["getIsolate"]["rootLib"] = {"uri": uri} if uri else None
                self.assert_fails("Unexpected root library", "profile")

    def test_missing_ready_marker_fails(self):
        self.stdout = "flutter: still booting\n"
        run, result = self.assert_fails("App-ready marker not observed")
        self.assertFalse(result["ready_marker_found"])
        self.assertTrue(self.processes[0].terminated)
        self.assertEqual(result["exit_status"], None)

    def test_exit_before_ready_fails(self):
        self.stdout = ""
        self.exit_after = 1
        self.exit_code = 3
        run, result = self.assert_fails(r"exited before it was ready \(status 3\)")
        self.assertEqual(result["exit_status"], 3)
        self.assertFalse(self.processes[0].terminated)

    def test_exit_during_observation_fails(self):
        self.exit_after = 2
        self.exit_code = -6
        run, result = self.assert_fails(r"exited during observation \(status -6\)")
        self.assertTrue(result["ready_marker_found"])

    def test_engine_failure_after_marker_fails(self):
        for line in ("ImpellerValidationBreak: Break on 'ImpellerValidationBreak'", "Thread 0 crashed with SIGABRT",
                     "[FATAL:flutter/shell/common/shell.cc(1)] boom", "Could not create render pipeline"):
            with self.subTest(line=line):
                self.processes.clear()
                self.output = self.root / f"evidence-{abs(hash(line))}"
                self.stderr = line + "\n"
                run, result = self.assert_fails("crash or engine failure")
                self.assertTrue(result["ready_marker_found"])
                self.assertEqual(result["failures"], [line])

    def test_non_device_mach_o_rejected(self):
        for name in ("Runner", "Flutter", "App", "libswift_Concurrency.dylib"):
            for platform in ("IOSSIMULATOR", "MACCATALYST"):
                with self.subTest(name=name, platform=platform):
                    self.output = self.root / f"evidence-{name}-{platform}"
                    self.platforms = {name: platform}
                    self.assert_fails(f"Not an arm64 iOS device Mach-O \\({platform}\\)", launched=False)
                    self.assertEqual(self.retarget_calls(), [])

    def test_missing_build_version_rejected(self):
        self.platforms = {"Flutter": "IOS"}
        original = self.fake_run

        def run(args, **kwargs):
            result = original(args, **kwargs)
            if "-show-build" in args and args[-1].endswith("Flutter"):
                result.stdout = "Flutter (architecture arm64):\n"
            return result

        patch("aot_run_smoke.subprocess.run", side_effect=run).start()
        self.assert_fails("No arm64 LC_BUILD_VERSION", launched=False)

    def test_missing_snapshot_symbols_rejected(self):
        for symbols in ("0000 S _kDartSnapshotData\n", "0000 S _main\n", ""):
            with self.subTest(symbols=symbols):
                self.output = self.root / f"evidence-{len(symbols)}"
                self.symbols = symbols
                self.assert_fails("is not an AOT snapshot", launched=False)
                self.assertEqual(self.retarget_calls(), [])

    def test_missing_app_framework_rejected(self):
        (self.app / "Frameworks/App.framework/App").unlink()
        self.original = self.snapshot(self.app)
        self.assert_fails("App.framework/App is missing", launched=False)

    def test_simulator_info_plist_rejected(self):
        self.info["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
        self.write_plist()
        self.original = self.snapshot(self.app)
        self.assert_fails("Expected an iPhoneOS device app", launched=False)
        self.assertFalse(any("vtool" in args for args in self.calls))

    def test_unsafe_executable_rejected(self):
        for executable in ("../Runner", "Sub/Runner", "", None):
            with self.subTest(executable=executable):
                self.output = self.root / f"evidence-{executable!r}".replace("/", "_")
                if executable is None:
                    self.info.pop("CFBundleExecutable", None)
                else:
                    self.info["CFBundleExecutable"] = executable
                self.write_plist()
                self.original = self.snapshot(self.app)
                self.assert_fails("Invalid app executable name", launched=False)

    def test_missing_executable_rejected(self):
        self.info["CFBundleExecutable"] = "Missing"
        self.write_plist()
        self.original = self.snapshot(self.app)
        self.assert_fails("App executable is missing", launched=False)

    def test_non_arm64_host_rejected(self):
        self.machine = "x86_64"
        self.assert_fails("Expected native macOS ARM64, got x86_64", launched=False)
        self.assertEqual(self.calls, [["/usr/bin/uname", "-m"]])

    def test_output_with_previous_evidence_rejected(self):
        self.output.mkdir()
        (self.output / "result.json").write_text("{}")
        with self.assertRaisesRegex(RuntimeError, "must not contain evidence"):
            self.make_run()
        self.assertEqual(self.calls, [])

    def test_empty_existing_output_accepted(self):
        self.output.mkdir()
        self.make_run().run()
        self.assertTrue(self.result()["passed"])

    def test_find_app(self):
        products = self.root / "products"
        products.mkdir()
        with self.assertRaisesRegex(RuntimeError, "found 0"):
            find_app(products)
        (products / "One.app").mkdir()
        self.assertEqual(find_app(products), products / "One.app")
        (products / "Two.app").mkdir()
        with self.assertRaisesRegex(RuntimeError, "found 2"):
            find_app(products)
        self.assertEqual(find_app(self.app), self.app)

    def test_constructor_resolves_directory(self):
        run = AotRun(self.root, self.output, "release", MARKER)
        self.assertEqual(run.source, self.app)

    def test_cli_rejects_invalid_arguments(self):
        cases = (
            ["--observe-seconds", "4"],
            ["--ready-marker", "   "],
            ["--launch-timeout", "0"],
            ["--mode", "debug"],
        )
        for extra in cases:
            with self.subTest(extra=extra):
                argv = ["aot_run_smoke.py", str(self.app), "--mode", "release", "--ready-marker", MARKER,
                        "--output", str(self.output)] + extra
                with patch.object(sys, "argv", argv), patch("sys.stderr", new_callable=io.StringIO), \
                        patch("aot_run_smoke.AotRun") as run:
                    with self.assertRaises(SystemExit) as raised:
                        aot_run_smoke.main()
                self.assertEqual(raised.exception.code, 2)
                run.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_cli_success(self):
        argv = ["aot_run_smoke.py", str(self.root), "--mode", "release", "--ready-marker", MARKER,
                "--output", str(self.output), "--observe-seconds", "5", "--launch-timeout", "3"]
        with patch.object(sys, "argv", argv), patch("aot_run_smoke.signal.signal"), \
                patch("sys.stdout", new_callable=io.StringIO) as stdout:
            aot_run_smoke.main()
        self.assertIn("Runner.app (release) ran as Mac Catalyst", stdout.getvalue())
        self.assertIn("no VM Service", stdout.getvalue())
        self.assertTrue(self.result()["passed"])


if __name__ == "__main__":
    unittest.main()
