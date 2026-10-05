import os
from pathlib import Path
import re
import subprocess
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
                else:
                    self.assertEqual(caches, [])
                uploads = [body for _, _, body in steps(source) if "actions/upload-artifact@" in body]
                if name == "warm-darwin-sdk.yml":
                    self.assertEqual(uploads, [])
                else:
                    self.assertEqual(len(uploads), 1)
                    self.assertEqual(
                        re.findall(r"(?m)^\s+path: (.+)$", uploads[0]),
                        ["${{ runner.temp }}/ios-simulator-smoke"],
                    )

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
        self.assertEqual(re.findall(r"(?m)^      (\w+):$", triggers), ["xcode_xip_url"])
        self.assertIn("required: true", triggers)
        self.assertNotIn("artifactbundle_url", source)
        self.assertNotIn("secrets.", source)
        self.assertNotIn("setup-darwin-sdk", source)
        self.assertIn("os: [ubuntu-24.04, ubuntu-24.04-arm, windows-2022, windows-11-arm]", source)
        self.assertIn("actions: write", job(source, "warm-cache"))
        names = [title for _, title, _ in steps(source)]
        self.assertEqual(names[0], "Mask Xcode xip URL")
        self.assertIn('::add-mask::$XCODE_XIP_URL', step(source, "Mask Xcode xip URL"))
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
        self.assertIn('gh cache delete "$CACHE_KEY" --repo "$GITHUB_REPOSITORY"', delete)
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
                             "CACHE_KEY": "xcross-darwin-linux-x64", "GITHUB_REPOSITORY": "o/r"},
                    )
                    self.assertEqual(result.returncode, expected)

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
