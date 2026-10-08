import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("gate", ROOT / ".github/actions/integration-gate/gate.py")
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)

REPO = "owner/repo"


def comment(body="/check", association="OWNER", is_pr="true", number="7"):
    return {
        "EVENT_NAME": "issue_comment", "REPOSITORY": REPO, "COMMENT_BODY": body,
        "COMMENT_ASSOCIATION": association, "ISSUE_IS_PR": is_pr, "ISSUE_NUMBER": number,
    }


def pull(head_repo, sha="headsha"):
    return lambda repository, number: {"head": {"sha": sha, "repo": {"full_name": head_repo}}}


class GateTests(unittest.TestCase):
    def test_push_and_dispatch_run_the_event_commit_trusted(self):
        for event in ("push", "workflow_dispatch"):
            with self.subTest(event=event):
                decision = gate.resolve({"EVENT_NAME": event, "REPOSITORY": REPO, "EVENT_SHA": "abc"})
                self.assertEqual(decision, {"run": True, "sha": "abc", "trusted": True, "pr": ""})

    def test_pull_request_runs_head_and_trusts_only_same_repository(self):
        for head_repo, trusted in ((REPO, True), ("fork/repo", False)):
            with self.subTest(head_repo=head_repo):
                decision = gate.resolve({
                    "EVENT_NAME": "pull_request", "REPOSITORY": REPO,
                    "PR_HEAD_SHA": "prsha", "PR_HEAD_REPO": head_repo, "PR_NUMBER": "12",
                })
                self.assertEqual(decision, {"run": True, "sha": "prsha", "trusted": trusted, "pr": "12"})

    def test_maintainer_check_runs_the_pull_request_head(self):
        for association in ("OWNER", "MEMBER", "COLLABORATOR"):
            with self.subTest(association=association):
                decision = gate.resolve(comment(association=association), pull(REPO))
                self.assertEqual(decision, {"run": True, "sha": "headsha", "trusted": True, "pr": "7"})

    def test_check_on_fork_pull_request_runs_without_the_private_sdk(self):
        decision = gate.resolve(comment(), pull("fork/repo"))
        self.assertTrue(decision["run"])
        self.assertFalse(decision["trusted"])

    def test_non_maintainers_other_text_and_issues_do_not_run(self):
        fetched = []

        def fetch(repository, number):
            fetched.append(number)
            return {"head": {"sha": "x", "repo": {"full_name": REPO}}}

        for env in (
            comment(association="CONTRIBUTOR"),
            comment(association="NONE"),
            comment(association="FIRST_TIME_CONTRIBUTOR"),
            comment(body="please /check"),
            comment(body="/checks"),
            comment(body=""),
            comment(is_pr="false"),
        ):
            with self.subTest(env=env):
                self.assertFalse(gate.resolve(env, fetch)["run"])
        self.assertEqual(fetched, [])

    def test_check_command_may_carry_trailing_text_on_later_lines(self):
        self.assertTrue(gate.resolve(comment(body="/check\nretry after the flake"), pull(REPO))["run"])

    def test_unknown_events_do_not_run(self):
        self.assertFalse(gate.resolve({"EVENT_NAME": "schedule", "REPOSITORY": REPO})["run"])


if __name__ == "__main__":
    unittest.main()
