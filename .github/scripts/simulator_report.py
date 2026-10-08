import argparse
import json
import os
import re
import shutil
from pathlib import Path


def entries(staged):
    found = []
    for screenshot in sorted(staged.glob("*/*/screenshot.png")):
        app = screenshot.parent.name
        artifact = screenshot.parent.parent.name
        platform = artifact.removeprefix("simulator-report-")
        result_path = screenshot.parent / "result.json"
        result = json.loads(result_path.read_text()) if result_path.is_file() else {}
        found.append({
            "platform": platform,
            "app": app,
            "screenshot": screenshot,
            "slug": re.sub(r"[^A-Za-z0-9._-]+", "-", f"{platform}-{app}"),
            "ready": result.get("ready_marker_found"),
            "launch_retries": len(result.get("launch_retries") or []),
        })
    return found


def publish(found, destination):
    destination.mkdir(parents=True, exist_ok=True)
    for entry in found:
        shutil.copyfile(entry["screenshot"], destination / f"{entry['slug']}.png")


def render(found, title, image_base):
    lines = [f"## {title}", ""]
    if not found:
        lines.append("No simulator screenshots were staged.")
        return "\n".join(lines) + "\n"
    lines += ["| Platform | App | Ready marker | Launch retries |", "| --- | --- | --- | --- |"]
    for entry in found:
        ready = {True: "found", False: "missing"}.get(entry["ready"], "n/a")
        lines.append(f"| {entry['platform']} | {entry['app']} | {ready} | {entry['launch_retries']} |")
    lines.append("")
    if image_base is None:
        lines.append("Screenshots could not be published; they stay in the staged artifacts.")
        return "\n".join(lines) + "\n"
    cells = [
        f'<td align="center"><b>{entry["platform"]}</b><br>{entry["app"]}<br>'
        f'<img src="{image_base}/{entry["slug"]}.png" width="220"></td>'
        for entry in found
    ]
    lines.append("<table>")
    for start in range(0, len(cells), 4):
        lines.append("<tr>" + "".join(cells[start:start + 4]) + "</tr>")
    lines.append("</table>")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description="Publish simulator screenshots and render a run report.")
    parser.add_argument("staged", type=Path)
    parser.add_argument("--title", required=True)
    parser.add_argument("--publish-dir", type=Path)
    parser.add_argument("--image-base")
    args = parser.parse_args()
    found = entries(args.staged)
    if args.publish_dir is not None:
        publish(found, args.publish_dir)
        return
    report = render(found, args.title, args.image_base)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as output:
            output.write(report)
    print(report, end="")


if __name__ == "__main__":
    main()
