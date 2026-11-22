#!/bin/sh
# Runs ci.sh in the Flutter image on buildserver, from /root/build/rc-photo-client.
# Pub and Gradle caches and the NDK and CMake (Gradle installs them on the first build) live in
# $cache so builds don't download everything again. The Android SDK is $cache/sdk: the image's
# components linked in, what Gradle adds kept there (one mount, so sdkmanager can move its
# downloads into place). build/ is removed afterwards: the disk of
# buildserver is small, and the APK is in out/.
#   sh tools/docker-ci.sh [test]        or any command: sh tools/docker-ci.sh -- dart format lib test
set -eu
cd "$(dirname "$0")/.."
image=ghcr.io/cirruslabs/flutter:3.44.0
cache=/root/build/rc-photo-client-cache
mkdir -p "$cache/pub" "$cache/gradle" "$cache/sdk"
if [ "${1:-}" = -- ]; then shift; cmd="$*"; else cmd="sh ci.sh ${1:-}"; fi
sdk='for d in build-tools cmdline-tools emulator licenses platforms platform-tools; do
  [ -e /sdk/$d ] || ln -s /opt/android-sdk-linux/$d /sdk/$d; done
  [ -e /sdk/.knownPackages ] || cp /opt/android-sdk-linux/.knownPackages /sdk/'
st=0
docker run --rm -v "$PWD":/w -w /w \
  -v "$cache/pub":/root/.pub-cache -v "$cache/gradle":/root/.gradle -v "$cache/sdk":/sdk \
  -e ANDROID_HOME=/sdk -e ANDROID_SDK_ROOT=/sdk \
  "$image" sh -c "$sdk; git config --global --add safe.directory '*' 2>/dev/null; $cmd" || st=$?
rm -rf build android/app/.cxx
exit $st
