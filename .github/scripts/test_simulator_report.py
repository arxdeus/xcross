import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from simulator_report import MARKER, artifact_links, artifact_name, entries, render


class SimulatorReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get("JCODE_SCRATCH_DIR"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.staged = self.root / "staged"

    def stage(self, artifact, app, result=None):
        directory = self.staged / artifact / app
        directory.mkdir(parents=True)
        (directory / "screenshot.png").write_bytes(b"png-" + artifact.encode() + app.encode())
        if result is not None:
            (directory / "result.json").write_text(json.dumps(result))

    def test_collects_every_staged_platform_with_smoke_results(self):
        self.stage("simulator-report-flutter-native", "flutter-example", {"ready_marker_found": True, "launch_retries": ["hung"]})
        self.stage("simulator-report-flutter-windows-11-arm", "flutter-example")
        self.stage("simulator-report-compose-native", "compose", {"ready_marker_found": False})
        found = entries(self.staged)
        self.assertEqual(
            [(entry["kind"], entry["platform"], entry["app"], entry["ready"], entry["launch_retries"]) for entry in found],
            [
                ("compose", "macos-15 (native)", "compose", False, 0),
                ("flutter", "macos-15 (native)", "flutter-example", True, 1),
                ("flutter", "windows-11-arm", "flutter-example", None, 0),
            ],
        )
        self.assertEqual(len({entry["slug"] for entry in found}), 3)

    def test_links_each_entry_to_its_unzipped_screenshot_artifact(self):
        self.stage("simulator-report-flutter-native", "flutter-example", {"ready_marker_found": True})
        self.stage("simulator-report-flutter-windows-2022", "flutter-example", {"ready_marker_found": True})
        self.stage("simulator-report-compose-native", "compose", {"ready_marker_found": False})
        found = entries(self.staged)
        self.assertEqual(
            sorted(artifact_name(entry) for entry in found),
            ["simulator-compose-native-compose.png", "simulator-flutter-native-flutter-example.png",
             "simulator-flutter-windows-2022-flutter-example.png"],
        )
        links = artifact_links([
            {"id": 11, "name": "simulator-flutter-native-flutter-example.png"},
            {"id": 12, "name": "simulator-compose-native-compose.png"},
            {"id": 13, "name": "simulator-flutter-windows-2022-flutter-example.png", "expired": True},
            {"id": 14, "name": "simulator-report-flutter-native"},
            {"id": 15, "name": "flutter-example-simulator-ubuntu-24.04"},
        ], "https://github.com/o/xcross", "77")
        self.assertEqual(links, {
            "simulator-flutter-native-flutter-example.png": "https://github.com/o/xcross/actions/runs/77/artifacts/11",
            "simulator-compose-native-compose.png": "https://github.com/o/xcross/actions/runs/77/artifacts/12",
        })
        report = render(found, "Integration simulator report", links)
        self.assertTrue(report.startswith(MARKER + "\n## Integration simulator report\n"))
        self.assertNotIn("<img", report)
        self.assertNotIn("raw.githubusercontent", report)
        flutter, compose = report.split("### Flutter\n", 1)[1].split("### Compose\n", 1)
        self.assertIn("| **macos-15 (native)** | `flutter-example` | ✅ Ready | 0 | 🖼️ [Open image](https://github.com/o/xcross/actions/runs/77/artifacts/11) |", flutter)
        self.assertIn("| **windows-2022** | `flutter-example` | ✅ Ready | 0 | _unavailable_ |", flutter)
        self.assertIn("| **macos-15 (native)** | `compose` | ❌ Not ready | 0 | 🖼️ [Open image](https://github.com/o/xcross/actions/runs/77/artifacts/12) |", compose)
        self.assertNotIn("artifacts/12", flutter)
        self.assertNotIn("found", report)

    def test_report_names_the_exact_xcross_and_examples_commits(self):
        self.stage("simulator-report-compose-native", "compose")
        report = render(entries(self.staged), "Report", None, (
            ("xcross", "https://github.com/o/xcross", "a" * 40),
            ("xcross_examples", "https://github.com/arxdeus/xcross_examples.git", "b" * 40),
        ))
        self.assertIn(f"xcross: [`{'a' * 12}`](https://github.com/o/xcross/commit/{'a' * 40})", report)
        self.assertIn(f"xcross_examples: [`{'b' * 12}`](https://github.com/arxdeus/xcross_examples/commit/{'b' * 40})", report)
        self.assertIn("xcross_examples: unknown", render([], "Report", None, (("xcross_examples", "", ""),)))

    def test_report_without_artifact_links_still_lists_every_result(self):
        self.stage("simulator-report-compose-native", "compose")
        report = render(entries(self.staged), "Report")
        self.assertIn("| **macos-15 (native)** | `compose` | ⚪ Unknown | 0 | _unavailable_ |", report)

    def test_empty_staging_renders_an_explicit_note_per_section(self):
        self.staged.mkdir()
        report = render([], "Report")
        self.assertIn("No Flutter simulator screenshots were staged.", report)
        self.assertIn("No Compose simulator screenshots were staged.", report)

if __name__ == "__main__":
    unittest.main()
