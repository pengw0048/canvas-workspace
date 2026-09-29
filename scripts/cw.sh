#!/bin/zsh
# Send one automation command to a running host: scripts/cw.sh <socket-path> <command...>
print -r -- "${@:2}" | nc -U -w 10 "$1" | head -1
