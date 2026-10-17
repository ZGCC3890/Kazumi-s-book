#!/usr/bin/env bash
set -euo pipefail
mkdir -p build/android-ui
capture() {
  adb logcat -d > build/android-ui/logcat.txt
  adb exec-out screencap -p > build/android-ui/final-screen.png
  if [ -f build/android-ui/maestro.log ]; then
    tail -n 60 build/android-ui/maestro.log
  fi
}
trap capture EXIT
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=24 -f lavfi -i sine=frequency=440 -t 20 -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart build/android-ui/fixtures-clip.mp4
mkdir -p build/android-ui/fixtures
mv build/android-ui/fixtures-clip.mp4 build/android-ui/fixtures/clip.mp4
python3 tool/android_ui/fixture_server.py --output build/android-ui/fixtures > build/android-ui/fixture-server.log 2>&1 &
fixture_pid=$!
curl --fail --silent --show-error --retry 8 --retry-connrefused --retry-delay 1 http://127.0.0.1:8765/fixture-state > build/android-ui/fixture-ready.json
# sys.boot_completed precedes MediaProvider attaching external_primary on a
# fresh API 34 boot. Wait for that actual volume before preparing Downloads.
book_media_ready=false
for book_media_attempt in $(seq 1 30); do
  if adb shell content query --uri content://media/external_primary/file --projection _id --where _id=-1 > build/android-ui/media-volume-ready.log 2>&1 &&
      grep -q '^No result found\.' build/android-ui/media-volume-ready.log; then
    book_media_ready=true
    break
  fi
  sleep 1
done
if [ "$book_media_ready" != true ]; then
  cat build/android-ui/media-volume-ready.log
  exit 1
fi
adb push build/android-ui/fixtures/video-rule.json /sdcard/Download/book-test-video.json > build/android-ui/push-fixture.log
adb logcat -c
if [ "$1" = tablet ]; then
  adb shell wm size 800x1280
  adb shell wm density 160
else
  adb shell wm size 480x900
  adb shell wm density 160
fi
sha256sum android-upgrade-apk/app-x86_64-release.apk android-ui-apk/app-x86_64-release.apk > build/android-ui/upgrade-packages.sha256
adb install -r android-upgrade-apk/app-x86_64-release.apk > build/android-ui/install-baseline.log
maestro test -e LAYOUT="$1" .maestro/00-upgrade-seed.yaml > build/android-ui/maestro.log 2>&1
curl --fail --silent http://127.0.0.1:8765/fixture-state > build/android-ui/upgrade-legacy-state.json
python3 tool/android_ui/verify_upgrade.py legacy build/android-ui/upgrade-legacy-state.json
adb install -r android-ui-apk/app-x86_64-release.apk > build/android-ui/install-upgrade.log
maestro test -e LAYOUT="$1" .maestro/00-upgrade-check.yaml >> build/android-ui/maestro.log 2>&1
curl --fail --silent http://127.0.0.1:8765/fixture-state > build/android-ui/upgrade-current-state.json
python3 tool/android_ui/verify_upgrade.py upgraded build/android-ui/upgrade-current-state.json
# Only the in-memory fixture is reset. The first main flow separately tests a
# clean application profile after the preserved-data upgrade above.
adb shell am force-stop com.zgcc.kazumisbook
kill "$fixture_pid"
wait "$fixture_pid" || test "$?" -eq 143
python3 tool/android_ui/fixture_server.py --output build/android-ui/fixtures >> build/android-ui/fixture-server.log 2>&1 &
curl --fail --silent --show-error --retry 8 --retry-connrefused --retry-delay 1 http://127.0.0.1:8765/fixture-state > build/android-ui/fixture-clean-ready.json
maestro test -e LAYOUT="$1" .maestro/main.yaml >> build/android-ui/maestro.log 2>&1
curl --fail --silent http://127.0.0.1:8765/fixture-state > build/android-ui/webdav-state.json
python3 tool/android_ui/verify_sync.py build/android-ui/webdav-state.json
python3 tool/android_ui/exercise_conflict.py inject
maestro test -e LAYOUT="$1" .maestro/06-conflict-cancel.yaml >> build/android-ui/maestro.log 2>&1
python3 tool/android_ui/exercise_conflict.py cancelled
maestro test -e LAYOUT="$1" .maestro/07-conflict-resolve.yaml >> build/android-ui/maestro.log 2>&1
python3 tool/android_ui/exercise_conflict.py resolved
curl --fail --silent http://127.0.0.1:8765/fixture-state > build/android-ui/webdav-final-state.json
