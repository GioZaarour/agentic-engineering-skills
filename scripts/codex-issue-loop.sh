#!/usr/bin/env bash
# Run the same issue workflow with Codex CLI, including all flags and resume stages.
set -uo pipefail
LOOP_CLI=codex
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./claude-issue-loop.sh
source "$SCRIPT_DIR/claude-issue-loop.sh"
