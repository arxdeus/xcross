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
import tempfile
import time
import urllib.parse
import urllib.request

from simulator_smoke import ABORT_MARKERS


ENGINE_FAILURES = re.compile(r"\[FATAL:|ImpellerValidationBreak|Could not create render pipeline")
VM_SERVICE = re.compile(r"The Dart VM service is listening on (http://127\.0\.0\.1:[0-9]+/[^/\s]*/?)")
BUILD_VERSION = re.compile(r"platform\s+(\S+)\s+minos\s+([0-9.]+)\s+sdk\s+(\S+)")
ROOT_LIBRARY = re.compile(r"package:[a-z0-9_]+/main\.dart")
SNAPSHOT_SYMBOLS = ("_kDartSnapshotData", "_kDartSnapshotText")
LOGS = ("app-stdout.log", "app-stderr.log")


def find_app(path):
    if path.suffix == ".app":
        return path
    apps = sorted(path.glob("*.app"))
    if len(apps) != 1:
        raise RuntimeError(f"Expected exactly one .app in {path}, found {len(apps)}")
    return apps[0]


def device_metadata(app):
    with (app / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    executable = info.get("CFBundleExecutable")
    if not executable or Path(executable).name != executable:
        raise RuntimeError("Invalid app executable name")
    if not (app / executable).is_file():
        raise RuntimeError("App executable is missing")
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
        raise RuntimeError("Expected an iPhoneOS device app")
    return executable


def binaries(app, executable):
    found = [app / executable]
    frameworks = app / "Frameworks"
    for framework in sorted(frameworks.glob("*.framework")):
        found.append(framework / framework.stem)
    found.extend(sorted(frameworks.glob("*.dylib")))
    return found


class AotRun:
    def __init__(self, app, output, mode, ready_marker, launch_timeout=90, observe_seconds=10):
        self.source = find_app(app.resolve())
        self.output = output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise RuntimeError("Run output directory must not contain evidence from a previous run")
        self.output.mkdir(parents=True, exist_ok=True)
        self.mode = mode
        self.ready_marker = ready_marker
        self.launch_timeout = launch_timeout
        self.observe_seconds = observe_seconds
        self.process = None
        self.exit_status = None
        self.ready_marker_found = False
        self.vm_service = None
        self.root_library = None
        self.failures = []

    def command(self, args, name, timeout=60):
        with (self.output / "commands.log").open("a") as log:
            log.write(json.dumps(args) + "\n")
        try:
            result = subprocess.run(
                args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, timeout=timeout, check=False,
            )
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(f"Timed out after {timeout}s: {args}") from error
        with (self.output / name).open("a") as log:
            log.write(result.stdout)
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {args}\n{result.stdout}")
        return result.stdout

    def build_version(self, binary):
        output = self.command(
            ["/usr/bin/xcrun", "vtool", "-arch", "arm64", "-show-build", str(binary)], "binary-validation.log",
        )
        match = BUILD_VERSION.search(output)
        if not match:
            raise RuntimeError(f"No arm64 LC_BUILD_VERSION in {binary}")
        return match.groups()

    def validate(self, app, executable):
        for binary in binaries(app, executable):
            platform, _, _ = self.build_version(binary)
            if platform not in ("IOS", "2"):
                raise RuntimeError(f"Not an arm64 iOS device Mach-O ({platform}): {binary}")
        snapshot = app / "Frameworks/App.framework/App"
        if not snapshot.is_file():
            raise RuntimeError("App.framework/App is missing")
        symbols = self.command(["/usr/bin/xcrun", "nm", "-gU", str(snapshot)], "binary-validation.log").split()
        missing = [symbol for symbol in SNAPSHOT_SYMBOLS if symbol not in symbols]
        if missing:
            raise RuntimeError(f"App.framework/App is not an AOT snapshot, missing {missing}")

    def retarget(self, app, executable):
        for binary in binaries(app, executable):
            _, minos, sdk = self.build_version(binary)
            retargeted = binary.with_name(binary.name + ".maccatalyst")
            self.command([
                "/usr/bin/xcrun", "vtool", "-arch", "arm64", "-set-build-version", "maccatalyst",
                minos, minos if sdk == "n/a" else sdk, "-replace", "-output", str(retargeted), str(binary),
            ], "retarget.log")
            os.replace(retargeted, binary)
            binary.chmod(0o755)
        for framework in sorted((app / "Frameworks").glob("*.framework")):
            self.command(["/usr/bin/codesign", "--force", "--sign", "-", str(framework)], "signature.log")
        for library in sorted((app / "Frameworks").glob("*.dylib")):
            self.command(["/usr/bin/codesign", "--force", "--sign", "-", str(library)], "signature.log")
        self.command(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], "signature.log")
        self.command(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-v", str(app)], "signature.log")

    def logs(self):
        return "".join(
            (self.output / name).read_text(errors="replace")
            for name in LOGS if (self.output / name).is_file()
        )

    def alive(self):
        if self.process.poll() is None:
            return True
        self.exit_status = self.process.returncode
        return False

    def wait_until_ready(self):
        deadline = time.monotonic() + self.launch_timeout
        while time.monotonic() < deadline:
            if self.ready_marker in self.logs():
                self.ready_marker_found = True
                return
            if not self.alive():
                raise RuntimeError(f"App exited before it was ready (status {self.exit_status})")
            time.sleep(0.25)
        raise RuntimeError(f"App-ready marker not observed within {self.launch_timeout}s: {self.ready_marker}")

    def rpc(self, method, **params):
        url = self.vm_service + method
        if params:
            url += "?" + urllib.parse.urlencode(params)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(url, timeout=10) as response:
            document = json.load(response)
        if "result" not in document:
            raise RuntimeError(f"VM service {method} failed: {document}")
        return document["result"]

    def check_vm_service(self):
        matches = VM_SERVICE.findall(self.logs())
        if self.mode == "release":
            if matches:
                raise RuntimeError(f"Release app serves a VM Service: {matches[0]}")
            return
        if len(set(matches)) != 1:
            raise RuntimeError(f"Expected one VM Service URI in a profile app, found {matches}")
        self.vm_service = matches[0].rstrip("/") + "/"
        vm = self.rpc("getVM")
        main = [isolate for isolate in vm.get("isolates", []) if isolate.get("name") == "main"]
        if len(main) != 1:
            raise RuntimeError(f"Expected one main isolate, found {vm.get('isolates')}")
        isolate = self.rpc("getIsolate", isolateId=main[0]["id"])
        self.root_library = (isolate.get("rootLib") or {}).get("uri")
        (self.output / "vm-service.json").write_text(json.dumps({
            "version": vm.get("version"), "operatingSystem": vm.get("operatingSystem"),
            "targetCPU": vm.get("targetCPU"), "runnable": isolate.get("runnable"),
            "rootLib": self.root_library,
        }, indent=2))
        if isolate.get("runnable") is not True:
            raise RuntimeError("Main isolate is not runnable")
        if not self.root_library or not ROOT_LIBRARY.fullmatch(self.root_library):
            raise RuntimeError(f"Unexpected root library: {self.root_library}")

    def observe(self):
        deadline = time.monotonic() + self.observe_seconds
        while time.monotonic() < deadline:
            if not self.alive():
                raise RuntimeError(f"App exited during observation (status {self.exit_status})")
            time.sleep(0.25)

    def stop(self):
        if self.process is None or not self.alive():
            return
        self.process.terminate()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=10)

    def scan(self):
        for line in self.logs().splitlines():
            if ABORT_MARKERS.search(line) or ENGINE_FAILURES.search(line):
                self.failures.append(line.strip()[:500])

    def run(self):
        error = None
        work = Path(tempfile.mkdtemp(prefix="aot-run-"))
        try:
            machine = self.command(["/usr/bin/uname", "-m"], "architecture.log").strip()
            if machine != "arm64":
                raise RuntimeError(f"Expected native macOS ARM64, got {machine}")
            executable = device_metadata(self.source)
            self.validate(self.source, executable)
            app = work / self.source.name
            shutil.copytree(self.source, app, symlinks=True)
            self.retarget(app, executable)
            with (self.output / LOGS[0]).open("w") as stdout, (self.output / LOGS[1]).open("w") as stderr:
                self.process = subprocess.Popen(
                    [str(app / executable)], cwd=work, stdin=subprocess.DEVNULL,
                    stdout=stdout, stderr=stderr, env=dict(os.environ, OS_ACTIVITY_DT_MODE="1"),
                    start_new_session=True,
                )
            self.wait_until_ready()
            self.check_vm_service()
            self.observe()
        except Exception as failure:
            error = failure
        finally:
            try:
                self.stop()
            except Exception as failure:
                error = error or failure
            try:
                self.scan()
            except Exception as failure:
                error = error or failure
            if not error and self.failures:
                error = RuntimeError(f"App logged a crash or engine failure: {self.failures[:5]}")
            shutil.rmtree(work, ignore_errors=True)
            (self.output / "result.json").write_text(json.dumps({
                "passed": error is None, "error": str(error) if error else None,
                "app": str(self.source), "mode": self.mode,
                "ready_marker": self.ready_marker, "ready_marker_found": self.ready_marker_found,
                "vm_service": self.vm_service, "root_library": self.root_library,
                "pid": self.process.pid if self.process else None,
                "exit_status": self.exit_status, "failures": self.failures,
                "observe_seconds": self.observe_seconds,
            }, indent=2))
        if error:
            raise error


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--mode", choices=("release", "profile"), required=True)
    parser.add_argument("--ready-marker", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--launch-timeout", type=int, default=90)
    parser.add_argument("--observe-seconds", type=int, default=10)
    args = parser.parse_args()
    if not args.ready_marker.strip() or args.launch_timeout < 1 or args.observe_seconds < 5:
        parser.error("A ready marker, a positive launch timeout and at least 5 seconds of observation are required")

    def terminate(signum, _frame):
        signal.signal(signum, signal.SIG_IGN)
        raise RuntimeError("Terminated")

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    run = AotRun(args.app, args.output, args.mode, args.ready_marker, args.launch_timeout, args.observe_seconds)
    try:
        run.run()
    except Exception:
        for line in run.logs().splitlines()[-40:]:
            print(line, file=sys.stderr)
        raise
    print(f"{run.source.name} ({args.mode}) ran as Mac Catalyst: {args.ready_marker}"
          + (f", VM Service root library {run.root_library}" if run.root_library else ", no VM Service"))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"AOT run failed: {error}", file=sys.stderr)
        sys.exit(1)
