#!/bin/bash
# A long-running demo load test that prints live latency samples (fixture for recordings).
# cache-loadtest [--regions all|<region>]
regions=(us-east eu-west ap-south sa-east); base=(17 19 23 21)
only=${2:-all}
echo "cache-loadtest  ·  12,000 requests per region  ·  read-through cache ON  ·  regions: $only"
echo
n=0
while true; do
  i=$((n % 4)); n=$((n + 1))
  [[ $only != all && ${regions[$i]} != "$only" ]] && continue
  j=$((RANDOM % 5 - 2)); p=$((base[i] + j))
  printf '%s  %-9s  p95 %3d ms   p50 %3d ms   ok\n' "$(date +%H:%M:%S)" "${regions[$i]}" "$p" "$((p / 2 + 2))"
  sleep 0.35
done
