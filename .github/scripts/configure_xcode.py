import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from simulator_smoke import select_device, version_tuple


def configure(output, applications=Path("/Applications")):
    output.mkdir(parents=True, exist_ok=True)
    candidates = sorted({path.resolve() for path in applications.glob("Xcode*.app")})
    selections = []
    errors = []
    for index, app in enumerate(candidates):
        developer = app / "Contents/Developer"
        env = dict(os.environ, DEVELOPER_DIR=str(developer))

        def command(args):
            try:
                result = subprocess.run(
                    args, env=env, text=True, stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, timeout=60, check=False,
                )
            except subprocess.TimeoutExpired as error:
                raise RuntimeError(f"Timed out: {args}") from error
            with (output / f"candidate-{index}.log").open("a") as log:
                log.write(json.dumps(args) + "\n" + result.stdout + result.stderr)
            if result.returncode:
                raise RuntimeError(f"Command failed: {args}: {result.stderr}")
            return result.stdout.strip()

        try:
            version = command(["/usr/bin/xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"])
            device_version = command(["/usr/bin/xcrun", "--sdk", "iphoneos", "--show-sdk-version"])
            if version_tuple(version) != version_tuple(device_version):
                raise RuntimeError("Device and simulator SDK versions must match")
            sdk = Path(command(["/usr/bin/xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]))
            if not sdk.is_dir() or not sdk.resolve().is_relative_to(developer.resolve()):
                raise RuntimeError("Simulator SDK must belong to the selected native Xcode")
            inventory = json.loads(command(["/usr/bin/xcrun", "simctl", "list", "--json"]))
            (output / f"candidate-{index}-inventory.json").write_text(json.dumps(inventory, indent=2))
            runtime, device_type = select_device(inventory, sdk_version=version)
            command(["/usr/bin/xcrun", "swift", "--version"])
            selections.append({
                "app": str(app), "developer": str(developer), "sdk": str(sdk),
                "sdk_version": version, "runtime": runtime, "device_type": device_type,
            })
        except Exception as error:
            errors.append({"app": str(app), "error": str(error)})
    (output / "selection-errors.json").write_text(json.dumps(errors, indent=2))
    if not selections:
        raise RuntimeError(f"No native Xcode with matching SDKs and available compatible iOS runtime: {errors}")
    selected = max(selections, key=lambda item: (version_tuple(item["sdk_version"]), item["app"]))
    (output / "selected-xcode.json").write_text(json.dumps(selected, indent=2))
    return selected


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    selected = configure(args.output)
    with Path(os.environ["GITHUB_ENV"]).open("a") as env:
        env.write(f"XCODE_APP={selected['app']}\nDEVELOPER_DIR={selected['developer']}\n")
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write(f"app={selected['app']}\nruntime={selected['runtime']}\n")
    print(json.dumps(selected, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Xcode setup failed: {error}", file=sys.stderr)
        sys.exit(1)
