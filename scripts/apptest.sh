#!/bin/sh
# Runs the app's own tests in a simulator: the app-state tests (AppTests) and the UI tests.
#   scripts/apptest.sh                            all of them
#   scripts/apptest.sh testAppleHealthRoundTrip   one UI test
# One simulator, no clones: the Apple Health test writes to that simulator's Health store.
# The full log, with every step and its time, is in .build/xcode/apptest.log, and the
# screenshots the UI tests take are in .build/xcode/screenshots.
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
result=".build/xcode/apptest.xcresult"
rm -rf "$result"
xcodebuild test -project Baseline.xcodeproj -scheme Baseline -derivedDataPath .build/xcode \
    -destination "platform=iOS Simulator,name=${SIMULATOR:-iPhone 18 Pro}" \
    -parallel-testing-enabled NO -resultBundlePath "$result" \
    -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180 \
    ${1:+-only-testing:BaselineUITests/BaselineUITests/$1} 2>&1 | tee .build/xcode/apptest.log | grep -E "^Test Case.*(passed|failed|exceeded)|^(✔|✘) Test |error:|\*\* TEST"

shots=".build/xcode/screenshots"
rm -rf "$shots"
xcrun xcresulttool export attachments --path "$result" --output-path "$shots" > /dev/null
python3 - "$shots" <<'PY'
import json, os, re, sys
folder = sys.argv[1]
for test in json.load(open(f"{folder}/manifest.json")):
    for attachment in test["attachments"]:
        # The tests name their screenshots like "metric-6-months"; a failure attaches other things.
        name = attachment["suggestedHumanReadableName"].split("_0_")[0]
        exported = f"{folder}/{attachment['exportedFileName']}"
        os.rename(exported, f"{folder}/{name}.png") if re.fullmatch("[a-z0-9-]+", name) else os.remove(exported)
os.remove(f"{folder}/manifest.json")
PY
