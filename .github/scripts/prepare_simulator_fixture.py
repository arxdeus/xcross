import argparse
from pathlib import Path
import shutil


def prepare_compose(source, destination):
    if destination.resolve().is_relative_to(source.resolve()):
        raise RuntimeError("Compose fixture destination must be outside the read-only source")
    shutil.copytree(source, destination, ignore=shutil.ignore_patterns(
        ".git", ".gradle", ".kotlin", "build", ".dart_tool",
    ))
    gradle = destination / "shared/build.gradle.kts"
    text = gradle.read_text()
    target = "    iosArm64 {"
    if text.count(target) != 1:
        raise RuntimeError("Expected exactly one example iosArm64 target")
    gradle.write_text(text.replace(target, "    iosSimulatorArm64 {"))
    controllers = list((destination / "shared/src/iosMain").rglob("MainViewController.kt"))
    if len(controllers) != 1:
        raise RuntimeError("Expected exactly one Compose main view controller")
    controller = controllers[0]
    text = controller.read_text()
    expression = "ComposeUIViewController { App() }"
    if text.count(expression) != 1:
        raise RuntimeError("Unexpected Compose main view controller")
    text = text.replace(
        "import androidx.compose.ui.window.ComposeUIViewController",
        "import androidx.compose.runtime.SideEffect\nimport androidx.compose.ui.window.ComposeUIViewController",
    ).replace(expression, """ComposeUIViewController {
    App()
    SideEffect { println("XCROSS_COMPOSE_READY") }
}""")
    controller.write_text(text)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=("compose",))
    parser.add_argument("destination", type=Path)
    parser.add_argument("--source", type=Path, required=True)
    args = parser.parse_args()
    prepare_compose(args.source, args.destination)

if __name__ == "__main__":
    main()
