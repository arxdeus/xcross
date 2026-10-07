import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
ACTION = ROOT / ".github/actions/setup-darwin-sdk/action.yml"
WORKFLOWS = ROOT / ".github/workflows"


def steps(source):
    return re.findall(
        r"(?m)^( +)- name: ([^\n]+)\n(.*?)(?=^\1- name: |\Z)",
        source, re.S,
    )


def step(source, name):
    return next(body for _, title, body in steps(source) if title == name)


def script(body):
    return textwrap.dedent(body.split("run: |\n", 1)[1]).rstrip() + "\n"


def job(source, name):
    return re.search(
        rf"(?ms)^  {re.escape(name)}:\n(.*?)(?=^  [\w-]+:\n|\Z)", source,
    ).group(1)


class CacheMissTests(unittest.TestCase):
    def test_cache_miss_fails_and_points_to_warm_workflow(self):
        action = ACTION.read_text()
        miss = step(action, "Require warmed Darwin SDK cache")
        self.assertIn("if: steps.darwin-cache.outputs.cache-hit != 'true'", miss)
        result = subprocess.run(
            ["bash", "-c", script(miss)], capture_output=True, text=True,
            env={**os.environ, "CACHE_KEY": "xcross-darwin-linux-x64"},
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("::error::", result.stdout)
        self.assertIn("xcross-darwin-linux-x64", result.stdout)
        self.assertIn('"Warm Darwin SDK cache"', result.stdout)
        self.assertIn("xcode_xip_url", result.stdout)

    def test_action_only_restores_and_never_downloads_or_saves(self):
        action = ACTION.read_text()
        self.assertNotIn("inputs:", action)
        self.assertNotIn("artifactbundle-url", action)
        self.assertNotIn("urllib", action)
        self.assertNotIn("actions/cache/save@", action)
        self.assertNotIn("- name: Download Darwin SDK", action)
        names = [title for _, title, _ in steps(action)]
        self.assertLess(names.index("Restore Darwin SDK cache"), names.index("Require warmed Darwin SDK cache"))
        for kept in ("Refresh clang builtin headers", "Materialize Swift compatibility resources", "Verify Darwin Swift SDK"):
            self.assertLess(names.index("Require warmed Darwin SDK cache"), names.index(kept))


class WorkflowSecurityTests(unittest.TestCase):
    def test_sdk_cached_per_host_and_never_uploaded_as_artifact(self):
        action = ACTION.read_text()
        self.assertIn("os.environ[\"RUNNER_OS\"]", step(action, "Resolve xcross Swift SDK path"))
        self.assertIn("os.environ[\"RUNNER_ARCH\"]", step(action, "Resolve xcross Swift SDK path"))
        self.assertNotIn("revision", action)
        self.assertIn('os.environ["RUNNER_OS"].lower()', action)
        self.assertIn("uses: actions/cache/restore@", step(action, "Restore Darwin SDK cache"))
        for name in ("integration.yml", "compose-integration.yml", "warm-darwin-sdk.yml"):
            source = (WORKFLOWS / name).read_text()
            with self.subTest(path=name):
                caches = re.findall(r"(?i)actions/cache[^\s]*", source)
                if name == "warm-darwin-sdk.yml":
                    self.assertEqual(len(caches), 1)
                    self.assertTrue(caches[0].startswith("actions/cache/save@"))
                elif name == "integration.yml":
                    cached = [body for _, _, body in steps(source) if "actions/cache" in body]
                    self.assertEqual(len(cached), len(caches))
                    for body in cached:
                        paths = re.findall(r"(?m)^ {12}(\S.*)$", body.split("path: |\n", 1)[1])
                        self.assertTrue(paths)
                        for path in paths:
                            self.assertRegex(path, r"/xcross(-cache)?/open-apple-macros/\*/(identity\.json|OpenAppleMacrosServer\*?)$")
                        self.assertIn("key: open-apple-macros-", body)
                else:
                    self.assertEqual(caches, [])
                uploads = [body for _, _, body in steps(source) if "actions/upload-artifact@" in body]
                if name == "warm-darwin-sdk.yml":
                    self.assertEqual(uploads, [])
                else:
                    paths = sorted(
                        path for body in uploads for path in re.findall(r"(?m)^\s+path: (.+)$", body)
                    )
                    smoke = "${{ runner.temp }}/ios-simulator-smoke"
                    screenshots = smoke + "/**/screenshot*.png"
                    allowed = {smoke, screenshots}
                    if name == "integration.yml":
                        allowed.add("examples/flutter_example/build/xcross-ios-simulator/*.app")
                    self.assertEqual(len(paths), len(uploads))
                    self.assertTrue(paths)
                    self.assertLessEqual(set(paths), allowed)
                    self.assertEqual(paths.count(smoke), paths.count(screenshots))
                    self.assertIn(screenshots, paths)
                    for body in uploads:
                        path = re.search(r"(?m)^\s+path: (.+)$", body).group(1)
                        condition = re.search(r"(?m)^\s+if: (.+)$", body)
                        condition = condition and condition.group(1)
                        if path == smoke:
                            self.assertEqual(condition, "failure() || cancelled()")
                        elif path == screenshots:
                            self.assertEqual(condition, "success()")

    def test_trusted_cross_host_jobs_restore_cache_without_secrets_and_forks_keep_toolchain_checks(self):
        for filename, job_name in (("integration.yml", "flutter-build"), ("compose-integration.yml", "compose-build")):
            with self.subTest(workflow=filename):
                source = (WORKFLOWS / filename).read_text()
                build = job(source, job_name)
                gate = step(build, "Resolve Darwin SDK availability")
                self.assertIn("github.event_name == 'pull_request'", gate)
                self.assertIn("github.event.pull_request.head.repo.full_name != github.repository", gate)
                for fork, expected in (("true", "false"), ("false", "true")):
                    with tempfile.TemporaryDirectory(dir=os.environ.get("JCODE_SCRATCH_DIR")) as directory:
                        output = Path(directory) / "output"
                        result = subprocess.run(
                            ["bash", "-c", script(gate)], check=True, capture_output=True, text=True,
                            env={**os.environ, "IS_FORK_PR": fork, "GITHUB_OUTPUT": str(output)},
                        )
                        self.assertEqual(output.read_text(), f"available={expected}\n")
                        if fork == "true":
                            self.assertIn("toolchain", result.stdout)
                download = step(build, "Download Darwin SDK")
                self.assertIn("if: steps.darwin.outputs.available == 'true'", download)
                self.assertIn("uses: ./.github/actions/setup-darwin-sdk", download)
                self.assertNotIn("with:", download)
                self.assertNotIn("secrets.", source)
                self.assertNotIn("steps.darwin.outputs.available", step(build, "Checkout"))

    def test_every_workflow_pins_the_minimum_supported_swift_release(self):
        x64 = "76169A85BCBA82854A0CD8F9655FFB74B3758D60C35A245457510095F2823C03"
        arm64 = "F48E393634995CB589F547E40D64673BC641CA76B099697BA8227A8904BE4A49"
        for filename, job_name, pins in (
            ("integration.yml", "flutter-build",
             {"SWIFT_WINDOWS_X64_SHA256": x64, "SWIFT_WINDOWS_ARM64_SHA256": arm64}),
            ("compose-integration.yml", "compose-build", {"SWIFT_WINDOWS_SHA256": x64}),
            ("warm-darwin-sdk.yml", "warm-cache",
             {"SWIFT_WINDOWS_X64_SHA256": x64, "SWIFT_WINDOWS_ARM64_SHA256": arm64}),
        ):
            with self.subTest(workflow=filename):
                source = (WORKFLOWS / filename).read_text()
                self.assertIn("\n  SWIFT_VERSION: 6.4.0\n", source)
                for key, value in pins.items():
                    self.assertIn(f"\n  {key}: >-\n    {value}\n", source)
                self.assertNotRegex(source, r"6\.3\.\d|matrix\.swift|swift: \[")
                build = job(source, job_name)
                linux = step(build, "Install pinned Swift on Linux")
                self.assertIn("if: runner.os == 'Linux'", linux)
                for needle in ("ubuntu2404-aarch64", "ubuntu2404", '--verify "$download/$archive.sig"'):
                    self.assertIn(needle, linux)
                tag = re.search(r'(?m)^ +(tag="[^\n]+")$', linux).group(1)
                result = subprocess.run(
                    ["bash", "-c", f'{tag}; printf %s "$tag"'], check=True, capture_output=True, text=True,
                    env={**os.environ, "SWIFT_VERSION": "6.4.0"},
                )
                self.assertEqual(result.stdout, "(swift-6.4-RELEASE)")
                self.assertIn('gzip -dcf "$download/all-keys.asc" > "$download/all-keys.txt"', linux)
                self.assertIn('--import "$download/all-keys.txt"', linux)
                self.assertIn("(swift-$($env:SWIFT_VERSION -replace '\\.0$')-RELEASE)", step(build, "Install official Swift and LLVM on Windows"))

    def test_native_simulator_jobs_use_installed_xcode_without_secrets(self):
        for filename, job_name in (("integration.yml", "flutter-simulator"), ("compose-integration.yml", "compose-simulator")):
            with self.subTest(workflow=filename):
                native = job((WORKFLOWS / filename).read_text(), job_name)
                self.assertIn("runs-on: macos-15", native)
                self.assertIn("uses: ./.github/actions/configure-xcode", native)
                self.assertIn('xcross sdk install "$XCODE_APP"', native)
                self.assertNotIn("secrets.", native)
                self.assertNotIn("setup-darwin-sdk", native)

    def test_warm_workflow_installs_xip_with_xcross_and_replaces_each_host_cache(self):
        source = (WORKFLOWS / "warm-darwin-sdk.yml").read_text()
        self.assertIn("name: Warm Darwin SDK cache", source)
        self.assertIn(
            "  workflow_dispatch:\n    inputs:\n      xcode_xip_url:\n", source,
        )
        triggers = re.search(r"(?ms)^on:\n(.*?)^\S", source).group(1)
        self.assertEqual(re.findall(r"(?m)^      (\w+):$", triggers), ["xcode_xip_url", "source_ref"])
        self.assertIn("required: true", triggers)
        self.assertIn("ref: ${{ inputs.source_ref }}", step(source, "Checkout"))
        self.assertNotIn("artifactbundle_url", source)
        self.assertNotIn("secrets.", source)
        self.assertNotIn("setup-darwin-sdk", source)
        self.assertIn("os: [ubuntu-24.04, ubuntu-24.04-arm, windows-2022, windows-11-arm]", source)
        self.assertIn("actions: write", job(source, "warm-cache"))
        names = [title for _, title, _ in steps(source)]
        self.assertEqual(names[0], "Mask Xcode xip URL")
        mask = step(source, "Mask Xcode xip URL")
        self.assertNotIn("${{", mask)
        with tempfile.TemporaryDirectory(dir=os.environ.get("JCODE_SCRATCH_DIR")) as directory:
            event = Path(directory) / "event.json"
            event.write_text('{"inputs": {"xcode_xip_url": "https://host.invalid/X.xip?sig=s"}}')
            result = subprocess.run(
                [sys.executable, "-c", script(mask)], check=True, capture_output=True, text=True,
                env={**os.environ, "GITHUB_EVENT_PATH": str(event)},
            )
        self.assertEqual(result.stdout, "::add-mask::https://host.invalid/X.xip?sig=s\n")
        download = step(source, "Download Xcode xip")
        self.assertIn("--user-agent curl/", download)
        self.assertIn("--retry", download)
        self.assertIn('"$RUNNER_TEMP/Xcode.xip"', download)
        self.assertRegex(script(step(source, "Install Darwin SDK with xcross")), r'(?m)^xcross sdk install "\$XCODE_XIP"$')
        self.assertIn("if: always()", step(source, "Delete Xcode xip"))
        verify = step(source, "Verify installed Darwin SDK")
        for needle in ("iPhoneOS.platform", "iPhoneSimulator.platform", '"--swift-sdks-path"'):
            self.assertIn(needle, verify)
        delete = step(source, "Delete previous Darwin SDK cache")
        self.assertIn('gh cache delete "$CACHE_KEY" --repo "$GITHUB_REPOSITORY" --ref "$GITHUB_REF"', delete)
        self.assertIn("GH_TOKEN: ${{ github.token }}", delete)
        save = step(source, "Save Darwin SDK cache")
        self.assertIn("key: ${{ steps.sdk-path.outputs.cache-key }}", save)
        self.assertIn("path: ${{ steps.sdk-path.outputs.bundle }}", save)
        self.assertNotIn("if:", save)
        order = [
            "Download Xcode xip", "Install Darwin SDK with xcross", "Delete Xcode xip",
            "Verify installed Darwin SDK", "Delete previous Darwin SDK cache", "Save Darwin SDK cache",
        ]
        self.assertEqual([n for n in names if n in order], order)
        self.assertEqual(
            script(step(source, "Resolve xcross Swift SDK path")),
            script(step(ACTION.read_text(), "Resolve xcross Swift SDK path")),
        )

    def test_warm_cache_delete_tolerates_only_missing_caches(self):
        delete = step((WORKFLOWS / "warm-darwin-sdk.yml").read_text(), "Delete previous Darwin SDK cache")
        with tempfile.TemporaryDirectory(dir=os.environ.get("JCODE_SCRATCH_DIR")) as directory:
            fake = Path(directory) / "gh"
            for message, status, expected in (
                ("deleted", 0, 0),
                ("X Could not find a cache matching xcross-darwin-linux-x64", 1, 0),
                ("HTTP 403: Resource not accessible by integration", 1, 1),
            ):
                with self.subTest(message=message):
                    fake.write_text(f"#!/bin/bash\necho '{message}' >&2\nexit {status}\n")
                    fake.chmod(0o755)
                    result = subprocess.run(
                        ["bash", "-c", script(delete)], capture_output=True, text=True,
                        env={**os.environ, "PATH": f"{directory}:{os.environ['PATH']}",
                             "CACHE_KEY": "xcross-darwin-linux-x64", "GITHUB_REPOSITORY": "o/r",
                             "GITHUB_REF": "refs/heads/main"},
                    )
                    self.assertEqual(result.returncode, expected)

    def test_windows_ci_setup_runs_the_checkout_direct_script(self):
        install = step(job((WORKFLOWS / "integration.yml").read_text(), "flutter-build"), "Install official Swift and LLVM on Windows")
        self.assertIn("$setupScript = (Resolve-Path 'setup\\direct.ps1').Path", install)
        self.assertIn('xcross.exe" setup --yes', install)
        for manager in ("winget", "scoop", "choco"):
            with self.subTest(manager=manager):
                self.assertNotIn(f"setup\\{manager}.ps1", install)

    def test_setup_scripts_keep_session_path_when_refreshing_environment(self):
        for name in ("direct", "winget", "scoop", "choco"):
            with self.subTest(script=name):
                source = (ROOT / f"setup/{name}.ps1").read_text()
                refresh = re.search(r"(?ms)^function Update-SessionEnvironment \{\n(.*?)^\}", source)
                self.assertIsNotNone(refresh)
                body = refresh.group(1)
                self.assertIn("$session = @($env:Path -split ';'", body)
                self.assertRegex(body, r"(?m)^  \$env:Path = \(@\(\$session\) \+ \$registered")
                self.assertNotRegex(body, r"(?m)^  \$env:Path = \(@\(\$machine, \$user\)")

    def test_direct_setup_installs_a_missing_pinned_llvm_directory(self):
        source = (ROOT / "setup/direct.ps1").read_text()
        missing = re.search(r"(?m)^\$llvmDirMissing = (.+)$", source)
        self.assertIsNotNone(missing)
        self.assertIn("$LlvmDir -and", missing.group(1))
        self.assertIn("ld64.lld.exe", missing.group(1))
        gate = re.search(r"(?m)^if \(\(Test-Wanted 'llvm'\) -and \((.+)\)\) \{$", source)
        self.assertIsNotNone(gate)
        self.assertTrue(gate.group(1).startswith("$llvmDirMissing -or "))
        self.assertLess(missing.start(), gate.start())

    def test_test_workflows_run_manually_without_inputs(self):
        for name in ("architecture.yml", "integration.yml", "compose-integration.yml"):
            with self.subTest(workflow=name):
                source = (WORKFLOWS / name).read_text()
                triggers = re.search(r"(?ms)^on:\n(.*?)^\S", source).group(1)
                self.assertRegex(triggers, r"(?m)^  workflow_dispatch:\s*$")
                self.assertRegex(triggers, r"(?m)^  pull_request:\s*$")
                self.assertNotIn("inputs", triggers)


if __name__ == "__main__":
    unittest.main()
