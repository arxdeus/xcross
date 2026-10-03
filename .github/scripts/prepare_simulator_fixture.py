import argparse
from pathlib import Path
import plistlib
import shutil


FLUTTER_PUBSPEC = """name: simulator_native_acceptance
version: 1.0.0+1
publish_to: none
environment:
  sdk: ^3.13.0
dependencies:
  flutter:
    sdk: flutter
  shared_preferences: 2.5.5
  sqlite3: 3.5.2
flutter:
  uses-material-design: true
"""

FLUTTER_MAIN = """import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  await preferences.setInt('xcross.simulator.probe', 42);
  if (preferences.getInt('xcross.simulator.probe') != 42) {
    throw StateError('SwiftPM plugin probe failed');
  }
  final database = sqlite3.openInMemory();
  final value = database.select('SELECT 42 AS value').single['value'];
  if (value != 42) throw StateError('Native build-hook probe failed');
  database.dispose();
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('xcross native simulator ready')))));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    print('XCROSS_SIMULATOR_NATIVE_FIRST_FRAME_READY');
  });
}
"""


def prepare_flutter(destination):
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "lib").mkdir(exist_ok=True)
    runner = destination / "ios/Runner"
    runner.mkdir(parents=True, exist_ok=True)
    (destination / "pubspec.yaml").write_text(FLUTTER_PUBSPEC)
    (destination / "lib/main.dart").write_text(FLUTTER_MAIN)
    (runner / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "dev.xcross.simulator.nativeacceptance",
        "CFBundleName": "simulator_native_acceptance",
    }))
    flutter = destination / "ios/Flutter"
    flutter.mkdir(parents=True, exist_ok=True)
    (flutter / "AppFrameworkInfo.plist").write_bytes(plistlib.dumps({
        "CFBundleDevelopmentRegion": "en", "CFBundleExecutable": "App",
        "CFBundleIdentifier": "io.flutter.flutter.app", "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "App", "CFBundlePackageType": "FMWK", "CFBundleShortVersionString": "1.0",
        "CFBundleSignature": "????", "CFBundleVersion": "1.0", "MinimumOSVersion": "13.0",
    }))


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
    parser.add_argument("kind", choices=("flutter", "compose"))
    parser.add_argument("destination", type=Path)
    parser.add_argument("--source", type=Path)
    args = parser.parse_args()
    if args.kind == "flutter":
        prepare_flutter(args.destination)
    elif args.source is None:
        parser.error("Compose fixture requires --source")
    else:
        prepare_compose(args.source, args.destination)


if __name__ == "__main__":
    main()
