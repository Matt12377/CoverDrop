#!/bin/zsh

set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
DERIVED_DATA="${TMPDIR:-/tmp/}CoverDropVerification"

cd "$PROJECT_ROOT"

xcodebuild \
  -project CoverDrop.xcodeproj \
  -scheme CoverDrop \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  clean test
