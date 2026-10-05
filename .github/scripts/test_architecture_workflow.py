import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


def workflow_jobs(text):
    jobs = {}
    current = None
    collecting = False
    for line in text.splitlines():
        if line == 'jobs:':
            collecting = True
            continue
        if not collecting:
            continue
        if line and not line.startswith(' '):
            break
        if line.startswith('  ') and not line.startswith('    ') and line.endswith(':'):
            current = line.strip()[:-1]
            jobs[current] = []
        elif current is not None:
            jobs[current].append(line)
    return jobs


def workflow_steps(lines):
    steps = []
    current = None
    for line in lines:
        if line.startswith('      - '):
            current = {'script': []}
            steps.append(current)
            value = line[8:]
        elif line.startswith('        ') and not line.startswith('          '):
            value = line[8:]
        elif current is not None and line.startswith('          '):
            command = line.strip()
            if current.get('run') in ('|', '>-') and not command.startswith('#'):
                current['script'].append(command)
            continue
        else:
            continue
        if current is not None and ':' in value:
            key, value = value.split(':', 1)
            current[key] = value.strip()
            if key == 'run' and value.strip() not in ('|', '>-'):
                current['script'] = [value.strip()]
    return {step.get('name'): step for step in steps}


class ArchitectureWorkflowTests(unittest.TestCase):
    def required_step(self, steps, name):
        self.assertIn(name, steps)
        step = steps[name]
        self.assertNotIn('if', step)
        self.assertIn(step.get('continue-on-error', 'false'), ('false', False))
        return step['script']

    def check_simulator_job(self, workflow, feature, marker):
        jobs = workflow_jobs(workflow)
        self.assertIn(f'{feature}-simulator', jobs)
        lines = jobs[f'{feature}-simulator']
        self.assertFalse(any(line.startswith('    if:') for line in lines))
        self.assertFalse(any(line.startswith('    continue-on-error:') for line in lines))
        steps = workflow_steps(lines)
        bundle = self.required_step(steps, 'Build native production xcross CLI')
        self.assertIn('(cd packages/xcross && dart run tool/build_xcross.dart)', bundle)
        self.assertIn('bundles=(packages/xcross/build/cli/*/bundle)', bundle)
        self.assertIn('cp -R "${bundles[0]}" "$RUNNER_TEMP/xcross-bundle"', bundle)
        self.assertIn('/usr/bin/xcrun lipo "$RUNNER_TEMP/xcross-bundle/bin/xcross" -verify_arch arm64', bundle)
        self.assertIn('echo "$RUNNER_TEMP/xcross-bundle/bin" >> "$GITHUB_PATH"', bundle)
        sdk = self.required_step(steps, 'Install selected native Xcode SDK through xcross')
        self.assertTrue(any(line.startswith('xcross sdk install "$XCODE_APP"') for line in sdk))
        build = self.required_step(steps, 'Build ARM64 simulator app through production xcross')
        command = f'xcross --verbose {feature} build --target-platform simulator'
        self.assertTrue(any(line.startswith(command) for line in build))
        if feature == 'flutter':
            self.assertTrue(any(line.startswith(command) and '--debug' in line for line in build))
        smoke = self.required_step(steps, f'Boot install launch and observe {feature.title()} app headlessly')
        self.assertIn(f'apps=("$RUNNER_TEMP/{feature}-simulator/build/xcross-ios-simulator/"*.app)', smoke)
        self.assertIn('test "${#apps[@]}" -eq 1', smoke)
        self.assertTrue(any(line.startswith('python3 .github/scripts/simulator_smoke.py "${apps[0]}"') for line in smoke))
        self.assertIn(f'--ready-marker {marker}', smoke)
        self.assertNotIn('--simulator', workflow)
        self.assertIn('if: always()', workflow)

    def test_strict_guard_is_an_independent_unprivileged_job(self):
        workflow = (ROOT / '.github/workflows/architecture.yml').read_text()
        self.assertIn('contents: read', workflow)
        self.assertIn('persist-credentials: false', workflow)
        self.assertIn('sdk: 3.13.0', workflow)
        steps = workflow_steps(workflow_jobs(workflow)['architecture'])
        self.assertIn('dart pub get --enforce-lockfile', self.required_step(steps, 'Resolve locked dependencies'))
        self.assertIn('dart --packages=.dart_tool/package_config.json tool/architecture/check_test.dart', self.required_step(steps, 'Test architecture guard'))
        self.assertIn('dart --packages=.dart_tool/package_config.json tool/architecture/check.dart > architecture-report.json', self.required_step(steps, 'Enforce production architecture'))
        self.assertNotIn('--report', workflow)
        self.assertNotIn('continue-on-error', workflow)
        self.assertNotIn('secrets.', workflow)
        self.assertNotIn('setup-darwin-sdk', workflow)

    def test_simulator_jobs_use_target_platform_and_preserve_smoke(self):
        for name, feature, marker in (
            ('integration.yml', 'flutter', 'XCROSS_SIMULATOR_NATIVE_FIRST_FRAME_READY'),
            ('compose-integration.yml', 'compose', 'XCROSS_COMPOSE_READY'),
        ):
            with self.subTest(workflow=name):
                self.check_simulator_job((ROOT / '.github/workflows' / name).read_text(), feature, marker)

    def check_cross_host_simulator_run(self, workflow):
        jobs = workflow_jobs(workflow)
        build = workflow_steps(jobs['flutter-build'])
        for host, prefix in (('Linux', '"$RUNNER_TEMP/xcross-bundle/bin/xcross"'), ('Windows', '& "$env:RUNNER_TEMP\\xcross-bundle\\bin\\xcross.exe"')):
            step = build[f'Build Flutter example for ARM64 simulator on {host}']
            self.assertNotIn('continue-on-error', step)
            self.assertIn(f'{prefix} --verbose flutter build --target-platform simulator --debug', step['script'])
        upload = build['Upload Flutter example simulator app']
        self.assertNotIn('continue-on-error', upload)
        self.assertIn('flutter-example-simulator-${{ matrix.os }}-swift-${{ matrix.swift }}', '\n'.join(jobs['flutter-build']))
        self.assertIn('if-no-files-found: error', '\n'.join(jobs['flutter-build']))
        lines = jobs['flutter-example-simulator-run']
        text = '\n'.join(lines)
        self.assertIn('    needs: flutter-build', lines)
        self.assertIn('    runs-on: macos-15', lines)
        self.assertFalse(any(line.startswith('    continue-on-error:') for line in lines))
        self.assertIn('host: [ubuntu-24.04, ubuntu-24.04-arm, windows-2022, windows-11-arm]', text)
        self.assertIn("swift: ['6.3.3', '6.4.0']", text)
        self.assertIn('name: flutter-example-simulator-${{ matrix.host }}-swift-${{ matrix.swift }}', text)
        steps = workflow_steps(lines)
        smoke = self.required_step(steps, 'Boot install launch and observe cross-built Flutter example headlessly')
        self.assertIn('test "${#apps[@]}" -eq 1', smoke)
        self.assertTrue(any(line.startswith('python3 .github/scripts/simulator_smoke.py "${apps[0]}"') for line in smoke))
        self.assertIn('--observe-seconds 30 --grace-seconds 10', smoke)
        self.assertEqual(steps['Upload simulator evidence'].get('if'), 'always()')

    def test_cross_host_simulator_apps_are_built_uploaded_and_run(self):
        self.check_cross_host_simulator_run((ROOT / '.github/workflows/integration.yml').read_text())

    def test_disabled_cross_host_simulator_run_is_rejected(self):
        original = (ROOT / '.github/workflows/integration.yml').read_text()
        name = '      - name: Boot install launch and observe cross-built Flutter example headlessly\n'
        for old, new in (
            (name, name + '        if: false\n'),
            (name, name + '        continue-on-error: true\n'),
            ('          python3 .github/scripts/simulator_smoke.py "${apps[0]}" \\\n            --output "$RUNNER_TEMP/ios-simulator-smoke/flutter-example"', '          echo mocked "${apps[0]}" \\\n            --output "$RUNNER_TEMP/ios-simulator-smoke/flutter-example"'),
            ('    needs: flutter-build\n    if: >-', '    needs: flutter-build\n    continue-on-error: true\n    if: >-'),
            ('"$RUNNER_TEMP/xcross-bundle/bin/xcross" --verbose flutter build --target-platform simulator --debug', 'echo skipped'),
        ):
            with self.subTest(new=new):
                self.assertIn(old, original)
                with self.assertRaises((AssertionError, KeyError)):
                    self.check_cross_host_simulator_run(original.replace(old, new))

    def test_jobs_running_example_fixtures_check_out_examples_first(self):
        jobs = workflow_jobs((ROOT / '.github/workflows/integration.yml').read_text())
        for job, first_use in (('flutter-build', None), ('native-host', 'Test xcross host workflows')):
            with self.subTest(job=job):
                steps = workflow_steps(jobs[job])
                names = list(steps)
                self.assertIn('git submodule update --init --checkout examples', self.required_step(steps, 'Update example submodule'))
                if first_use is not None:
                    self.assertLess(names.index('Update example submodule'), names.index(first_use))

    def test_warm_cache_builds_xcross_from_checkout_on_every_host(self):
        jobs = workflow_jobs((ROOT / '.github/workflows/warm-darwin-sdk.yml').read_text())
        steps = workflow_steps(jobs['warm-cache'])
        for name in ('Build xcross on Linux', 'Build xcross on Windows'):
            with self.subTest(step=name):
                self.assertIn(name, steps)
                self.assertNotIn('continue-on-error', steps[name])
                self.assertTrue(any('dart run tool/build_xcross.dart' in line and not line.startswith('#') for line in steps[name]['script']))
        names = list(steps)
        self.assertLess(names.index('Build xcross on Windows'), names.index('Install Darwin SDK with xcross'))
        self.assertNotIn('if', steps['Install Darwin SDK with xcross'])

    def test_disabled_or_optional_real_smoke_is_rejected(self):
        original = (ROOT / '.github/workflows/integration.yml').read_text()
        name = '      - name: Boot install launch and observe Flutter app headlessly\n'
        for replacement in (name + '        if: false\n', name + '        continue-on-error: true\n'):
            with self.subTest(replacement=replacement):
                with self.assertRaises(AssertionError):
                    self.check_simulator_job(original.replace(name, replacement), 'flutter', 'XCROSS_SIMULATOR_NATIVE_FIRST_FRAME_READY')

    def test_comments_and_mock_commands_cannot_replace_real_build_or_smoke(self):
        original = (ROOT / '.github/workflows/integration.yml').read_text()
        for old, new in (
            ('          xcross --verbose flutter build --target-platform simulator --debug', '          # xcross --verbose flutter build --target-platform simulator --debug'),
            ('          python3 .github/scripts/simulator_smoke.py "${apps[0]}"', '          echo mocked-smoke "${apps[0]}"'),
            ('          (cd packages/xcross && dart run tool/build_xcross.dart)', '          echo "dart run tool/build_xcross.dart"'),
        ):
            with self.subTest(command=old):
                with self.assertRaises(AssertionError):
                    self.check_simulator_job(original.replace(old, new), 'flutter', 'XCROSS_SIMULATOR_NATIVE_FIRST_FRAME_READY')


if __name__ == '__main__':
    unittest.main()
