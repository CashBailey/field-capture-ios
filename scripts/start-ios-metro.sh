#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$REPO_ROOT"
NODE_OPTIONS=--dns-result-order=ipv4first npm --workspace @fieldcapture/mobile run start -- --host localhost
