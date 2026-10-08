import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from simulator_report import MARKER, entries, publish, render


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

    def test_publishes_one_png_per_entry_under_its_slug(self):
        self.stage("simulator-report-flutter-ubuntu-24.04", "flutter-example")
        self.stage("simulator-report-compose-native", "compose")
        destination = self.root / "publish" / "123" / "1"
        found = entries(self.staged)
        publish(found, destination)
        self.assertEqual(sorted(path.name for path in destination.iterdir()),
                         sorted(f"{entry['slug']}.png" for entry in found))
        for entry in found:
            self.assertEqual((destination / f"{entry['slug']}.png").read_bytes(), entry["screenshot"].read_bytes())

    def test_report_embeds_each_screenshot_inline_in_separate_tables(self):
        self.stage("simulator-report-flutter-native", "flutter-example", {"ready_marker_found": True})
        self.stage("simulator-report-flutter-windows-2022", "flutter-example", {"ready_marker_found": True})
        self.stage("simulator-report-compose-native", "compose", {"ready_marker_found": False})
        found = entries(self.staged)
        report = render(found, "Integration simulator report", "https://raw.example/sha/runs/1/1")
        self.assertTrue(report.startswith(MARKER + "\n## Integration simulator report\n"))
        for entry in found:
            self.assertIn(f'<img src="https://raw.example/sha/runs/1/1/{entry["slug"]}.png" width="220">', report)
        self.assertEqual(report.count("<img "), 3)
        self.assertEqual(report.count("<table>"), 2)
        flutter, compose = report.split("### Flutter\n", 1)[1].split("### Compose\n", 1)
        self.assertIn("| windows-2022 | flutter-example | ✅ | 0 |", flutter)
        self.assertIn("compose-native-compose.png", compose)
        self.assertNotIn("compose-native-compose.png", flutter)
        self.assertIn("| macos-15 (native) | compose | ❌ | 0 |", compose)
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

    def test_report_without_published_images_says_so_instead_of_linking(self):
        self.stage("simulator-report-compose-native", "compose")
        report = render(entries(self.staged), "Report", None)
        self.assertNotIn("<img", report)
        self.assertIn("could not be published", report)

    def test_empty_staging_renders_an_explicit_note_per_section(self):
        self.staged.mkdir()
        report = render([], "Report", "https://x")
        self.assertIn("No Flutter simulator screenshots were staged.", report)
        self.assertIn("No Compose simulator screenshots were staged.", report)

if __name__ == "__main__":
    unittest.main()
