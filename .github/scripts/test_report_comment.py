import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from report_comment import BOT, OUTDATED_MARKER, outdated_body, post
from simulator_report import MARKER

ROOT = Path(__file__).resolve().parents[2]
REPO = "owner/repo"


class FakeApi:
    def __init__(self, comments):
        self.comments = comments
        self.calls = []

    def __call__(self, *args, payload=None):
        self.calls.append((args, payload))
        if args[0].endswith("/comments") and "POST" in args:
            return {"id": 99, "html_url": "https://github.com/owner/repo/pull/7#issuecomment-99"}
        if args[0].endswith("/comments"):
            return [self.comments]
        return {}


def comment(identifier, body, login=BOT):
    return {"id": identifier, "node_id": f"IC_{identifier}", "body": body, "user": {"login": login}}


class ReportCommentTests(unittest.TestCase):
    def test_new_report_is_posted_and_every_earlier_report_is_collapsed_and_minimized(self):
        api = FakeApi([
            comment(1, f"{MARKER}\n## Old report\n| a |"),
            comment(2, "unrelated bot comment"),
            comment(3, f"{MARKER}\n## Spoofed", login="someone"),
            comment(4, f"{OUTDATED_MARKER}\n<details>already retired</details>"),
            comment(5, f"{MARKER}\n## Older report"),
        ])
        created, stale = post(api, REPO, "7", f"{MARKER}\n## New")
        self.assertEqual(created["id"], 99)
        self.assertEqual([entry["id"] for entry in stale], [1, 5])
        posts = [payload for args, payload in api.calls if "POST" in args]
        self.assertEqual(posts, [{"body": f"{MARKER}\n## New"}])
        patches = {args[0]: payload["body"] for args, payload in api.calls if "PATCH" in args}
        self.assertEqual(set(patches), {f"repos/{REPO}/issues/comments/1", f"repos/{REPO}/issues/comments/5"})
        for body in patches.values():
            self.assertTrue(body.startswith(OUTDATED_MARKER))
            self.assertNotIn(MARKER + "\n", body)
            self.assertIn("<details>\n<summary>⚠️ Outdated integration report", body)
            self.assertIn("issuecomment-99", body)
            self.assertTrue(body.rstrip().endswith("</details>"))
        minimized = [payload["variables"]["id"] for args, payload in api.calls if args[0] == "graphql"]
        self.assertEqual(minimized, ["IC_1", "IC_5"])
        for args, payload in api.calls:
            if args[0] == "graphql":
                self.assertIn("classifier: OUTDATED", payload["query"])

    def test_outdated_body_keeps_the_old_report_inside_the_spoiler(self):
        body = outdated_body(f"{MARKER}\n## Report\n<img src=x>", "a newer report")
        self.assertIn("## Report\n<img src=x>\n\n</details>", body)

    def test_check_comment_is_deleted_only_after_the_gate_accepts_it(self):
        action = (ROOT / ".github/actions/integration-gate/action.yml").read_text()
        step = action.split("- name: Delete the /check comment\n", 1)[1]
        self.assertIn("if: github.event_name == 'issue_comment' && steps.gate.outputs.run == 'true'", step)
        self.assertIn('gh api -X DELETE "repos/${GITHUB_REPOSITORY}/issues/comments/${COMMENT_ID}"', step)
        workflow = (ROOT / ".github/workflows/integration.yml").read_text()
        gate = workflow.split("\n  gate:\n", 1)[1].split("\n  flutter-build:\n", 1)[0]
        self.assertIn("pull-requests: write", gate)


if __name__ == "__main__":
    unittest.main()
