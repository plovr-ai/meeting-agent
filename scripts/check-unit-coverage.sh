#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"

cd "$ROOT_DIR"
SCRATCH_PATH="${MEETING_AGENT_COVERAGE_SCRATCH_PATH:-${TMPDIR:-/tmp}/meeting-agent-swiftpm-coverage}"
MODULE_CACHE_PATH="$SCRATCH_PATH/clang-module-cache"
mkdir -p "$MODULE_CACHE_PATH"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_PATH"

swift test --scratch-path "$SCRATCH_PATH" --enable-code-coverage
COVERAGE_JSON="$(swift test --scratch-path "$SCRATCH_PATH" --enable-code-coverage --show-codecov-path)"
scripts/check-unit-coverage.swift "$COVERAGE_JSON"
