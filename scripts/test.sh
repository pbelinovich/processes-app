#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Sources/ProcessesMenu/ProcessService.swift Tests/ProcessServiceChecks.swift -o "$TEST_DIR/process-checks"
"$TEST_DIR/process-checks"
swiftc -D PROCESS_UI_CHECKS Sources/ProcessesMenu/ProcessService.swift Sources/ProcessesMenu/App.swift Tests/RefreshChecks.swift -o "$TEST_DIR/refresh-checks"
"$TEST_DIR/refresh-checks"
