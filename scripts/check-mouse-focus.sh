#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
for scrolloff in 0 30; do
  PI_AGENT_TEST_SCROLLOFF=$scrolloff nvim --headless -u NONE -l "$root/scripts/check-mouse-focus.lua"
done
