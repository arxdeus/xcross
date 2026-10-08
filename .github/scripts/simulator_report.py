import argparse
import json
import os
import re
import shutil
from pathlib import Path

MARKER = "<!-- xcross-integration-report -->"
SECTIONS = (("flutter", "Flutter"), ("compose", "Compose"))
HOSTS = {"native": "macos-15 (native)"}


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


def publish(found, destination):
    destination.mkdir(parents=True, exist_ok=True)
    for entry in found:
        shutil.copyfile(entry["screenshot"], destination / f"{entry['slug']}.png")


def commit_link(label, repository_url, sha):
    if not sha:
        return f"{label}: unknown"
    if not repository_url:
        return f"{label}: `{sha}`"
    return f"{label}: [`{sha[:12]}`]({repository_url.removesuffix('.git')}/commit/{sha})"


def section(title, found, image_base):
    lines = [f"### {title}", ""]
    if not found:
        return lines + [f"No {title} simulator screenshots were staged.", ""]
    lines += ["| Host | App | Ready marker | Launch retries |", "| --- | --- | :---: | :---: |"]
    for entry in found:
        ready = {True: "✅", False: "❌"}.get(entry["ready"], "n/a")
        lines.append(f"| {entry['platform']} | {entry['app']} | {ready} | {entry['launch_retries']} |")
    lines.append("")
    if image_base is None:
        return lines + ["Screenshots could not be published; they stay in the staged artifacts.", ""]
    cells = [
        f'<td align="center"><b>{entry["platform"]}</b><br>{entry["app"]}<br>'
        f'<img src="{image_base}/{entry["slug"]}.png" width="220"></td>'
        for entry in found
    ]
    lines.append("<table>")
    for start in range(0, len(cells), 4):
        lines.append("<tr>" + "".join(cells[start:start + 4]) + "</tr>")
    lines += ["</table>", ""]
    return lines


def render(found, title, image_base, commits=()):
    lines = [MARKER, f"## {title}", ""]
    if commits:
        lines += [" · ".join(commit_link(*commit) for commit in commits), ""]
    for kind, heading in SECTIONS:
        lines += section(heading, [entry for entry in found if entry["kind"] == kind], image_base)
    return "\n".join(lines).rstrip("\n") + "\n"


def main():
    parser = argparse.ArgumentParser(description="Publish simulator screenshots and render a run report.")
    parser.add_argument("staged", type=Path)
    parser.add_argument("--title", required=True)
    parser.add_argument("--publish-dir", type=Path)
    parser.add_argument("--image-base")
    parser.add_argument("--commit", default="")
    parser.add_argument("--repository-url", default="")
    parser.add_argument("--examples-commit", default="")
    parser.add_argument("--examples-url", default="")
    args = parser.parse_args()
    found = entries(args.staged) if args.staged.is_dir() else []
    if args.publish_dir is not None:
        publish(found, args.publish_dir)
        return
    commits = (
        ("xcross", args.repository_url, args.commit),
        ("xcross_examples", args.examples_url, args.examples_commit),
    )
    report = render(found, args.title, args.image_base, commits)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as output:
            output.write(report)
    print(report, end="")


if __name__ == "__main__":
    main()
