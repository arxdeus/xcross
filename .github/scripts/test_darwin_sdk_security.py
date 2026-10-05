import contextlib
import io
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import textwrap
import unittest
from unittest.mock import patch
import urllib.error


ROOT = Path(__file__).resolve().parents[2]
ACTION = ROOT / ".github/actions/setup-darwin-sdk/action.yml"
WORKFLOWS = ROOT / ".github/workflows"
URL = "https://source.invalid/private/sdk.tar.gz?token=synthetic-secret"


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


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get("JCODE_SCRATCH_DIR"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.parent = self.root / "swift-sdks"
        self.bundle = self.parent / "xcross-darwin.artifactbundle"
        self.archive = self.root / "xcross-darwin.artifactbundle.tar.gz"
        self.code = compile(script(step(ACTION.read_text(), "Download Darwin SDK")), str(ACTION), "exec")
        self.env = {
            "DARWIN_ARTIFACTBUNDLE_URL": URL,
            "XCROSS_SWIFT_SDKS_PATH": str(self.parent),
            "XCROSS_DARWIN_BUNDLE": str(self.bundle),
            "RUNNER_TEMP": str(self.root),
        }
        self.log = io.StringIO()

    def execute(self):
        with patch.dict(os.environ, self.env), contextlib.redirect_stdout(self.log), contextlib.redirect_stderr(self.log):
            exec(self.code, {})

    def payload(self, valid=True):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w:gz") as archive:
            if valid:
                member = tarfile.TarInfo("xcross-darwin.artifactbundle/info.json")
                member.size = 2
                archive.addfile(member, io.BytesIO(b"{}"))
        return output.getvalue()

    def test_missing_url_fails_actionably_without_network_even_with_existing_bundle(self):
        self.bundle.mkdir(parents=True)
        (self.bundle / "info.json").write_text("stale")
        for value in ("", " \n "):
            with self.subTest(value=value), patch("urllib.request.urlopen") as download:
                self.env["DARWIN_ARTIFACTBUNDLE_URL"] = value
                with self.assertRaises(SystemExit) as failure:
                    self.execute()
                self.assertEqual(failure.exception.code, 1)
                download.assert_not_called()
                self.assertIn("Set the repository secret DARWIN_ARTIFACTBUNDLE_URL", self.log.getvalue())
                self.assertFalse(self.archive.exists())

    def test_each_run_downloads_fresh_sdk_and_removes_archive(self):
        for _ in range(2):
            self.bundle.mkdir(parents=True, exist_ok=True)
            stale = self.bundle / "stale-sdk"
            stale.write_text("must not be reused")
            with patch("urllib.request.urlopen", return_value=io.BytesIO(self.payload())) as download:
                self.execute()
            download.assert_called_once_with(URL, timeout=120)
            self.assertEqual((self.bundle / "info.json").read_text(), "{}")
            self.assertFalse(stale.exists())
            self.assertFalse(self.archive.exists())
        self.assertNotIn(URL, self.log.getvalue())
        self.assertNotIn("synthetic-secret", self.log.getvalue())

    def test_download_exceptions_cannot_leak_urls_or_credentials(self):
        redirected = "https://redirect.invalid/encoded-secret?credential=transformed-secret"
        errors = (
            urllib.error.HTTPError(URL, 403, redirected, None, None),
            urllib.error.URLError(f"{URL} {redirected}"),
            ValueError(f"invalid URL {URL}"),
            OSError(f"{URL} {redirected}"),
            TimeoutError(URL),
        )
        for error in errors:
            with self.subTest(error=type(error).__name__), patch("urllib.request.urlopen", side_effect=error):
                with self.assertRaises(SystemExit) as failure:
                    self.execute()
                self.assertEqual(failure.exception.code, 1)
                self.assertTrue(failure.exception.__suppress_context__)
                self.assertFalse(self.archive.exists())
        self.assertIn("Darwin SDK download failed", self.log.getvalue())
        for sensitive in (URL, redirected, "synthetic-secret", "transformed-secret", "Traceback"):
            self.assertNotIn(sensitive, self.log.getvalue())

    def test_response_read_failure_is_redacted_and_partial_archive_removed(self):
        response = io.BytesIO(b"partial")
        with patch.object(response, "read", side_effect=OSError(URL)), patch("urllib.request.urlopen", return_value=response):
            with self.assertRaises(SystemExit) as failure:
                self.execute()
        self.assertEqual(failure.exception.code, 1)
        self.assertTrue(failure.exception.__suppress_context__)
        self.assertNotIn(URL, self.log.getvalue())
        self.assertFalse(self.archive.exists())

    def test_invalid_bundle_fails_and_removes_archive(self):
        with patch("urllib.request.urlopen", return_value=io.BytesIO(self.payload(valid=False))):
            with self.assertRaises(SystemExit) as failure:
                self.execute()
        self.assertEqual(failure.exception.code, 1)
        self.assertIn("Archive must contain xcross-darwin.artifactbundle", self.log.getvalue())
        self.assertFalse(self.archive.exists())

    def test_extraction_failure_removes_archive(self):
        with patch("urllib.request.urlopen", return_value=io.BytesIO(self.payload())), patch(
            "subprocess.run", side_effect=subprocess.CalledProcessError(1, "tar"),
        ):
            with self.assertRaises(subprocess.CalledProcessError):
                self.execute()
        self.assertFalse(self.archive.exists())
        self.assertNotIn(URL, self.log.getvalue())


class WorkflowSecurityTests(unittest.TestCase):
    def test_no_sdk_cache_restore_save_or_artifact_upload(self):
        sources = [ACTION, *(WORKFLOWS / name for name in (
            "integration.yml", "compose-integration.yml", "warm-darwin-sdk.yml",
        ))]
        for path in sources:
            source = path.read_text()
            with self.subTest(path=path.name):
                self.assertNotRegex(source, r"(?i)actions/cache(?:[/@\s]|$)")
                self.assertNotIn("cache-revision", source)
                self.assertNotIn("cache-key", source)
                uploads = [body for _, _, body in steps(source) if "actions/upload-artifact@" in body]
                if path.name in ("integration.yml", "compose-integration.yml"):
                    self.assertEqual(len(uploads), 1)
                    self.assertEqual(
                        re.findall(r"(?m)^\s+path: (.+)$", uploads[0]),
                        ["${{ runner.temp }}/ios-simulator-smoke"],
                    )
                else:
                    self.assertEqual(uploads, [])

    def test_only_trusted_cross_host_calls_receive_secret_and_forks_keep_toolchain_checks(self):
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
                self.assertIn("artifactbundle-url: ${{ secrets.DARWIN_ARTIFACTBUNDLE_URL }}", download)
                self.assertEqual(source.count("secrets.DARWIN_ARTIFACTBUNDLE_URL"), 1)
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

    def test_dispatch_validates_source_without_plaintext_url_inputs(self):
        source = (WORKFLOWS / "warm-darwin-sdk.yml").read_text()
        self.assertIn("name: Validate Darwin SDK source", source)
        self.assertIn("workflow_dispatch:", source)
        self.assertNotIn("inputs:", source)
        self.assertNotIn("inputs.", source)
        self.assertIn("os: [ubuntu-24.04, ubuntu-24.04-arm, windows-2022, windows-11-arm]", source)
        self.assertIn("artifactbundle-url: ${{ secrets.DARWIN_ARTIFACTBUNDLE_URL }}", source)
        self.assertIn("- name: Verify Darwin Swift SDK", ACTION.read_text())
        self.assertNotIn("Warm Darwin SDK cache", source)


if __name__ == "__main__":
    unittest.main()
