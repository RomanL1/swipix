#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 DEDICATED_QA_SIMULATOR_UUID" >&2
    exit 1
fi
simulator_id="$1"
cd "$(dirname "$0")/.."
xcrun simctl bootstatus "$simulator_id" -b
xcodebuild -project Swipix.xcodeproj -scheme Swipix \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -derivedDataPath /tmp/SwipixQA CODE_SIGNING_ALLOWED=NO build
xcrun simctl install "$simulator_id" /tmp/SwipixQA/Build/Products/Debug-iphonesimulator/Swipix.app
xcrun simctl privacy "$simulator_id" grant photos com.swipix.app
xcrun simctl addmedia "$simulator_id" Tests/Fixtures/landscape-0.jpg Tests/Fixtures/landscape-1.jpg Tests/Fixtures/landscape-2.jpg Tests/Fixtures/landscape-3.jpg
