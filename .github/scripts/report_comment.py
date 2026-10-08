"""Post the integration report on a pull request and retire earlier ones.

Every earlier report comment is rewritten so its body sits inside a
collapsed spoiler under an "Outdated" summary, then minimized as OUTDATED,
so the pull request keeps exactly one expanded, current report.
"""
import argparse
import json
import subprocess
from pathlib import Path

from simulator_report import MARKER

OUTDATED_MARKER = "<!-- xcross-integration-report:outdated -->"
BOT = "github-actions[bot]"


def gh(*args, payload=None):
    result = subprocess.run(
        ["gh", "api", *args, *(["--input", "-"] if payload is not None else [])],
        input=json.dumps(payload) if payload is not None else None,
        check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout) if result.stdout.strip() else None


def previous_reports(comments):
    return [
        comment for comment in comments
        if (comment.get("user") or {}).get("login") == BOT
        and (comment.get("body") or "").lstrip().startswith(MARKER)
    ]


def outdated_body(body, superseded_by):
    inner = body.lstrip().removeprefix(MARKER).strip()
    return (
        f"{OUTDATED_MARKER}\n"
        f"<details>\n<summary>⚠️ Outdated integration report, superseded by {superseded_by}</summary>\n\n"
        f"{inner}\n\n</details>\n"
    )


def retire(api, repository, comment, superseded_by):
    api(f"repos/{repository}/issues/comments/{comment['id']}", "-X", "PATCH",
        payload={"body": outdated_body(comment["body"], superseded_by)})
    try:
        api("graphql", payload={
            "query": "mutation($id: ID!) { minimizeComment(input: {subjectId: $id, classifier: OUTDATED}) "
                     "{ minimizedComment { isMinimized } } }",
            "variables": {"id": comment["node_id"]},
        })
    except subprocess.CalledProcessError as failure:
        print(f"::warning::Could not minimize report comment {comment['id']}: {failure.stderr}")


def post(api, repository, pr, body):
    comments = api(f"repos/{repository}/issues/{pr}/comments", "--paginate", "--slurp")
    if comments and isinstance(comments[0], list):
        comments = [comment for page in comments for comment in page]
    stale = previous_reports(comments or [])
    created = api(f"repos/{repository}/issues/{pr}/comments", "-X", "POST", payload={"body": body})
    link = f"[the latest report]({created['html_url']})" if created and created.get("html_url") else "a newer report"
    for comment in stale:
        retire(api, repository, comment, link)
    return created, stale


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--pr", required=True)
    parser.add_argument("--body-file", type=Path, required=True)
    args = parser.parse_args()
    post(gh, args.repository, args.pr, args.body_file.read_text())


if __name__ == "__main__":
    main()
