#!/usr/bin/env bash
# Installs the APK on the CI emulator, opens the app the way the home-screen
# icon does, and checks it is still running after a while. Saves the device
# log to launch-logcat.txt either way. Exit code 1 = the app didn't stay open.
set -u
apk="$1"
pkg=com.writingrecogniser

result=0
if ! adb install -r "$apk" > install.txt 2>&1; then
  cat install.txt
  echo "Install failed" > launch-result.txt
  adb logcat -d -v time > launch-logcat.txt 2>&1 || true
  exit 1
fi

adb logcat -c || true
adb shell am start -W -a android.intent.action.MAIN \
  -c android.intent.category.LAUNCHER -n "$pkg/.LaunchActivity" || true
# Flutter takes a while to start on the emulator; give it time to crash.
sleep 30

pid=$(adb shell pidof "$pkg" | tr -d '\r')
top=$(adb shell dumpsys activity activities | grep -m1 -E 'topResumedActivity|mResumedActivity' | tr -d '\r')
adb logcat -d -v time > launch-logcat.txt 2>&1 || true

if [ -z "$pid" ]; then
  echo "App is NOT running 30 s after launch" > launch-result.txt
  result=1
elif grep -q -E 'FATAL EXCEPTION|Fatal signal' launch-logcat.txt; then
  echo "App is running but a crash was logged" > launch-result.txt
  result=1
elif grep -q -E 'Error registering plugin|W/ComponentDiscovery' launch-logcat.txt; then
  # The app runs, but a plugin (e.g. ML Kit) failed to load, so one of its
  # features would only fail later, on the tablet.
  echo "App is running but a plugin failed to load" > launch-result.txt
  result=1
else
  echo "App opened and is still running (pid $pid)" > launch-result.txt
fi
echo "Top activity: $top" >> launch-result.txt
cat launch-result.txt
exit $result
