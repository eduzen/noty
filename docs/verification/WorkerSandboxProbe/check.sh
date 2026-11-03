#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 /absolute/path/to/NotyTranscriptionWorker 'Signing Identity'" >&2
    exit 64
fi

probe_sources=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository=$(CDPATH= cd -- "$probe_sources/../../.." && pwd)
helper=$1
identity=$2
mkdir -p "$repository/build"
workspace=$(mktemp -d "$repository/build/worker-sandbox-probe.XXXXXX")
trap 'rm -rf "$workspace"' EXIT HUP INT TERM
probe="$workspace/NotyWorkerProbe.app"
mkdir -p "$probe/Contents/MacOS"
cp "$probe_sources/Info.plist" "$probe/Contents/Info.plist"
ditto "$helper" "$probe/Contents/MacOS/NotyTranscriptionWorker"

# Validate the built helper's signature; do not replace its production entitlements.
codesign --verify --strict "$probe/Contents/MacOS/NotyTranscriptionWorker"
codesign -d --entitlements - "$probe/Contents/MacOS/NotyTranscriptionWorker"
xcrun swiftc -swift-version 6 -module-cache-path "$workspace/module-cache" \
    "$repository/TranscriptionShared/TranscriptionTypes.swift" "$probe_sources/ProbeParent.swift" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
    -Xlinker "$probe/Contents/Info.plist" -o "$probe/Contents/MacOS/NotyWorkerProbe"
codesign --force --options runtime --sign "$identity" \
    --entitlements "$probe_sources/ProbeParent.entitlements" "$probe"
"$probe/Contents/MacOS/NotyWorkerProbe"
