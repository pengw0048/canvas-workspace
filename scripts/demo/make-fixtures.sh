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
# Terminal fixture: a project folder whose shell has a neutral prompt and window title.
t=$d/cache-service; mkdir -p $t/bin $t/.zsh
cp "$(dirname $0)/loadtest.sh" $t/bin/cache-loadtest
printf "PROMPT='%%F{green}cache-service%%f %%# '\n" > $t/.zsh/.zshrc
cat > $t/load-test.command <<'SH'
#!/bin/zsh -f
d=${0:A:h}; cd $d; echo $$ > $d/.pid; export PATH="$d/bin:$PATH" ZDOTDIR=$d/.zsh
printf '\033]7;file://%s%s\007\033]0;load test\007\033[8;22;86t' "$HOST" "$d"; clear
exec zsh
SH
chmod +x $t/bin/cache-loadtest $t/load-test.command
# Numbers and Keynote sources; open them once and save native copies (see director.sh).
${PYTHON:-python3} "$(dirname $0)/office-fixtures.py" $d
echo "fixtures in $d"
