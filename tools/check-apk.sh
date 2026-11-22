#!/bin/sh
# Checks that R8 kept in a release APK what Android and libraries create by reflection: without
# it the app crashes at start, which no test on the computer sees.
#   sh tools/check-apk.sh app-release.apk
set -eu
apk=$1
tools=$ANDROID_HOME/build-tools/$(ls "$ANDROID_HOME/build-tools" | sort -V | tail -1)
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
unzip -q "$apk" 'classes*.dex' -d "$dir"
"$tools/dexdump" "$dir"/classes*.dex 2>/dev/null |
  awk '/Class descriptor/{c=$4} /name *: .<init>./{getline; print c, $3}' > "$dir/ctors"
st=0
for want in \
  "'Landroidx/work/impl/WorkDatabase_Impl;' '()V'" \
  "'Landroidx/work/WorkManagerInitializer;' '()V'" \
  "'Lcom/rustcloud/photos/BackupWorker;' '(Landroid/content/Context;Landroidx/work/WorkerParameters;)V'" \
  "'Lcom/rustcloud/photos/MainActivity;' '()V'"
do
  if grep -qF "$want" "$dir/ctors"; then
    echo "ok: $want"
  else
    echo "::error title=R8::constructor removed: $want (see android/app/proguard-rules.pro)"
    st=1
  fi
done
exit $st
