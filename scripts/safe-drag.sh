#!/bin/zsh
# Drags only when the expected app is frontmost: scripts/safe-drag.sh <drive> <expected-app> x1 y1 x2 y2 [holdms]
drive=$1; want=$2; shift 2
front=$($drive front)
[[ "$front" == "$want" ]] || { echo "refusing to drag: frontmost is $front, expected $want"; exit 1 }
$drive drag "$@"
