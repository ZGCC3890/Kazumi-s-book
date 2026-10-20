"""Exercise shell orchestration with device boundaries replaced by command doubles."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


RUNNER = Path(__file__).with_name('run.sh').resolve()
BASH = 'C:/Program Files/Git/bin/bash.exe' if os.name == 'nt' else '/bin/bash'
DOUBLES = {
    'adb': '''#!/usr/bin/env bash
echo "adb $*" >> events
case "$*" in
  'shell content query'*)
    if [ "${FAIL_AT:-}" = media ]; then echo 'Volume not ready'; return 1; fi
    echo 'No result found.' ;;
  'shell dumpsys window') echo 'mCurrentFocus=test' ;;
  'shell settings put secure immersive_mode_confirmations confirmed') touch immersive-confirmed ;;
esac
''',
    'curl': '''#!/usr/bin/env bash
echo '{}'
''',
    'python3': '''#!/usr/bin/env bash
local script="$1"; shift
echo "python ${script##*/} $*" >> events
case "$script" in
  */fixture_server.py)
    if [ "${FAIL_AT:-}" = fixture ]; then echo 'fixture bind failed'; exit 4; fi
    trap 'exit 143' TERM
    if [ "${FAIL_AT:-}" != fixture-timeout ]; then touch build/android-ui/fixture.ready; fi
    while :; do /usr/bin/sleep 0.1; done ;;
  */run_stage.py) echo "stage $1" >> "$2"; shift 2; "$@" ;;
  */verify_sync.py) if [ "${FAIL_AT:-}" = verify-sync ]; then return 8; fi ;;
esac
''',
    'maestro': '''#!/usr/bin/env bash
local flow="${*: -1}"
echo "flow $flow" >> events
if [ "${FAIL_AT:-}" = "$flow" ]; then echo 'assertion failed'; return 7; fi
case "$flow" in
  .maestro/00-upgrade-seed.yaml) touch immersive-confirmed ;;
  .maestro/main.yaml|.maestro/owned-main.yaml)
    if [ ! -f immersive-confirmed ]; then echo 'System fullscreen prompt covers reader'; return 6; fi
    touch clipboard-rule ;;
  .maestro/08-accounts.yaml)
    if [ ! -f clipboard-rule ]; then echo 'No copied rule for the select-all operation'; return 9; fi ;;
esac
''',
    'sleep': '#!/usr/bin/env bash\n/usr/bin/sleep 0.01\n',
}


class NativeRunnerTest(unittest.TestCase):
    def run_suite(self, suite, layout='phone', scope='full', failure=''):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ['android-upgrade-apk', 'android-ui-apk']:
                (root / name).mkdir()
                (root / name / 'app-x86_64-release.apk').write_bytes(b'APK double')
            fixture = root / 'build/android-ui/fixtures'
            fixture.mkdir(parents=True)
            (fixture / 'clip.mp4').write_bytes(b'video double')
            shutil.copyfile(RUNNER, root / 'run.sh')
            env = dict(os.environ, FAIL_AT=failure)
            definitions = '\n'.join(f'{name}() {{\n{content}\n}}\nexport -f {name}'
                                    for name, content in DOUBLES.items())
            command = definitions + '\nbash run.sh "$@"'
            result = subprocess.run([BASH, '-c', command, '--', layout, scope, suite],
                cwd=root, env=env, capture_output=True, text=True, timeout=30)
            events_path = root / 'events'
            events = events_path.read_text(encoding='utf-8') if events_path.exists() else ''
            return result, events

    def test_parallel_suites_preserve_every_flow_once_per_layout(self):
        for layout in ['phone', 'tablet']:
            with self.subTest(layout=layout):
                full, full_events = self.run_suite('full', layout)
                upgrade, upgrade_events = self.run_suite('upgrade', layout)
                reading, reading_events = self.run_suite('reading', layout)
                for result in [full, upgrade, reading]:
                    self.assertEqual(result.returncode, 0, result.stderr)
                def flows(events):
                    return sorted(line for line in events.splitlines() if line.startswith('flow '))
                self.assertEqual(flows(full_events), flows(upgrade_events + reading_events))
                self.assertEqual(len(flows(full_events)), 6)
                self.assertNotIn('install -r android-upgrade-apk', reading_events)
                self.assertIn('verify_upgrade.py legacy', upgrade_events)
                self.assertIn('verify_upgrade.py upgraded', upgrade_events)
                self.assertIn('verify_sync.py build/android-ui/webdav-state.json full', reading_events)
                self.assertIn('exercise_conflict.py resolved', reading_events)
                self.assertIn('flow .maestro/08-accounts.yaml', reading_events)
                self.assertNotIn('flow .maestro/08-accounts.yaml', upgrade_events)
                size = '800x1280' if layout == 'tablet' else '480x900'
                self.assertIn('adb shell wm size ' + size, reading_events)

    def test_owned_diagnostics_selects_owned_flow(self):
        result, events = self.run_suite('full', scope='owned')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('flow .maestro/owned-main.yaml', events)

    def test_failures_stop_execution_and_preserve_status(self):
        for failure, code in [('.maestro/00-upgrade-seed.yaml', 7),
                              ('.maestro/main.yaml', 7), ('verify-sync', 8)]:
            with self.subTest(failure=failure):
                result, events = self.run_suite('full', failure=failure)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertNotIn('flow .maestro/08-accounts.yaml', events)

    def test_environment_startup_failures_are_visible(self):
        for failure, message in [('fixture', 'fixture bind failed'),
                                 ('fixture-timeout', 'did not become ready'),
                                 ('media', 'Volume not ready')]:
            with self.subTest(failure=failure):
                result, events = self.run_suite('full', failure=failure)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(message, result.stdout + result.stderr)
                self.assertNotIn('flow ', events)

    def test_invalid_arguments_stop_before_device_operations(self):
        for suite, scope in [('bad', 'full'), ('full', 'bad')]:
            result, events = self.run_suite(suite, scope=scope)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(events, '')


if __name__ == '__main__':
    unittest.main()
