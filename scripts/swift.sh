#!/bin/sh
# Runs `swift <args>` in BaselineKit with Xcode's toolchain, also while `xcode-select` still
# points at the Command Line Tools: the package uses macros, which only Xcode ships.
#   scripts/swift.sh test
cd "$(dirname "$0")/../BaselineKit"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" exec swift "$@"
