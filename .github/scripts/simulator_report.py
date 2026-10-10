import argparse
import json
import os
import re
from pathlib import Path

MARKER = "<!-- xcross-integration-report -->"
SECTIONS = (("flutter", "Flutter"), ("compose", "Compose"))
HOSTS = {"native": "macos-15 (native)"}
STATUS = {True: "✅ Ready", False: "❌ Not ready", None: "⚪ Unknown"}


def entries(staged):
    found = []
    for screenshot in sorted(staged.glob("*/*/screenshot.png")):
        app = screenshot.parent.name
        artifact = screenshot.parent.parent.name.removeprefix("simulator-report-")
        kind, _, host = artifact.partition("-")
        if kind not in dict(SECTIONS) or not host:
            kind, host = ("compose" if app.startswith("compose") else "flutter"), artifact
        result_path = screenshot.parent / "result.json"
        result = json.loads(result_path.read_text()) if result_path.is_file() else {}
        found.append({
            "kind": kind,
            "platform": HOSTS.get(host, host),
            "app": app,
            "screenshot": screenshot,
            "slug": re.sub(r"[^A-Za-z0-9._-]+", "-", f"{kind}-{host}-{app}"),
            "ready": result.get("ready_marker_found"),
            "launch_retries": len(result.get("launch_retries") or []),
        })
    return found


def artifact_name(entry):
    return f"simulator-{entry['slug']}.png"


def artifact_links(artifacts, repository_url, run_id):
    """Map unzipped screenshot artifact names to their browser URLs."""
    return {
        artifact["name"]: f"{repository_url}/actions/runs/{run_id}/artifacts/{artifact['id']}"
        for artifact in artifacts
        if artifact.get("name", "").startswith("simulator-")
        and artifact["name"].endswith(".png")
        and not artifact.get("expired")
    }


def commit_link(label, repository_url, sha):
    if not sha:
        return f"{label}: unknown"
    if not repository_url:
        return f"{label}: `{sha}`"
    return f"{label}: [`{sha[:12]}`]({repository_url.removesuffix('.git')}/commit/{sha})"


def section(title, found, links):
    lines = [f"### {title}", ""]
    if not found:
        return lines + [f"No {title} simulator screenshots were staged.", ""]
    lines += ["| Host | App | Status | Launch retries | Screenshot |", "| :--- | :--- | :--- | :---: | :--- |"]
    for entry in found:
        status = STATUS.get(entry["ready"], STATUS[None])
        link = links.get(artifact_name(entry))
        shot = f"🖼️ [Open image]({link})" if link else "_unavailable_"
        lines.append(
            f"| **{entry['platform']}** | `{entry['app']}` | {status} | {entry['launch_retries']} | {shot} |"
        )
    return lines + [""]


def render(found, title, links=None, commits=()):
    links = links or {}
    lines = [MARKER, f"## {title}", ""]
    if commits:
        lines += [" · ".join(commit_link(*commit) for commit in commits), ""]
    for kind, heading in SECTIONS:
        lines += section(heading, [entry for entry in found if entry["kind"] == kind], links)
    if found:
        lines += ["<sub>Screenshots are Actions artifacts of this run. They open in the browser and expire after 30 days.</sub>", ""]
    return "\n".join(lines).rstrip("\n") + "\n"


def main():
    parser = argparse.ArgumentParser(description="Render a run report that links each simulator screenshot artifact.")
    parser.add_argument("staged", type=Path)
    parser.add_argument("--title", required=True)
    parser.add_argument("--artifacts", type=Path, help="JSON list of this run's artifacts from the Actions API.")
    parser.add_argument("--run-id", default="")
    parser.add_argument("--commit", default="")
    parser.add_argument("--repository-url", default="")
    parser.add_argument("--examples-commit", default="")
    parser.add_argument("--examples-url", default="")
    args = parser.parse_args()
    found = entries(args.staged) if args.staged.is_dir() else []
    links = {}
    if args.artifacts is not None and args.artifacts.is_file():
        links = artifact_links(json.loads(args.artifacts.read_text()), args.repository_url, args.run_id)
    commits = (
        ("xcross", args.repository_url, args.commit),
        ("xcross_examples", args.examples_url, args.examples_commit),
    )
    report = render(found, args.title, links, commits)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as output:
            output.write(report)
    print(report, end="")


if __name__ == "__main__":
    main()
