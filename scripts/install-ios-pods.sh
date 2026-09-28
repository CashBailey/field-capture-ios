#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_RUBY="${LOCAL_RUBY:-}"

if command -v pod >/dev/null 2>&1; then
  POD_BIN="$(command -v pod)"
elif [ -x "$LOCAL_RUBY/pod" ]; then
  POD_BIN="$LOCAL_RUBY/pod"
else
  echo "CocoaPods was not found. Install CocoaPods or restore the local Ruby toolchain at:"
  echo "$LOCAL_RUBY"
  exit 1
fi

cd "$REPO_ROOT/apps/mobile/ios"
"$POD_BIN" install
