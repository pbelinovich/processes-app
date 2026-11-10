#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
CORE=(Sources/ProcessesMenu/Model.swift Sources/ProcessesMenu/ProcessService.swift Sources/ProcessesMenu/Attribution.swift)
UI=(${(f)"$(ls Sources/ProcessesMenu/*.swift | grep -v -e '/Model.swift$' -e '/ProcessService.swift$' -e '/Attribution.swift$')"})
# Data-layer checks: every Tests/*Checks.swift except UI ones (UI checks are named *UIChecks.swift or RefreshChecks.swift).
for check in Tests/*Checks.swift(N); do
  case "$check" in *UIChecks.swift|*RefreshChecks.swift) continue;; esac
  name=${check:t:r}
  swiftc $CORE "$check" -o "$TEST_DIR/$name"
  "$TEST_DIR/$name"
done
for check in Tests/RefreshChecks.swift(N) Tests/*UIChecks.swift(N); do
  name=${check:t:r}
  swiftc -D PROCESS_UI_CHECKS $CORE $UI "$check" -o "$TEST_DIR/$name"
  "$TEST_DIR/$name"
done
