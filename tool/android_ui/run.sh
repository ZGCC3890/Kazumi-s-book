#!/usr/bin/env bash
set -euo pipefail
mkdir -p build/android-ui
capture() {
  adb logcat -d > build/android-ui/logcat.txt
  adb exec-out screencap -p > build/android-ui/final-screen.png
}
trap capture EXIT
python3 tool/android_ui/fixture_server.py --output build/android-ui/fixtures > build/android-ui/fixture-server.log 2>&1 &
adb install -r android-ui-apk/app-x86_64-release.apk > build/android-ui/install.log
adb logcat -c
if [ "$1" = tablet ]; then
  adb shell wm size 800x1280
  adb shell wm density 160
  adb shell settings put system accelerometer_rotation 0
  adb shell settings put system user_rotation 1
else
  adb shell wm size 480x900
  adb shell wm density 160
  adb shell settings put system accelerometer_rotation 0
  adb shell settings put system user_rotation 0
fi
maestro test .maestro > build/android-ui/maestro.log 2>&1
