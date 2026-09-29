#!/bin/zsh
# Coordinates real-input test runs with the person at the Mac.
#   input-window.sh begin — notify, show a persistent banner, then wait until the user is idle for 10 s
#   input-window.sh end   — remove the banner and notify that the Mac is free again
dir=${TMPDIR:-/tmp}
bin=$dir/cw-input-banner
pidfile=$dir/cw-input-banner.pid
case $1 in
begin)
  [[ $bin -nt ${0:h}/input-banner.swift ]] || swiftc -O ${0:h}/input-banner.swift -o $bin 2>/dev/null
  [[ -f $pidfile ]] && kill $(cat $pidfile) 2>/dev/null
  $bin >/dev/null 2>&1 &
  echo $! > $pidfile
  osascript -e 'display notification "Real mouse/keyboard tests start once you stop using the Mac for 10 seconds. A banner stays at the top of the screen until they finish." with title "Canvas Workspace tests" sound name "Glass"'
  for i in {1..120}; do
    idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
    (( idle >= 10 )) && exit 0
    sleep 2
  done
  echo "user still active after 4 minutes; not starting" >&2
  kill $(cat $pidfile) 2>/dev/null; rm -f $pidfile; exit 1 ;;
end)
  [[ -f $pidfile ]] && kill $(cat $pidfile) 2>/dev/null; rm -f $pidfile
  osascript -e 'display notification "Tests finished. You can use the Mac again." with title "Canvas Workspace tests" sound name "Glass"' ;;
esac
