#!/bin/sh
# Runs ci.sh on buildserver with its own SDKs: Flutter /root/flutter-sdk/flutter (3.44.0),
# Android SDK /root/android-sdk, JDK 21 from apt. build/ is removed afterwards: the disk is
# small, and the APK is in out/.
#   sh tools/buildserver-ci.sh [test]        or any command: sh tools/buildserver-ci.sh -- dart format lib test
set -eu
cd "$(dirname "$0")/.."
export ANDROID_HOME=/root/android-sdk ANDROID_SDK_ROOT=/root/android-sdk
export PATH="/root/flutter-sdk/flutter/bin:$ANDROID_HOME/platform-tools:$PATH"
export FLUTTER_SUPPRESS_ANALYTICS=true
# Flutter unpacks its downloads with tar; as root tar keeps the archives' owners, which this
# container (unprivileged LXC) cannot map.
export TAR_OPTIONS=--no-same-owner
if [ "${1:-}" = -- ]; then shift; cmd="$*"; else cmd="sh ci.sh ${1:-}"; fi
st=0
sh -c "$cmd" || st=$?
rm -rf build android/app/.cxx
exit $st
