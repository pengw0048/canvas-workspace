#!/bin/zsh
# Coordinates real-input test runs with the person at the Mac.
#   input-window.sh begin <drive>  — notify, then wait until the user has been idle for 10 s
#   input-window.sh end            — notify that the Mac is free again
case $1 in
begin)
  osascript -e 'display notification "Real mouse/keyboard tests start once you stop using the Mac for 10 seconds. Please do not touch it until the next notification." with title "Canvas Workspace tests" sound name "Glass"'
  for i in {1..120}; do
    idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
    (( idle >= 10 )) && exit 0
    sleep 2
  done
  echo "user still active after 4 minutes; not starting" >&2; exit 1 ;;
end)
  osascript -e 'display notification "Tests finished. You can use the Mac again." with title "Canvas Workspace tests" sound name "Glass"' ;;
esac
