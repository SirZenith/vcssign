#!/usr/bin/env sh
# Run the headless specs.  Usage: scripts/run_tests.sh [spec ...]
# Fixtures must exist first: scripts/make_test_repos.sh
set -eu
cd "$(dirname "$0")/.."
exec nvim --headless -u NONE -l test/run.lua "$@"
