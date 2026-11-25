#!/bin/sh
# Makes the Android launcher icons from assets/logo.svg (needs rsvg-convert, librsvg):
#   sh tools/icons.sh
# - adaptive icon (Android 8+): the logo in the middle 66 of 108 dp, the part no launcher mask
#   cuts, on the background colour in values/ic_launcher_background.xml;
# - ic_launcher.png: the logo alone, for launchers without adaptive icons.
set -eu
cd "$(dirname "$0")/.."
res=android/app/src/main/res
fg=$(mktemp)
trap 'rm -f "$fg"' EXIT
# 512 units of the logo = 66 dp of 108: a margin of (108/66 - 1) / 2 × 512 ≈ 163 units.
sed 's#viewBox="0 0 512 512" width="512" height="512"#viewBox="-163 -163 838 838" width="838" height="838"#' \
  assets/logo.svg > "$fg"
for d in mdpi:1 hdpi:1.5 xhdpi:2 xxhdpi:3 xxxhdpi:4; do
  name=${d%%:*} k=${d#*:}
  size=$(awk "BEGIN{print int(48*$k)}") big=$(awk "BEGIN{print int(108*$k)}")
  mkdir -p "$res/mipmap-$name"
  rsvg-convert -w "$size" -h "$size" assets/logo.svg -o "$res/mipmap-$name/ic_launcher.png"
  rsvg-convert -w "$big" -h "$big" "$fg" -o "$res/mipmap-$name/ic_launcher_foreground.png"
done
