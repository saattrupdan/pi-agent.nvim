#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
nvim --headless -u NONE -l "$root/scripts/check-iterm-status.lua"
