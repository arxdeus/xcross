import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid


def version_tuple(version):
    parts = tuple(int(part) for part in version.split("."))
    return parts + (0,) * max(0, 3 - len(parts))


def select_device(inventory, sdk_version=None, minimum_version=None):
    types = {item["identifier"]: item for item in inventory["devicetypes"]}
    by_name = {item["name"]: item["identifier"] for item in types.values()}
    runtimes = sorted(
        (
            item for item in inventory["runtimes"]
            if item.get("isAvailable") is True
            and item["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
            and (sdk_version is None or (
                version_tuple(item["version"])[0] == version_tuple(sdk_version)[0]
                and version_tuple(item["version"]) <= version_tuple(sdk_version)
            ))
            and (minimum_version is None
                 or version_tuple(item["version"]) >= version_tuple(minimum_version))
        ),
        key=lambda item: (tuple(int(n) for n in item["version"].split(".")), item["identifier"]),
        reverse=True,
    )
    for runtime in runtimes:
        compatible = {
            item["identifier"] for item in runtime.get("supportedDeviceTypes", [])
        }
        compatible.update(
            item.get("deviceTypeIdentifier") or by_name.get(item["name"])
            for item in inventory.get("devices", {}).get(runtime["identifier"], [])
            if item.get("isAvailable") is True
        )
        iphones = sorted(
            identifier for identifier in compatible
            if identifier in types and types[identifier]["name"].startswith("iPhone ")
        )
        if iphones:
            return runtime["identifier"], iphones[0]
    raise RuntimeError("No available iOS runtime with a compatible iPhone device type")


def app_metadata(app):
    with (app / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    identifier = info["CFBundleIdentifier"]
    executable = info["CFBundleExecutable"]
    if not re.fullmatch(r"[A-Za-z0-9.-]+", identifier):
        raise RuntimeError("Invalid app bundle identifier")
    if not executable or Path(executable).name != executable:
        raise RuntimeError("Invalid app executable name")
    if not (app / executable).is_file():
        raise RuntimeError("App executable is missing")
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"]:
        raise RuntimeError("Expected an iPhoneSimulator app, not a device app")
    return identifier, executable


class Smoke:
    def __init__(self, app, output, boot_timeout=180, observe_seconds=20, ready_marker=None):
        self.app = app.resolve()
        self.output = output.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        if any((self.output / name).exists() for name in (
                "result.json", "app-stdout.log", "app-stderr.log", "simulator.log")):
            raise RuntimeError("Smoke output directory must not contain evidence from a previous run")
        self.boot_timeout = boot_timeout
        self.observe_seconds = observe_seconds
        self.device = None
        self.pid = None
        self.executable = None
        self.identifier = None
        self.started = time.time()
        self.crashes = []
        self.created_name = None
        self.runtime = None
        self.device_type = None
        self.ready_marker = ready_marker
        self.ready_marker_found = False

    def command(self, args, name, timeout=60, check=True):
        with (self.output / "commands.log").open("a") as log:
            log.write(json.dumps(args) + "\n")
        try:
            result = subprocess.run(
                args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, timeout=timeout, check=False,
            )
        except subprocess.TimeoutExpired as error:
            data = error.stdout or b""
            if isinstance(data, bytes):
                data = data.decode(errors="replace")
            (self.output / name).write_text(data + f"\nTimed out after {timeout}s\n")
            raise RuntimeError(f"Command timed out after {timeout}s: {args}") from error
        with (self.output / name).open("a") as log:
            log.write(result.stdout)
        if check and result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {args}\n{result.stdout}")
        return result

    def simctl(self, *args, name, timeout=60, check=True):
        return self.command(
            ["/usr/bin/xcrun", "simctl", *args], name, timeout, check,
        )

    def validate_binary(self, binary):
        self.command(
            ["/usr/bin/xcrun", "lipo", "-verify_arch", "arm64", str(binary)],
            "binary-validation.log",
        )
        result = self.command(
            ["/usr/bin/xcrun", "vtool", "-arch", "arm64", "-show-build", str(binary)],
            "binary-validation.log",
        )
        if not re.search(r"platform\s+(?:IOSSIMULATOR|7)\b", result.stdout):
            raise RuntimeError(f"Not an ARM64 iOS Simulator Mach-O: {binary}")

    def observe(self):
        deadline = time.monotonic() + self.observe_seconds
        expected = f"/{self.app.name}/{self.executable}"
        while True:
            result = self.command(
                ["/bin/ps", "-p", str(self.pid), "-o", "stat=,command="],
                "process-observation.log", check=False,
            )
            fields = result.stdout.strip().split(maxsplit=1)
            if (result.returncode or len(fields) != 2
                    or fields[0].startswith("Z") or expected not in fields[1]):
                raise RuntimeError(f"Launched app exited or crashed during observation (PID {self.pid})")
            if time.monotonic() >= deadline:
                return
            time.sleep(min(1, max(0, deadline - time.monotonic())))

    def capture_crashes(self):
        if not self.executable or not self.device:
            return
        roots = [
            Path.home() / "Library/Logs/DiagnosticReports",
            Path.home() / "Library/Developer/CoreSimulator/Devices" / self.device
            / "data/Library/Logs/CrashReporter",
        ]
        target = self.output / "crashes"
        for index, root in enumerate(roots):
            if not root.is_dir():
                continue
            for path in root.rglob("*"):
                if (path.is_file() and path.name.startswith(self.executable + "-")
                        and path.suffix in (".ips", ".crash")
                        and path.stat().st_mtime >= self.started
                        and (index == 1 or self.attributed_crash(path))):
                    target.mkdir(exist_ok=True)
                    shutil.copy2(path, target / f"{index}-{path.name}")
                    self.crashes.append(str(path))

    def attributed_crash(self, path):
        if not self.pid:
            return False
        text = path.read_text(errors="replace")
        if path.suffix == ".crash":
            pid = re.search(r"^Process:\s+.*\[([0-9]+)\]\s*$", text, re.MULTILINE)
            bundle = re.search(r"^Identifier:\s+(\S+)\s*$", text, re.MULTILINE)
            process_path = re.search(r"^Path:\s+(.+)$", text, re.MULTILINE)
            return bool(pid and int(pid.group(1)) == self.pid and (
                (bundle and bundle.group(1) == self.identifier)
                or (process_path and self.device.lower() in process_path.group(1).lower())
            ))
        documents = []
        decoder = json.JSONDecoder()
        while text.strip():
            try:
                document, end = decoder.raw_decode(text.lstrip())
            except ValueError:
                return False
            documents.append(document)
            text = text.lstrip()[end:]
        for document in documents:
            if not isinstance(document, dict) or document.get("pid") != self.pid:
                continue
            bundle_info = document.get("bundleInfo") or {}
            bundle = bundle_info.get("CFBundleIdentifier") if isinstance(bundle_info, dict) else None
            bundles = {item.get("bundleID") for item in documents if isinstance(item, dict)}
            if (bundle == self.identifier or self.identifier in bundles
                    or self.device.lower() in str(document.get("procPath", "")).lower()):
                return True
        return False

    def diagnostics(self):
        failures = []
        if self.device:
            commands = [
                (["io", self.device, "screenshot", str(self.output / "screenshot.png")], "screenshot.log"),
                (["list", "devices", "--json"], "devices-final.json"),
            ]
            predicate = f"process == {json.dumps(self.executable)}"
            if self.pid:
                predicate += f" OR processID == {self.pid}"
            commands.append(([
                "spawn", self.device, "log", "show", "--style", "compact",
                "--last", "5m", "--predicate", predicate,
            ], "simulator.log"))
            for args, name in commands:
                try:
                    result = self.simctl(*args, name=name, check=False, timeout=30)
                    if result.returncode:
                        failures.append(name)
                except Exception as error:
                    failures.append(f"{name}: {error}")
        try:
            self.capture_crashes()
        except Exception as error:
            failures.append(f"crash collection: {error}")
        return failures

    def recover_created_device(self):
        if self.device or not self.created_name:
            return
        result = self.simctl("list", "devices", "--json", name="create-recovery.json", timeout=30)
        devices = json.loads(result.stdout).get("devices", {}).get(self.runtime, [])
        matches = [item for item in devices if item.get("name") == self.created_name]
        if len(matches) > 1:
            raise RuntimeError("Multiple simulators matched the unique job-created name")
        if matches:
            self.device = str(uuid.UUID(matches[0]["udid"]))

    def cleanup(self):
        if not self.device:
            return
        try:
            self.simctl("shutdown", self.device, name="cleanup.log", check=False, timeout=30)
        finally:
            self.simctl("delete", self.device, name="cleanup.log", timeout=30)

    def run(self):
        error = None
        try:
            machine = self.command(["/usr/bin/uname", "-m"], "architecture.log").stdout.strip()
            if machine != "arm64":
                raise RuntimeError(f"Expected native macOS ARM64, got {machine}")
            identifier, self.executable = app_metadata(self.app)
            self.identifier = identifier
            self.validate_binary(self.app / self.executable)
            for framework in sorted((self.app / "Frameworks").glob("*.framework")):
                self.validate_binary(framework / framework.stem)
            result = self.simctl("list", "--json", name="inventory.json")
            sdk_version = self.command(
                ["/usr/bin/xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"],
                "sdk-version.log",
            ).stdout.strip()
            with (self.app / "Info.plist").open("rb") as source:
                minimum_version = plistlib.load(source).get("MinimumOSVersion")
            runtime, device_type = select_device(json.loads(result.stdout), sdk_version, minimum_version)
            self.runtime, self.device_type = runtime, device_type
            self.created_name = f"xcross-smoke-{os.environ.get('GITHUB_RUN_ID', 'local')}-{uuid.uuid4().hex}"
            result = self.simctl("create", self.created_name, device_type, runtime, name="create.log")
            self.device = str(uuid.UUID(result.stdout.strip()))
            (self.output / "device.json").write_text(json.dumps({
                "udid": self.device, "runtime": runtime, "device_type": device_type,
                "name": self.created_name, "app": str(self.app), "bundle_id": identifier,
            }, indent=2))
            self.simctl("boot", self.device, name="boot.log")
            self.simctl("bootstatus", self.device, "-b", name="bootstatus.log", timeout=self.boot_timeout)
            self.simctl("install", self.device, str(self.app), name="install.log", timeout=120)
            result = self.simctl(
                "launch", "--terminate-running-process",
                f"--stdout={self.output / 'app-stdout.log'}",
                f"--stderr={self.output / 'app-stderr.log'}",
                self.device, identifier, name="launch.log",
            )
            match = re.search(rf"^{re.escape(identifier)}: ([1-9][0-9]*)$", result.stdout, re.MULTILINE)
            if not match:
                raise RuntimeError("simctl launch did not return an app PID")
            self.pid = int(match.group(1))
            self.observe()
        except Exception as failure:
            error = failure
        finally:
            try:
                self.recover_created_device()
            except Exception as failure:
                error = error or failure
            diagnostics = []
            try:
                diagnostics = self.diagnostics()
                if self.ready_marker:
                    self.ready_marker_found = any(
                        path.is_file() and self.ready_marker in path.read_text(errors="replace")
                        for path in (self.output / name for name in (
                            "app-stdout.log", "app-stderr.log", "simulator.log",
                        ))
                    )
                    if not self.ready_marker_found:
                        error = error or RuntimeError(f"App-ready marker not observed: {self.ready_marker}")
            except Exception as failure:
                error = error or failure
            try:
                self.cleanup()
            except Exception as failure:
                error = error or failure
            if not error and (diagnostics or self.crashes):
                error = RuntimeError(f"Smoke diagnostics failed or found crashes: {diagnostics + self.crashes}")
            (self.output / "result.json").write_text(json.dumps({
                "passed": error is None, "error": str(error) if error else None,
                "pid": self.pid, "device": self.device,
                "observe_seconds": self.observe_seconds,
                "ready_marker": self.ready_marker, "ready_marker_found": self.ready_marker_found,
                "diagnostic_failures": diagnostics, "crashes": self.crashes,
            }, indent=2))
        if error:
            raise error


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--boot-timeout", type=int, default=180)
    parser.add_argument("--observe-seconds", type=int, default=20)
    parser.add_argument("--ready-marker")
    args = parser.parse_args()
    if args.boot_timeout < 1 or args.observe_seconds < 20:
        parser.error("Boot timeout must be positive and observation must last at least 20 seconds")

    def terminate(signum, _frame):
        signal.signal(signum, signal.SIG_IGN)
        raise RuntimeError("Terminated")

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    Smoke(args.app, args.output, args.boot_timeout, args.observe_seconds, args.ready_marker).run()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Simulator smoke failed: {error}", file=sys.stderr)
        sys.exit(1)
