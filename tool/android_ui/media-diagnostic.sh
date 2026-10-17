#!/usr/bin/env bash
set -euo pipefail
mkdir -p build/media-diagnostic/fixtures
capture() {
  adb logcat -d > build/media-diagnostic/final-logcat.txt
  adb exec-out screencap -p > build/media-diagnostic/final-screen.png
}
trap capture EXIT
prior_clip=diagnostic-prior/work/Kazumi-s-book/Kazumi-s-book/build/android-ui/fixtures/clip.mp4
cp "$prior_clip" build/media-diagnostic/fixtures/clip.mp4
sha256sum "$prior_clip" build/media-diagnostic/fixtures/clip.mp4 diagnostic-apk/app-x86_64-release.apk > build/media-diagnostic/input.sha256
python3 - <<'PY'
from pathlib import Path
import hashlib
prior = Path('diagnostic-prior/work/Kazumi-s-book/Kazumi-s-book/build/android-ui/upgrade-packages.sha256')
expected = next(line.split()[0] for line in prior.read_text().splitlines() if line.endswith('android-ui-apk/app-x86_64-release.apk'))
assert hashlib.sha256(Path('diagnostic-apk/app-x86_64-release.apk').read_bytes()).hexdigest() == expected
PY
test "$(adb shell getprop ro.build.fingerprint | tr -d '\r')" = 'google/sdk_gphone64_x86_64/emu64xa:14/UE1A.230829.050/12077443:userdebug/dev-keys'
emulator -version > build/media-diagnostic/emulator-version.txt 2>&1
cp "$ANDROID_HOME/system-images/android-34/google_apis/x86_64/package.xml" build/media-diagnostic/system-image-package.xml
adb shell wm size 480x900
adb shell wm density 160
adb shell pm list features > build/media-diagnostic/device-features.txt
adb shell getprop > build/media-diagnostic/device-properties.txt
adb shell dumpsys SurfaceFlinger > build/media-diagnostic/surface-flinger.txt
python3 tool/android_ui/fixture_server.py --output build/media-diagnostic/fixtures > build/media-diagnostic/fixture-server.log 2>&1 &
fixture_pid=$!
trap 'capture; kill "$fixture_pid"' EXIT
curl --fail --silent --show-error --retry 8 --retry-connrefused --retry-delay 1 http://127.0.0.1:8765/fixture-state > build/media-diagnostic/fixture-ready.json
book_media_ready=false
for book_media_attempt in $(seq 1 30); do
  if adb shell content query --uri content://media/external_primary/file --projection _id --where _id=-1 > build/media-diagnostic/media-ready.log 2>&1 &&
      grep -q '^No result found\.' build/media-diagnostic/media-ready.log; then
    book_media_ready=true
    break
  fi
  sleep 1
done
test "$book_media_ready" = true
adb push build/media-diagnostic/fixtures/video-rule.json /sdcard/Download/book-test-video.json > build/media-diagnostic/push-fixture.log
adb install diagnostic-apk/app-x86_64-release.apk > build/media-diagnostic/install.log
maestro test .maestro/media-diagnostic-prepare.yaml > build/media-diagnostic/prepare.log 2>&1
set +e
maestro test .maestro/media-diagnostic-play.yaml > build/media-diagnostic/auto.log 2>&1
auto_result=$?
set -e
test "$auto_result" = 1
adb logcat -d > build/media-diagnostic/auto-logcat.txt
adb exec-out screencap -p > build/media-diagnostic/auto-screen.png
capture_zero() {
  local phase="$1"
  adb shell uiautomator dump /sdcard/renderer-auto.xml > "build/media-diagnostic/${phase}-dump.log"
  adb pull /sdcard/renderer-auto.xml "build/media-diagnostic/${phase}.xml" > "build/media-diagnostic/${phase}-pull.log"
  python3 - "$phase" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
root = ET.fromstring(Path(f'build/media-diagnostic/{sys.argv[1]}.xml').read_text())
labels = [node.attrib.get('content-desc', '') for node in root.iter('node')]
assert any('00:00 / 00:20' in label for label in labels), labels
assert any('Episode 1，正在播放' in label for label in labels), labels
print(f'{sys.argv[1]} RED: actual player remains at zero with the unchanged signed APK and clip.')
PY
}
capture_zero auto
maestro test .maestro/media-diagnostic-gpu.yaml > build/media-diagnostic/gpu-setting.log 2>&1
maestro test .maestro/media-diagnostic-play.yaml > build/media-diagnostic/gpu.log 2>&1
for sample in 1 2; do
  adb shell uiautomator dump /sdcard/renderer-gpu.xml > "build/media-diagnostic/gpu-${sample}-dump.log"
  adb pull /sdcard/renderer-gpu.xml "build/media-diagnostic/gpu-${sample}.xml" > "build/media-diagnostic/gpu-${sample}-pull.log"
  adb exec-out screencap -p > "build/media-diagnostic/gpu-${sample}-screen.png"
  sleep 2
done
python3 - <<'PY'
from pathlib import Path
import re
import xml.etree.ElementTree as ET
positions = []
for sample in (1, 2):
    root = ET.fromstring(Path(f'build/media-diagnostic/gpu-{sample}.xml').read_text())
    matches = [re.search(r'00:(\d{2}) / 00:20', node.attrib.get('content-desc', '')) for node in root.iter('node')]
    positions.append(next(int(match[1]) for match in matches if match))
assert 0 < positions[0] < positions[1] <= 20, positions
print(f'GPU GREEN: actual native playback positions increased: {positions}')
PY
adb logcat -d > build/media-diagnostic/gpu-logcat.txt
maestro test .maestro/media-diagnostic-auto.yaml > build/media-diagnostic/auto-restored-setting.log 2>&1
maestro test -e REQUIRE_PROGRESS=false .maestro/media-diagnostic-play.yaml > build/media-diagnostic/auto-restored.log 2>&1
for sample in 1 2; do
  sleep 5
  adb shell uiautomator dump /sdcard/renderer-auto-restored.xml > "build/media-diagnostic/auto-restored-${sample}-dump.log"
  adb pull /sdcard/renderer-auto-restored.xml "build/media-diagnostic/auto-restored-${sample}.xml" > "build/media-diagnostic/auto-restored-${sample}-pull.log"
  adb exec-out screencap -p > "build/media-diagnostic/auto-restored-${sample}-screen.png"
done
python3 - <<'PY'
from pathlib import Path
import re
import xml.etree.ElementTree as ET
positions = []
for sample in (1, 2):
    root = ET.fromstring(Path(f'build/media-diagnostic/auto-restored-{sample}.xml').read_text())
    matches = [re.search(r'00:(\d{2}) / 00:20', node.attrib.get('content-desc', '')) for node in root.iter('node')]
    positions.append(next(int(match[1]) for match in matches if match))
assert 0 <= positions[0] == positions[1] < 20, positions
print(f'AUTO RESTORED RED: actual native playback stalled again: {positions}')
PY
echo 'A-B-A confirmed: only the renderer changed; review both captured gpu video frames.'
