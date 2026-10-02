#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmpdir=$(mktemp -d)
pid_file=$tmpdir/child.pid
cleanup() {
  if [ -f "$pid_file" ]; then
    child=$(cat "$pid_file")
    group=$(ps -o pgid= -p "$child" 2>/dev/null | tr -d ' ' || true)
    own_group=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ' || true)
    if [ -n "$group" ] && [ "$group" != "$own_group" ] && [ "$group" = "$child" ]; then
      kill -TERM -- "-$group" 2>/dev/null || true
    fi
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT HUP INT TERM

PI_AGENT_TEST_PID_FILE=$pid_file nvim --headless -u NONE \
  --cmd "cd $root" -c "luafile $root/scripts/check-exit-process-group.lua"

child=$(cat "$pid_file")
state=$(ps -o stat= -p "$child" 2>/dev/null | tr -d ' ' || true)
case "$state" in
  ''|Z*) ;;
  *) echo "Pi descendant $child survived ExitPre (state: $state)" >&2; exit 1 ;;
esac
printf '%s\n' 'ExitPre stopped the Pi process group and Neovim quit normally.'
