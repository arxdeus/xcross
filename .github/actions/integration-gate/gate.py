import json
import os
import subprocess

MAINTAINERS = {"OWNER", "MEMBER", "COLLABORATOR"}


def pull_request(repository, number):
    result = subprocess.run(
        ["gh", "api", f"repos/{repository}/pulls/{number}"],
        check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout)


def resolve(env, fetch_pull_request=pull_request):
    event = env["EVENT_NAME"]
    repository = env["REPOSITORY"]
    if event in ("push", "workflow_dispatch"):
        return {"run": True, "sha": env["EVENT_SHA"], "trusted": True, "pr": ""}
    if event == "pull_request":
        return {
            "run": True,
            "sha": env["PR_HEAD_SHA"],
            "trusted": env.get("PR_HEAD_REPO") == repository,
            "pr": env.get("PR_NUMBER", ""),
        }
    if event == "issue_comment":
        command = env.get("COMMENT_BODY", "").strip().splitlines()
        is_check = bool(command) and command[0].strip() == "/check"
        is_pr = env.get("ISSUE_IS_PR") == "true"
        is_maintainer = env.get("COMMENT_ASSOCIATION") in MAINTAINERS
        if not (is_check and is_pr and is_maintainer):
            return {"run": False, "sha": "", "trusted": False, "pr": ""}
        number = env["ISSUE_NUMBER"]
        pull = fetch_pull_request(repository, number)
        head_repo = (pull.get("head") or {}).get("repo") or {}
        return {
            "run": True,
            "sha": pull["head"]["sha"],
            "trusted": head_repo.get("full_name") == repository,
            "pr": str(number),
        }
    return {"run": False, "sha": "", "trusted": False, "pr": ""}


def main():
    decision = resolve(os.environ)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"run={str(decision['run']).lower()}\n")
        output.write(f"sha={decision['sha']}\n")
        output.write(f"trusted={str(decision['trusted']).lower()}\n")
        output.write(f"pr={decision['pr']}\n")
    if decision["run"] and not decision["trusted"]:
        print("::notice::Fork pull request: building the xcross CLI and toolchain only. "
              "The private Apple SDK and the iOS build steps run once a maintainer "
              "pushes the branch to this repository.")


if __name__ == "__main__":
    main()
