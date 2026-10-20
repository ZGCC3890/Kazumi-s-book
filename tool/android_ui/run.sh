#!/usr/bin/env bash
set -euo pipefail
validation_scope="$2"
case "$validation_scope" in
  full) main_flow=.maestro/main.yaml ;;
  owned) main_flow=.maestro/owned-main.yaml ;;
  *) echo 'Expected validation scope: full or owned' >&2; exit 2 ;;
esac
suite="$3"
case "$suite" in
  full|upgrade|reading) ;;
  *) echo 'Expected suite: full, upgrade or reading' >&2; exit 2 ;;
esac
mkdir -p build/android-ui
fixture_pid=''
capture() {
  local result=$?
  if [ -n "$fixture_pid" ] && kill -0 "$fixture_pid" 2>/dev/null; then
    kill "$fixture_pid"
    wait "$fixture_pid" || test "$?" -eq 143
  fi
  adb logcat -d > build/android-ui/logcat.txt
  adb exec-out screencap -p > build/android-ui/final-screen.png
  if [ -f build/android-ui/maestro.log ]; then
    tail -n 60 build/android-ui/maestro.log
  fi
  return "$result"
}
trap capture EXIT
run_stage() {
  python3 tool/android_ui/run_stage.py "$1" build/android-ui/maestro.log "${@:2}"
}
start_fixture() {
  rm -f build/android-ui/fixture.ready
  python3 tool/android_ui/fixture_server.py --output build/android-ui/fixtures --ready-file build/android-ui/fixture.ready >> build/android-ui/fixture-server.log 2>&1 &
  fixture_pid=$!
  for attempt in $(seq 1 40); do
    if [ -f build/android-ui/fixture.ready ]; then return; fi
    if ! kill -0 "$fixture_pid" 2>/dev/null; then
      cat build/android-ui/fixture-server.log
      return 1
    fi
    sleep 0.2
  done
  echo 'Fixture server did not become ready within eight seconds.' >&2
  return 1
}
capture_host() {
  local stage="$1"
  adb shell date > "build/android-ui/host-${stage}-time.txt"
  adb shell dumpsys activity lastanr > "build/android-ui/host-${stage}-lastanr.txt"
  adb shell dumpsys window | awk '/mCurrentFocus=|mFocusedApp=|mTopFocusedDisplayId=|Application Not Responding/' > "build/android-ui/host-${stage}-window.txt"
}
test -s build/android-ui/fixtures/clip.mp4
start_fixture
curl --fail --silent --show-error http://127.0.0.1:8765/fixture-state > build/android-ui/fixture-ready.json
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
adb logcat -d > build/android-ui/host-before-wm-boot-logcat.txt
# The released baseline hides wide navigation semantics. Seed its data in a
# fixed compact viewport; only the new package is tested at the target size.
if [ "$suite" != reading ]; then
capture_host legacy-before-wm
adb shell wm size 480x900
capture_host legacy-after-size
adb shell wm density 160
capture_host legacy-after-density
sha256sum android-upgrade-apk/app-x86_64-release.apk android-ui-apk/app-x86_64-release.apk > build/android-ui/upgrade-packages.sha256
adb install -r android-upgrade-apk/app-x86_64-release.apk > build/android-ui/install-baseline.log
capture_host legacy-before-maestro
run_stage upgrade-seed maestro test -e LAYOUT="$1" .maestro/00-upgrade-seed.yaml
curl --fail --silent http://127.0.0.1:8765/fixture-state > build/android-ui/upgrade-legacy-state.json
python3 tool/android_ui/verify_upgrade.py legacy build/android-ui/upgrade-legacy-state.json
adb shell am force-stop com.zgcc.kazumisbook
fi
capture_host current-before-wm
if [ "$1" = tablet ]; then
  adb shell wm size 800x1280
else
  adb shell wm size 480x900
fi
capture_host current-after-size
adb shell wm density 160
capture_host current-after-density
adb install -r android-ui-apk/app-x86_64-release.apk > build/android-ui/install-upgrade.log
capture_host current-before-maestro
if [ "$suite" != reading ]; then
run_stage upgrade-check maestro test -e LAYOUT="$1" .maestro/00-upgrade-check.yaml
curl --fail --silent http://127.0.0.1:8765/fixture-state > build/android-ui/upgrade-current-state.json
python3 tool/android_ui/verify_upgrade.py upgraded build/android-ui/upgrade-current-state.json
# Only the in-memory fixture is reset. The first main flow separately tests a
# clean application profile after the preserved-data upgrade above.
adb shell am force-stop com.zgcc.kazumisbook
kill "$fixture_pid"
wait "$fixture_pid" || test "$?" -eq 143
start_fixture
curl --fail --silent --show-error http://127.0.0.1:8765/fixture-state > build/android-ui/fixture-clean-ready.json
fi
if [ "$suite" != upgrade ]; then
run_stage reading-playback-sync maestro test -e LAYOUT="$1" "$main_flow"
curl --fail --silent http://127.0.0.1:8765/fixture-state > build/android-ui/webdav-state.json
python3 tool/android_ui/verify_sync.py build/android-ui/webdav-state.json "$validation_scope"
python3 tool/android_ui/exercise_conflict.py inject
run_stage conflict-cancel maestro test -e LAYOUT="$1" .maestro/06-conflict-cancel.yaml
python3 tool/android_ui/exercise_conflict.py cancelled
run_stage conflict-resolve maestro test -e LAYOUT="$1" .maestro/07-conflict-resolve.yaml
python3 tool/android_ui/exercise_conflict.py resolved
curl --fail --silent http://127.0.0.1:8765/fixture-state > build/android-ui/webdav-final-state.json
fi
if [ "$suite" != reading ]; then
run_stage accounts maestro test -e LAYOUT="$1" .maestro/08-accounts.yaml
fi
kill "$fixture_pid"
wait "$fixture_pid" || test "$?" -eq 143
