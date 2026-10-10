import pathlib
import re
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


SMOKE_DIR = '${{ runner.temp }}/ios-simulator-smoke'
REPORT_PATHS = [SMOKE_DIR + '/*/screenshot.png', SMOKE_DIR + '/*/result.json']
SIMULATOR_JOBS = (
    ('integration.yml', 'flutter-simulator', 'flutter-arm64-ios-simulator', 'simulator-report-flutter-native'),
    ('integration.yml', 'flutter-example-simulator-run', 'flutter-example-simulator-run-${{ matrix.host }}', 'simulator-report-flutter-${{ matrix.host }}'),
    ('integration.yml', 'compose-simulator', 'compose-arm64-ios-simulator', 'simulator-report-compose-native'),
)
STAGE = 'Stage simulator screenshots for the report'
EVIDENCE = 'Upload simulator evidence'


def step_body(lines, name):
    text = '\n'.join(lines) + '\n'
    return text.split(f'      - name: {name}\n', 1)[1].split('\n\n', 1)[0]


class ArchitectureWorkflowTests(unittest.TestCase):
    def check_simulator_uploads(self, workflow, job, artifact, staged):
        lines = workflow_jobs(workflow)[job]
        steps = workflow_steps(lines)
        names = list(steps)
        uploads = [name for name, step in steps.items() if step.get('uses', '').startswith('actions/upload-artifact@')]
        self.assertEqual(uploads, [STAGE, EVIDENCE])
        smokes = [name for name, step in steps.items() if any('simulator_smoke.py' in line for line in step['script'])]
        self.assertTrue(smokes)
        self.assertLess(names.index(smokes[-1]), names.index(STAGE))
        self.assertLess(names.index(STAGE), names.index(EVIDENCE))
        stage = step_body(lines, STAGE)
        evidence = step_body(lines, EVIDENCE)
        self.assertEqual(steps[STAGE].get('if'), 'success()')
        self.assertEqual(steps[EVIDENCE].get('if'), 'failure() || cancelled()')
        self.assertEqual(re.findall(r'(?m)^ {12}(\S.*)$', stage.split('path: |\n', 1)[1].split('\n          if-no', 1)[0]), REPORT_PATHS)
        self.assertEqual(re.findall(r'(?m)^ +path: (.+)$', evidence), [SMOKE_DIR])
        self.assertIn(f'          name: {staged}\n', stage + '\n')
        self.assertIn(f'          name: {artifact}-${{{{ github.run_attempt }}}}\n', evidence + '\n')
        self.assertIn('          retention-days: 1', stage)
        self.assertIn('          retention-days: 7', evidence)
        for body in (stage, evidence):
            self.assertIn('          if-no-files-found: warn', body)
            self.assertNotIn('continue-on-error', body)

    def check_simulator_report(self, workflow, simulator_jobs, title):
        jobs = workflow_jobs(workflow)
        lines = jobs['simulator-report']
        text = '\n'.join(lines)
        self.assertIn(f"    needs: [gate, {', '.join(simulator_jobs)}]", lines)
        self.assertIn("    if: ${{ !cancelled() && needs.gate.outputs.trusted == 'true' }}", lines)
        self.assertIn('      contents: write', lines)
        self.assertIn('      pull-requests: write', lines)
        steps = workflow_steps(lines)
        download = step_body(lines, 'Download staged simulator screenshots')
        self.assertIn('uses: actions/download-artifact@', download)
        self.assertIn('pattern: simulator-report-*', download)
        report = step_body(lines, 'Publish screenshots and write the run report')
        self.assertIn('uses: ./.github/actions/simulator-report', report)
        self.assertIn(f'title: {title}', report)
        self.assertIn('sha: ${{ needs.gate.outputs.sha }}', report)
        self.assertIn('pr: ${{ needs.gate.outputs.pr }}', report)
        self.assertNotIn('upload-artifact', text)
        self.assertNotIn('continue-on-error', text)
        self.assertTrue(steps)

    def test_simulator_jobs_stage_screenshots_on_success_and_evidence_on_failure(self):
        for name, job, artifact, staged in SIMULATOR_JOBS:
            with self.subTest(job=job):
                self.check_simulator_uploads((ROOT / '.github/workflows' / name).read_text(), job, artifact, staged)

    def test_one_report_job_shows_every_flutter_and_compose_screenshot(self):
        self.check_simulator_report(
            (ROOT / '.github/workflows/integration.yml').read_text(),
            ['flutter-simulator', 'flutter-example-simulator-run', 'compose-simulator'],
            'Integration simulator report',
        )
        self.assertFalse((ROOT / '.github/workflows/compose-integration.yml').exists())

    def test_each_branch_rule_context_gets_its_own_verdict(self):
        jobs = workflow_jobs((ROOT / '.github/workflows/integration.yml').read_text())
        for job, context, required in (
            ('verdict', 'Integration Tests', ['flutter-build', 'flutter-aot-reference', 'flutter-aot-parity', 'flutter-aot-run', 'flutter-simulator', 'flutter-example-simulator-run', 'native-host', 'simulator-report']),
            ('compose-verdict', 'Compose Integration Tests', ['compose-build', 'compose-simulator', 'simulator-report']),
        ):
            with self.subTest(job=job):
                text = '\n'.join(jobs[job])
                self.assertIn(f"    needs: [gate, {', '.join(required)}]", jobs[job])
                self.assertIn(f'context: {context}', text)
                self.assertIn('run: exit 1', text)
        gate = '\n'.join(jobs['gate'])
        for context in ('Integration Tests', 'Compose Integration Tests'):
            self.assertIn(f'context: {context}\n          state: pending', gate)

    def test_report_action_publishes_to_a_dedicated_branch_and_writes_the_summary(self):
        action = (ROOT / '.github/actions/simulator-report/action.yml').read_text()
        self.assertIn('branch=simulator-reports', action)
        self.assertIn('--publish-dir "$work/$REPORT_PATH"', action)
        self.assertIn('REPORT_PATH: ${{ github.run_id }}/${{ github.run_attempt }}/${{ github.job }}', action)
        self.assertIn('https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${commit}/${REPORT_PATH}', action)
        self.assertIn('--image-base "$BASE"', action)
        self.assertIn('if: inputs.pr != \'\'', action)
        self.assertIn('python3 .github/scripts/report_comment.py', action)
        self.assertIn('contents/examples?ref=${SHA}', action)
        self.assertIn('--examples-commit "$EXAMPLES_SHA"', action)
        self.assertNotIn('gh-pages', action)

    def test_broadened_or_unconditional_simulator_uploads_are_rejected(self):
        for name, job, artifact, staged in SIMULATOR_JOBS:
            original = (ROOT / '.github/workflows' / name).read_text()
            for old, new in (
                ('        if: success()\n', '        if: always()\n'),
                ('        if: failure() || cancelled()\n', '        if: always()\n'),
                ('        if: failure() || cancelled()\n', '        if: failure()\n'),
                ('/ios-simulator-smoke/*/screenshot.png\n', '/ios-simulator-smoke\n'),
                (f'      - name: {STAGE}\n', '      - name: Upload simulator pictures\n'),
                ('          retention-days: 1\n', '          retention-days: 7\n'),
            ):
                with self.subTest(job=job, new=new):
                    self.assertIn(old, original)
                    with self.assertRaises((AssertionError, KeyError, IndexError)):
                        self.check_simulator_uploads(original.replace(old, new), job, artifact, staged)

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
        self.assertIn('    needs: gate', lines)
        self.assertIn("    if: needs.gate.outputs.run == 'true' && needs.gate.outputs.trusted == 'true'", lines)
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
        self.assertNotIn('if: always()', '\n'.join(lines))

    def check_aot_parity(self, workflow):
        jobs = workflow_jobs(workflow)
        self.assertIn("    if: needs.gate.outputs.run == 'true' && needs.gate.outputs.trusted == 'true'", jobs['flutter-aot-reference'])
        parity = jobs['flutter-aot-parity']
        self.assertIn('    timeout-minutes: 15', parity)
        self.assertNotIn('jq', '\n'.join(parity))
        hosts = re.search(r'os: \[(.+)\]', '\n'.join(jobs['flutter-build'])).group(1).split(', ')
        self.assertIn(f"      AOT_HOSTS: {' '.join(hosts)}", parity)
        self.assertIn('      AOT_APPS: smoke plugins', parity)
        steps = workflow_steps(parity)
        for mode, smoke, plugins in (
            ('release', '__text,__const,Flutter.__text', '__text,Flutter.__text'),
            ('profile', '__text,Flutter.__text', 'Flutter.__text'),
        ):
            compare = [name for name in steps if name.startswith(f'Compare {mode} ')]
            self.assertEqual(len(compare), 1)
            script = self.required_step(steps, compare[0])
            self.assertIn('for app in $AOT_APPS; do', script)
            self.assertIn(f'sections={smoke}', script)
            self.assertIn(f'[ "$app" = plugins ] && sections={plugins}', script)
            self.assertIn('dart run packages/xcross/tool/verify_flutter_aot.dart \\', script)
            self.assertIn(f'"$RUNNER_TEMP/cross/flutter-aot-digests-$host/$app-{mode}.json" \\', script)
            self.assertIn(f'"--expect=$RUNNER_TEMP/reference/$app-{mode}.json" \\', script)
            self.assertIn('"--sections=$sections" ||', script)
            self.assertIn('exit "$failed"', script)
        registrant = self.required_step(steps, 'Compare the Dart plugin registrant with flutter build ios')
        self.assertIn('diff -u "$RUNNER_TEMP/reference/plugins-registrant.dart" \\', registrant)
        self.assertIn('"$RUNNER_TEMP/cross/flutter-aot-digests-$host/plugins-registrant.dart" ||', registrant)
        self.assertIn('{ echo "::error::$host Dart plugin registrant differs from flutter build ios"; failed=1; }', registrant)
        self.assertIn('exit "$failed"', registrant)
        build = workflow_steps(jobs['flutter-build'])
        linux = build['Build precompiled Flutter apps on Linux']['script']
        windows = build['Build precompiled Flutter apps on Windows']['script']
        reference = '\n'.join(workflow_steps(jobs['flutter-aot-reference'])['Record flutter build ios digests']['script'])
        self.assertIn('for app in smoke plugins; do', linux)
        self.assertIn("foreach ($app in 'smoke', 'plugins') {", windows)
        self.assertIn('for app in smoke plugins; do', reference)
        self.assertIn('cp -R .github/fixtures/aot_plugins "$RUNNER_TEMP/aot-plugins"', linux)
        self.assertIn('Copy-Item -Recurse .github/fixtures/aot_plugins "$env:RUNNER_TEMP/aot-plugins"', windows)
        self.assertIn('cp -R .github/fixtures/aot_plugins "$RUNNER_TEMP/aot-plugins"', reference)
        self.assertIn('"$RUNNER_TEMP/aot-$app/build/xcross-ios" --dsym=required \\', linux)
        self.assertIn('"$env:RUNNER_TEMP/aot-$app/build/xcross-ios" --dsym=optional `', windows)
        registrant = '.dart_tool/flutter_build/dart_plugin_registrant.dart'
        self.assertIn(f'cp "$RUNNER_TEMP/aot-plugins/{registrant}" \\', linux)
        self.assertIn('"$RUNNER_TEMP/aot-digests/plugins-registrant.dart"', linux)
        self.assertIn(f'Copy-Item "$env:RUNNER_TEMP/aot-plugins/{registrant}" `', windows)
        self.assertIn('"$env:RUNNER_TEMP/aot-digests/plugins-registrant.dart"', windows)
        self.assertIn(f'cp "$RUNNER_TEMP/aot-plugins/{registrant}" \\', reference)
        self.assertIn('"$RUNNER_TEMP/aot-reference/plugins-registrant.dart"', reference)

    def check_aot_run(self, workflow):
        jobs = workflow_jobs(workflow)
        lines = jobs['flutter-aot-run']
        text = '\n'.join(lines)
        self.assertIn('    needs: [gate, flutter-build]', lines)
        self.assertIn('    runs-on: macos-15', lines)
        self.assertNotIn('continue-on-error', text)
        hosts = re.search(r'os: \[(.+)\]', '\n'.join(jobs['flutter-build'])).group(1).split(', ')
        self.assertIn(f"      AOT_RUN_HOSTS: {' '.join(hosts)}", lines)
        steps = workflow_steps(lines)
        self.assertIn('pattern: flutter-aot-apps-*', step_body(lines, 'Download precompiled apps'))
        run = self.required_step(steps, 'Run release and profile apps as Mac Catalyst')
        self.assertIn('for host in $AOT_RUN_HOSTS; do', run)
        self.assertIn('for mode in release profile; do', run)
        self.assertIn('python3 .github/scripts/aot_run_smoke.py \\', run)
        self.assertIn('--ready-marker "XCROSS_AOT_READY mode=$mode probe=ios build=2.3.4+56" \\', run)
        self.assertIn('{ echo "::error::$host $mode app did not run"; failed=1; }', run)
        self.assertIn('exit "$failed"', run)
        self.assertEqual(steps['Upload run evidence'].get('if'), 'failure() || cancelled()')
        build = workflow_steps(jobs['flutter-build'])
        self.assertIn('cp -R "$RUNNER_TEMP/aot-plugins/build/xcross-ios/aot_plugins.app" "$RUNNER_TEMP/aot-apps/$mode/"', build['Build precompiled Flutter apps on Linux']['script'])
        self.assertIn('Copy-Item -Recurse "$env:RUNNER_TEMP/aot-plugins/build/xcross-ios/aot_plugins.app" "$env:RUNNER_TEMP/aot-apps/$mode/"', build['Build precompiled Flutter apps on Windows']['script'])
        upload = step_body(jobs['flutter-build'], 'Upload precompiled apps')
        self.assertIn('          name: flutter-aot-apps-${{ matrix.os }}', upload)
        self.assertIn('          if-no-files-found: error', upload)

    def test_cross_built_precompiled_apps_run_as_mac_catalyst(self):
        self.check_aot_run((ROOT / '.github/workflows/integration.yml').read_text())

    def test_weakened_aot_run_is_rejected(self):
        original = (ROOT / '.github/workflows/integration.yml').read_text()
        for old, new in (
            ('      AOT_RUN_HOSTS: ubuntu-24.04 ubuntu-24.04-arm windows-2022 windows-11-arm\n', '      AOT_RUN_HOSTS: ubuntu-24.04\n'),
            ('            for mode in release profile; do\n              echo "::group::$host $mode"\n', '            for mode in release; do\n              echo "::group::$host $mode"\n'),
            ('                { echo "::error::$host $mode app did not run"; failed=1; }\n', '                true\n'),
            ('      - name: Run release and profile apps as Mac Catalyst\n', '      - name: Run release and profile apps as Mac Catalyst\n        continue-on-error: true\n'),
            ('              python3 .github/scripts/aot_run_smoke.py \\\n', '              echo python3 .github/scripts/aot_run_smoke.py \\\n'),
        ):
            with self.subTest(new=new):
                self.assertIn(old, original)
                with self.assertRaises((AssertionError, KeyError, IndexError, AttributeError)):
                    self.check_aot_run(original.replace(old, new))

    def test_aot_parity_compares_every_host_with_the_digest_verifier(self):
        self.check_aot_parity((ROOT / '.github/workflows/integration.yml').read_text())

    def test_weakened_aot_parity_is_rejected(self):
        original = (ROOT / '.github/workflows/integration.yml').read_text()
        for old, new in (
            ("    if: needs.gate.outputs.run == 'true' && needs.gate.outputs.trusted == 'true'\n    permissions:\n      contents: read\n    runs-on: macos-15\n    timeout-minutes: 45\n", "    if: needs.gate.outputs.run == 'true'\n    permissions:\n      contents: read\n    runs-on: macos-15\n    timeout-minutes: 45\n"),
            ('      AOT_HOSTS: ubuntu-24.04 ubuntu-24.04-arm windows-2022 windows-11-arm\n', '      AOT_HOSTS: ubuntu-24.04\n'),
            ('      AOT_APPS: smoke plugins\n', '      AOT_APPS: smoke\n'),
            ('          for app in smoke plugins; do\n            for mode in release profile; do\n              (cd "$RUNNER_TEMP/aot-$app" && flutter build ios', '          for app in smoke; do\n            for mode in release profile; do\n              (cd "$RUNNER_TEMP/aot-$app" && flutter build ios'),
            ('              [ "$app" = plugins ] && sections=Flutter.__text\n', '              [ "$app" = plugins ] && sections=\n'),
            ('              sections=__text,__const,Flutter.__text\n', '              sections=__text\n'),
            ('              { echo "::error::$host Dart plugin registrant differs from flutter build ios"; failed=1; }\n', '              true\n'),
            ('          exit "$failed"\n', '          exit 0\n'),
            ('--dsym=required', '--dsym=optional'),
        ):
            with self.subTest(new=new):
                self.assertIn(old, original)
                with self.assertRaises((AssertionError, KeyError, IndexError, AttributeError)):
                    self.check_aot_parity(original.replace(old, new))

    def test_strict_guard_is_an_independent_unprivileged_job(self):
        workflow = (ROOT / '.github/workflows/architecture.yml').read_text()
        self.assertIn('contents: read', workflow)
        self.assertIn('persist-credentials: false', workflow)
        self.assertIn('sdk: 3.13.0', workflow)
        steps = workflow_steps(workflow_jobs(workflow)['architecture'])
        self.assertIn('dart pub get --enforce-lockfile', self.required_step(steps, 'Resolve locked dependencies'))
        self.assertIn('dart test', self.required_step(steps, 'Test repo analyzer plugin'))
        self.assertEqual(steps['Test repo analyzer plugin'].get('working-directory'), 'tool/repo_analyzer')
        self.assertIn('dart analyze --fatal-warnings --format=machine > architecture-report.txt', self.required_step(steps, 'Enforce architecture with the repo analyzer plugin'))
        options = (ROOT / 'analysis_options.yaml').read_text()
        self.assertIn('plugins:\n  repo_analyzer:\n    path: tool/repo_analyzer\n', options)
        self.assertNotIn('--report', workflow)
        self.assertNotIn('continue-on-error', workflow)
        self.assertNotIn('secrets.', workflow)
        self.assertNotIn('setup-darwin-sdk', workflow)

    def test_simulator_jobs_use_target_platform_and_preserve_smoke(self):
        for name, feature, marker in (
            ('integration.yml', 'compose', 'XCROSS_COMPOSE_READY'),
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
        self.assertIn('name: flutter-example-simulator-${{ matrix.os }}\n', '\n'.join(jobs['flutter-build']) + '\n')
        self.assertIn('if-no-files-found: error', '\n'.join(jobs['flutter-build']))
        lines = jobs['flutter-example-simulator-run']
        text = '\n'.join(lines)
        self.assertIn('    needs: [gate, flutter-build]', lines)
        self.assertIn('    runs-on: macos-15', lines)
        self.assertFalse(any(line.startswith('    continue-on-error:') for line in lines))
        self.assertIn('host: [ubuntu-24.04, ubuntu-24.04-arm, windows-2022, windows-11-arm]', text)
        self.assertIn('name: flutter-example-simulator-${{ matrix.host }}\n', text + '\n')
        steps = workflow_steps(lines)
        smoke = self.required_step(steps, 'Boot install launch and observe cross-built Flutter example headlessly')
        self.assertIn('test "${#apps[@]}" -eq 1', smoke)
        self.assertTrue(any(line.startswith('python3 .github/scripts/simulator_smoke.py "${apps[0]}"') for line in smoke))
        self.assertIn('--observe-seconds 30 --grace-seconds 10', [line.removesuffix('\\').rstrip() for line in smoke])
        self.assertIn('--ready-marker XCROSS_FLUTTER_EXAMPLE_READY', smoke)
        self.assertEqual(steps[EVIDENCE].get('if'), 'failure() || cancelled()')
        self.assertEqual(steps[STAGE].get('if'), 'success()')

    def check_native_example_simulator_run(self, workflow):
        steps = workflow_steps(workflow_jobs(workflow)['flutter-simulator'])
        names = list(steps)
        self.assertIn('git submodule update --init --checkout examples', self.required_step(steps, 'Update example submodule'))
        build_name = 'Build Flutter example for ARM64 simulator through production xcross'
        smoke_name = 'Boot install launch and observe Flutter example headlessly'
        rust_name = 'Install Flutter example Rust toolchain with preinstalled rustup'
        rust = self.required_step(steps, rust_name)
        self.assertEqual(steps[rust_name].get('working-directory'), 'examples/flutter_example/rust')
        self.assertIn('channel="$(sed -n \'s/^channel = "\\(.*\\)"$/\\1/p\' rust-toolchain.toml)"', rust)
        self.assertIn('test -n "$channel"', rust)
        self.assertTrue(any(line.startswith('rustup toolchain install "$channel"') for line in rust))
        self.assertIn('--target aarch64-apple-ios-sim --target aarch64-apple-ios', rust)
        self.assertIn('grep -qx aarch64-apple-ios-sim "$RUNNER_TEMP/rust-targets.txt"', rust)
        self.assertIn('grep -qx aarch64-apple-ios "$RUNNER_TEMP/rust-targets.txt"', rust)
        self.assertLess(names.index('Update example submodule'), names.index(rust_name))
        self.assertLess(names.index(rust_name), names.index(build_name))
        build = self.required_step(steps, build_name)
        self.assertEqual(steps[build_name].get('working-directory'), 'examples/flutter_example')
        self.assertTrue(any(line.startswith('xcross --verbose flutter build --target-platform simulator --debug') for line in build))
        smoke = self.required_step(steps, smoke_name)
        self.assertIn('apps=(examples/flutter_example/build/xcross-ios-simulator/*.app)', smoke)
        self.assertIn('test "${#apps[@]}" -eq 1', smoke)
        self.assertTrue(any(line.startswith('python3 .github/scripts/simulator_smoke.py "${apps[0]}"') for line in smoke))
        self.assertIn('--ready-marker XCROSS_FLUTTER_EXAMPLE_READY', smoke)
        self.assertLess(names.index('Update example submodule'), names.index(build_name))
        self.assertLess(names.index('Build native production xcross CLI'), names.index(build_name))
        self.assertLess(names.index(build_name), names.index(smoke_name))
        self.assertLess(names.index(smoke_name), names.index(STAGE))
        self.assertLess(names.index(STAGE), names.index(EVIDENCE))

    def check_flutter_example_smokes_require_marker(self, workflow):
        smokes = []
        for job, lines in workflow_jobs(workflow).items():
            for name, step in workflow_steps(lines).items():
                script = step.get('script', [])
                if any('simulator_smoke.py' in line for line in script) and any('flutter-example' in line for line in script):
                    smokes.append((job, name, script))
        self.assertGreaterEqual(len(smokes), 2)
        for job, name, script in smokes:
            self.assertIn('--ready-marker XCROSS_FLUTTER_EXAMPLE_READY', script, f'{job}: {name}')

    def test_native_flutter_example_is_built_and_run_with_ready_marker(self):
        self.check_native_example_simulator_run((ROOT / '.github/workflows/integration.yml').read_text())

    def test_every_flutter_example_smoke_requires_ready_marker(self):
        self.check_flutter_example_smokes_require_marker((ROOT / '.github/workflows/integration.yml').read_text())

    def test_missing_flutter_example_ready_marker_is_rejected(self):
        original = (ROOT / '.github/workflows/integration.yml').read_text()
        marker = ' \\\n            --ready-marker XCROSS_FLUTTER_EXAMPLE_READY'
        self.assertEqual(original.count(marker), 2)
        first = original.index(marker)
        variants = (
            original[:first] + original[first + len(marker):],
            original[:first + 1] + original[first + 1:].replace(marker, '', 1),
            original.replace(marker, ''),
            original.replace('--ready-marker XCROSS_FLUTTER_EXAMPLE_READY', '--ready-marker SOMETHING_ELSE'),
        )
        for index, variant in enumerate(variants):
            with self.subTest(variant=index):
                with self.assertRaises(AssertionError):
                    self.check_flutter_example_smokes_require_marker(variant)

    def test_disabled_native_flutter_example_run_is_rejected(self):
        original = (ROOT / '.github/workflows/integration.yml').read_text()
        smoke = '      - name: Boot install launch and observe Flutter example headlessly\n'
        build = '      - name: Build Flutter example for ARM64 simulator through production xcross\n'
        rust = '      - name: Install Flutter example Rust toolchain with preinstalled rustup\n'
        for old, new in (
            (smoke, smoke + '        if: false\n'),
            (rust, rust + '        if: false\n'),
            (rust, rust + '        continue-on-error: true\n'),
            ('            --target aarch64-apple-ios-sim --target aarch64-apple-ios\n', '            --target aarch64-apple-ios\n'),
            ('          rustup toolchain install "$channel"', '          echo rustup toolchain install "$channel"'),
            (build, build + '        continue-on-error: true\n'),
            ('          xcross --verbose flutter build --target-platform simulator --debug 2>&1 | \\\n            tee "$RUNNER_TEMP/ios-simulator-smoke/flutter-example-build.log"', '          echo skipped'),
        ):
            with self.subTest(new=new):
                self.assertIn(old, original)
                with self.assertRaises((AssertionError, KeyError)):
                    self.check_native_example_simulator_run(original.replace(old, new))

    def test_cross_host_simulator_apps_are_built_uploaded_and_run(self):
        self.check_cross_host_simulator_run((ROOT / '.github/workflows/integration.yml').read_text())

    def test_disabled_cross_host_simulator_run_is_rejected(self):
        original = (ROOT / '.github/workflows/integration.yml').read_text()
        name = '      - name: Boot install launch and observe cross-built Flutter example headlessly\n'
        for old, new in (
            (name, name + '        if: false\n'),
            (name, name + '        continue-on-error: true\n'),
            ('          python3 .github/scripts/simulator_smoke.py "${apps[0]}" \\\n            --output "$RUNNER_TEMP/ios-simulator-smoke/flutter-example"', '          echo mocked "${apps[0]}" \\\n            --output "$RUNNER_TEMP/ios-simulator-smoke/flutter-example"'),
            ('    needs: [gate, flutter-build]\n    if: >-', '    needs: [gate, flutter-build]\n    continue-on-error: true\n    if: >-'),
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

    def check_open_apple_macros_cache(self, workflow, job, first_build, last_build):
        lines = workflow_jobs(workflow)[job]
        steps = workflow_steps(lines)
        names = list(steps)
        restore = steps['Restore open apple macros server']
        save = steps['Save open apple macros server']
        self.assertTrue(restore['uses'].startswith('actions/cache/restore@'))
        self.assertTrue(save['uses'].startswith('actions/cache/save@'))
        self.assertEqual(restore.get('id'), 'open-apple-macros')
        self.assertIn('!cancelled()', save['if'])
        self.assertIn("steps.open-apple-macros.outputs.cache-hit != 'true'", save['if'])
        self.assertNotIn('continue-on-error', save)
        self.assertLess(names.index('Restore open apple macros server'), names.index(first_build))
        self.assertLess(names.index(last_build), names.index('Save open apple macros server'))
        text = '\n'.join(lines)
        bodies = [text.split(f'      - name: {name}\n', 1)[1].split('\n\n', 1)[0] for name in ('Restore open apple macros server', 'Save open apple macros server')]
        keys = [re.search(r'(?m)^ +key: (.+)$', body).group(1) for body in bodies]
        paths = [body.split('path: |\n', 1)[1].split('\n          key:', 1)[0] for body in bodies]
        self.assertEqual(keys[0], keys[1])
        self.assertEqual(paths[0], paths[1])
        self.assertIn("hashFiles('.gitmodules', 'packages/xcross/lib/src/shared/flutter/swiftpm/open_apple_macros.dart')", keys[0])
        self.assertIn('${{ runner.os }}-${{ runner.arch }}', keys[0])
        return keys[0]

    def test_open_apple_macros_server_is_cached_around_every_build(self):
        workflow = (ROOT / '.github/workflows/integration.yml').read_text()
        key = self.check_open_apple_macros_cache(workflow, 'flutter-build', 'Build Flutter example on Linux', 'Build Flutter example on Windows')
        self.assertIn('${{ env.SWIFT_VERSION }}', key)
        key = self.check_open_apple_macros_cache(workflow, 'flutter-simulator', 'Build Flutter example for ARM64 simulator through production xcross', 'Build Flutter example for ARM64 simulator through production xcross')
        self.assertIn('${{ steps.xcode.outputs.app }}', key)

    def test_unkeyed_or_skipped_open_apple_macros_cache_is_rejected(self):
        original = (ROOT / '.github/workflows/integration.yml').read_text()
        for old, new in (
            ("${{ !cancelled() && steps.darwin", "${{ success() && steps.darwin"),
            ("-swift-${{ env.SWIFT_VERSION }}-", "-"),
            ("'packages/xcross/lib/src/shared/flutter/swiftpm/open_apple_macros.dart'", "'.gitmodules'"),
        ):
            with self.subTest(new=new):
                self.assertIn(old, original)
                with self.assertRaises(AssertionError):
                    workflow = original.replace(old, new, 1)
                    key = self.check_open_apple_macros_cache(workflow, 'flutter-build', 'Build Flutter example on Linux', 'Build Flutter example on Windows')
                    self.assertIn('${{ env.SWIFT_VERSION }}', key)

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
        name = '      - name: Boot install launch and observe Compose app headlessly\n'
        for replacement in (name + '        if: false\n', name + '        continue-on-error: true\n'):
            with self.subTest(replacement=replacement):
                with self.assertRaises(AssertionError):
                    self.check_simulator_job(original.replace(name, replacement), 'compose', 'XCROSS_COMPOSE_READY')

    def test_scratch_flutter_fixture_is_not_compiled(self):
        workflow = (ROOT / '.github/workflows/integration.yml').read_text()
        self.assertNotIn('prepare_simulator_fixture.py flutter', workflow)
        self.assertNotIn('XCROSS_SIMULATOR_NATIVE_FIRST_FRAME_READY', workflow)
        self.assertNotIn('$RUNNER_TEMP/flutter-simulator', workflow)

    def test_comments_and_mock_commands_cannot_replace_real_build_or_smoke(self):
        original = (ROOT / '.github/workflows/integration.yml').read_text()
        for old, new in (
            ('          xcross --verbose compose build --target-platform simulator', '          # xcross --verbose compose build --target-platform simulator'),
            ('          python3 .github/scripts/simulator_smoke.py "${apps[0]}"', '          echo mocked-smoke "${apps[0]}"'),
            ('          (cd packages/xcross && dart run tool/build_xcross.dart)', '          echo "dart run tool/build_xcross.dart"'),
        ):
            with self.subTest(command=old):
                with self.assertRaises(AssertionError):
                    self.check_simulator_job(original.replace(old, new), 'compose', 'XCROSS_COMPOSE_READY')


if __name__ == '__main__':
    unittest.main()
