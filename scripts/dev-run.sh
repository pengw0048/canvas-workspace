#!/bin/zsh
# Launch a windowed host with automation for development: scripts/dev-run.sh <profile> <data-dir> [extra args]
profile=$1; dir=$2; shift 2
mkdir -p "$dir"
CANVAS_DATA_DIR="$dir" "$(dirname $0)/../.build/debug/CanvasWorkspace" --windowed --automation --profile "$profile" "$@" > "$dir/$profile.log" 2>&1 &
for i in {1..40}; do
  sock=$(grep -o "Automation socket: .*" "$dir/$profile.log" 2>/dev/null | sed 's/Automation socket: //')
  [[ -n "$sock" && -S "$sock" ]] && { echo "$sock"; exit 0 }
  sleep 0.25
done
echo "failed to start; see $dir/$profile.log" >&2; exit 1
