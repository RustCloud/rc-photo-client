#!/bin/sh
# Phase 0 on buildserver: a fresh RustCloud with the rc-photo plugin on 127.0.0.1:18095,
# then tools/api_check.py against it; the container is removed afterwards.
#
#   sh tools/api-check.sh [server image] [plugin zip] [photo.jpg] [video.mp4]
set -u
here=$(cd "$(dirname "$0")" && pwd)
image=${1:-ghcr.io/rustcloud/server:latest}
zip=${2:-/root/build/rc-image-ci/dist/rc-photo.zip}
photo=${3:-/root/build/media-samples/photo.jpg}
video=${4:-/root/build/media-samples/video.mp4}
name=rc-photo-client-check
data=$(mktemp -d /tmp/rc-photo-client-check.XXXX)
chown 10001 "$data"
docker rm -f $name >/dev/null 2>&1
docker run -d --name $name -p 127.0.0.1:18095:8080 -v "$data":/data "$image" >/dev/null
for i in $(seq 90); do curl -sf http://127.0.0.1:18095/health >/dev/null && break; sleep 1; done
python3 "$here/api_check.py" http://127.0.0.1:18095 "$zip" "$photo" "$video"
st=$?
docker rm -f $name >/dev/null 2>&1
rm -rf "$data"
exit $st
