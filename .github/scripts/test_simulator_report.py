import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from simulator_report import entries, publish, render


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
        self.stage("simulator-report-native", "flutter", {"ready_marker_found": True, "launch_retries": []})
        self.stage("simulator-report-native", "flutter-example", {"ready_marker_found": True, "launch_retries": ["hung"]})
        self.stage("simulator-report-windows-11-arm", "flutter-example")
        found = entries(self.staged)
        self.assertEqual(
            [(entry["platform"], entry["app"], entry["ready"], entry["launch_retries"]) for entry in found],
            [
                ("native", "flutter", True, 0),
                ("native", "flutter-example", True, 1),
                ("windows-11-arm", "flutter-example", None, 0),
            ],
        )
        self.assertEqual(len({entry["slug"] for entry in found}), 3)

    def test_publishes_one_png_per_entry_under_its_slug(self):
        self.stage("simulator-report-ubuntu-24.04", "flutter-example")
        self.stage("simulator-report-compose", "compose")
        destination = self.root / "publish" / "123" / "1"
        found = entries(self.staged)
        publish(found, destination)
        self.assertEqual(sorted(path.name for path in destination.iterdir()),
                         sorted(f"{entry['slug']}.png" for entry in found))
        for entry in found:
            self.assertEqual((destination / f"{entry['slug']}.png").read_bytes(), entry["screenshot"].read_bytes())

    def test_report_embeds_each_screenshot_inline(self):
        self.stage("simulator-report-native", "flutter-example", {"ready_marker_found": True})
        self.stage("simulator-report-windows-2022", "flutter-example", {"ready_marker_found": True})
        found = entries(self.staged)
        report = render(found, "Flutter simulator report", "https://raw.example/sha/runs/1/1")
        self.assertIn("## Flutter simulator report", report)
        for entry in found:
            self.assertIn(f'<img src="https://raw.example/sha/runs/1/1/{entry["slug"]}.png" width="220">', report)
        self.assertEqual(report.count("<img "), 2)
        self.assertIn("| windows-2022 | flutter-example | found | 0 |", report)

    def test_report_without_published_images_says_so_instead_of_linking(self):
        self.stage("simulator-report-compose", "compose")
        report = render(entries(self.staged), "Compose simulator report", None)
        self.assertNotIn("<img", report)
        self.assertIn("could not be published", report)

    def test_empty_staging_renders_an_explicit_note(self):
        self.staged.mkdir()
        self.assertIn("No simulator screenshots were staged.", render([], "Report", "https://x"))


if __name__ == "__main__":
    unittest.main()
