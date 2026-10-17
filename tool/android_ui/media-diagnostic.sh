#!/usr/bin/env bash
set -euo pipefail
mkdir -p build/media-diagnostic/fixtures
capture() {
  adb logcat -d > build/media-diagnostic/final-logcat.txt
  adb shell dumpsys media.codec > build/media-diagnostic/media-codec.txt
  adb shell dumpsys media.metrics > build/media-diagnostic/media-metrics.txt
  adb exec-out screencap -p > build/media-diagnostic/final-screen.png
  for phase in flow; do
    if [ -f "build/media-diagnostic/${phase}.log" ]; then
      printf '\n%s\n' "Diagnostic ${phase}:"
      tail -n 12 "build/media-diagnostic/${phase}.log"
    fi
  done
}
trap capture EXIT
prior_clip=diagnostic-prior/work/Kazumi-s-book/Kazumi-s-book/build/android-ui/fixtures/clip.mp4
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=24 -f lavfi -i sine=frequency=440 -t 120 -c:v libx264 -threads 1 -pix_fmt yuv420p -c:a aac -movflags +faststart build/media-diagnostic/fixtures/clip.mp4
sha256sum "$prior_clip" build/media-diagnostic/fixtures/clip.mp4 diagnostic-apk/app-x86_64-release.apk > build/media-diagnostic/input.sha256
python3 - <<'PY'
from pathlib import Path
import hashlib
prior = Path('diagnostic-prior/work/Kazumi-s-book/Kazumi-s-book/build/android-ui/upgrade-packages.sha256')
expected = next(line.split()[0] for line in prior.read_text().splitlines() if line.endswith('android-ui-apk/app-x86_64-release.apk'))
assert hashlib.sha256(Path('diagnostic-apk/app-x86_64-release.apk').read_bytes()).hexdigest() == expected
PY
test "$(adb shell getprop ro.build.fingerprint | tr -d '\r')" = 'google/sdk_gphone64_x86_64/emu64xa:14/UE1A.230829.050/12077443:userdebug/dev-keys'
cp "$ANDROID_HOME/emulator/source.properties" build/media-diagnostic/emulator-version.txt
cp "$ANDROID_HOME/system-images/android-34/google_apis/x86_64/package.xml" build/media-diagnostic/system-image-package.xml
adb shell wm size 480x900
adb shell wm density 160
adb shell pm list features > build/media-diagnostic/device-features.txt
adb shell getprop > build/media-diagnostic/device-properties.txt
test "$(adb shell getprop ro.boot.qemu.hwcodec.avcdec | tr -d '\r')" != '2'
adb shell dumpsys SurfaceFlinger > build/media-diagnostic/surface-flinger.txt
python3 tool/android_ui/fixture_server.py --output build/media-diagnostic/fixtures > build/media-diagnostic/fixture-server.log 2>&1 &
fixture_pid=$!
trap 'capture; kill "$fixture_pid"' EXIT
curl --fail --silent --show-error --retry 8 --retry-connrefused --retry-delay 1 http://127.0.0.1:8765/fixture-state > build/media-diagnostic/fixture-ready.json
python3 - <<'PY'
import json
from pathlib import Path
stamp = 1792240000000
version = f'{stamp:016d}|fixture-media:1'
key = 'Fixture Video400602::online'
history = {
    'bangumiItem': {'id': 400602, 'type': 2, 'name': '葬送的芙莉莲',
                    'nameCn': '葬送的芙莉莲',
                    'images': {'large': 'http://10.0.2.2:8765/cover.png'}},
    'lastWatchEpisode': 1, 'adapterName': 'Fixture Video',
    'lastWatchTime': stamp, 'lastSrc': '1',
    'lastWatchEpisodeName': 'Episode 1', 'entryKind': 'online',
    'episodePageUrl': 'http://10.0.2.2:8765/clip.mp4',
    'progresses': {'1': {'episode': 1, 'road': 0, 'progressMs': 0, 'updatedAtMs': stamp}},
}
Path('build/media-diagnostic/history-snapshot.json').write_text(json.dumps({
    'schemaVersion': 1, 'generatedAt': stamp, 'histories': [history],
    'itemVersions': {key: version}, 'progressVersions': {key: {'1': version}},
    'deletedVersions': {},
}), encoding='utf-8')
PY
for collection in kazumiSync kazumiSync/history kazumiSync/history/changes; do
  curl --fail --silent --show-error -X MKCOL "http://127.0.0.1:8765/dav/${collection}"
done
curl --fail --silent --show-error --upload-file build/media-diagnostic/history-snapshot.json http://127.0.0.1:8765/dav/kazumiSync/history/snapshot.json
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
maestro test .maestro/media-diagnostic.yaml > build/media-diagnostic/flow.log 2>&1
echo 'Both episode timing records completed with default player settings; review video frames.'
