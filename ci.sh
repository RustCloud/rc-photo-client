#!/bin/sh
# Checks and builds the app: the same steps on buildserver (tools/buildserver-ci.sh) and in CI.
# Needs flutter on PATH (with the Android SDK for the APK). The debug APK goes to out/.
#   sh ci.sh            analyze, format, tests, debug APK
#   sh ci.sh test       without the APK
set -eu
cd "$(dirname "$0")"
flutter --version | head -1
flutter pub get
flutter gen-l10n
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
[ "${1:-}" = test ] && exit 0
flutter build apk --debug
mkdir -p out
cp build/app/outputs/flutter-apk/app-debug.apk out/rc-photo-debug.apk
ls -la out/rc-photo-debug.apk
