#!/bin/zsh
# Runs the core tests. With the Command Line Tools toolchain the Testing macro plugin sometimes
# fails to load on the first build after `swift build`; a later attempt succeeds.
cd "$(dirname $0)/.."
for i in 1 2 3; do
  out=$(swift test "$@" 2>&1)
  if print -r -- "$out" | grep -q "Test run with"; then print -r -- "$out" | grep -E "✔|✘"; print -r -- "$out" | grep -q "✘" && exit 1; exit 0; fi
  print -r -- "$out" | grep -q "TestingMacros" || { print -r -- "$out" | tail -20; exit 1 }
done
exit 1
