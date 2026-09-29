#!/bin/zsh
# Creates the demo fixture folder: scripts/demo/make-fixtures.sh <dir>
set -e
d=$1; mkdir -p $d
cat > $d/research.html <<'HTML'
<!doctype html><html><head><title>Cache rollout — engineering notes</title><style>
body{font:20px -apple-system;margin:0;background:#fafafa;color:#1d1d1f}
header{background:linear-gradient(120deg,#0b84f3,#6e56cf);color:white;padding:36px 48px}
h1{margin:0;font-size:38px} .sub{opacity:.85;margin-top:8px}
main{padding:28px 48px} .card{background:white;border-radius:14px;padding:22px 26px;margin:16px 0;box-shadow:0 2px 10px rgba(0,0,0,.06)}
.big{font-size:44px;font-weight:700;color:#0b84f3} li{margin:6px 0}</style></head><body>
<header><h1>Read-through cache rollout</h1><div class="sub">Engineering notes · week 39</div></header>
<main><div class="card"><div class="big">−60% p95</div><div>across four regions after enabling the cache</div></div>
<div class="card"><b>Method</b><ul><li>12,000 sampled requests per region</li><li>Same traffic replayed before and after</li><li>Cold-start requests excluded</li></ul></div></main></body></html>
HTML
printf 'region,p95_before_ms,p95_after_ms\nus-east,42,17\neu-west,47,19\nap-south,55,23\nsa-east,51,21\n' > $d/metrics.csv.txt
printf 'Launch review\n\nSummary\nThe read-through cache cut p95 latency by about 60%% in every region.\n\nEvidence\n' > $d/review.txt
textutil -convert rtfd $d/review.txt -output "$d/Launch review.rtfd"; rm $d/review.txt
swift "$(dirname $0)/chart.swift" $d/latency-chart.png
echo "fixtures in $d"
