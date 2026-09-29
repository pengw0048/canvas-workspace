#!/bin/zsh
# Clicks only when the expected app is frontmost: scripts/safe-click.sh <drive> <expected-app> <x> <y> [double]
drive=$1; want=$2; shift 2
front=$($drive front)
[[ "$front" == "$want" ]] || { echo "refusing to click: frontmost is $front, expected $want"; exit 1 }
$drive click "$@"
