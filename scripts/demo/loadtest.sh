#!/bin/bash
# A long-running demo load test that prints live latency samples (fixture for recordings).
echo "cache-loadtest  ·  12,000 requests per region  ·  read-through cache ON"
echo
regions=(us-east eu-west ap-south sa-east); base=(17 19 23 21)
n=0
while true; do
  i=$((n % 4)); j=$((RANDOM % 5 - 2)); p=$((base[i] + j))
  printf '%s  %-9s  p95 %3d ms   p50 %3d ms   ok\n' "$(date +%H:%M:%S)" "${regions[$i]}" "$p" "$((p / 2 + 2))"
  n=$((n + 1)); sleep 0.35
done
