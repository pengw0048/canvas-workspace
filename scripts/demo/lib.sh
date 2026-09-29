# Shared helpers for the demo directors. Expects root, W and T; defines the host (h) and member (m, b) clients.
HS=${HS:-$T/cw-demo.sock}; CS=${CS:-$T/cw-maya.sock}; BS=${BS:-$T/cw-member2.sock}
# Unbundled, so it runs with the terminal's Screen Recording and Accessibility grants (swift build -c release).
APP=${CANVAS_APP:-$root/.build/release/CanvasWorkspace}
h() { $root/scripts/cw.sh $HS "$@"; }; m() { $root/scripts/cw.sh $CS "$@"; }; b() { $root/scripts/cw.sh $BS "$@"; }
jid() { python3 -c "import json,sys; d=sys.stdin.read(); j=json.loads(d); print(j['id']) if 'id' in j else sys.exit('no id in reply: ' + d)"; }
xy() { python3 -c "import json,sys; d=json.load(sys.stdin); print(int(d['x']), int(d['y']))"; }
tool() { local b=$T/cw-$1; [[ $b -nt $2 ]] || swiftc -O $2 -o $b 2>/dev/null; echo $b; }
drive=$(tool drive $root/scripts/drive.swift); aw=$(tool appwindows $root/scripts/demo/app-windows.swift)
axclose=$(tool axclose $root/scripts/axclose.swift); resize=$(tool sizewindow $root/scripts/demo/size-window.swift)
front() { $drive front; }
# Real input goes only to the expected app; anything else (a system prompt, say) stops the take.
isfront() { for i in {1..30}; do [[ $(front) == $1 ]] && return 0; sleep 0.1; done; echo "stopping: $(front) (pid $($drive front pid)) is frontmost, expected $1" >&2; kill -INT ${REC_PID:-} 2>/dev/null; sleep 2; exit 1; }
win() { h windows | python3 -c "import json,sys; ws=[w for w in json.load(sys.stdin)['windows'] if w['owner']=='$1' and w['title'].startswith('$2')]; print(ws[0]['id'] if ws else '')"; }
frame() { h windows | python3 -c "import json,sys; ws=[w for w in json.load(sys.stdin)['windows'] if w['owner']=='$1' and w['title'].startswith('$2')]; print(*map(int, ws[0]['frame']))"; }
center() { h state | python3 -c "import json,sys; o=[o for o in json.load(sys.stdin)['objects'] if o['id']=='$1'][0]; print(o['x']+o['w']/2, o['y']+o['h']/2)"; }
dbl() { local p=($(center $1)); local s=($(h screen $p[1] $p[2] | xy)); isfront CanvasWorkspace && $drive click $s[1] $s[2] double; }
T0=$EPOCHREALTIME; mark() { printf '%s %.2f\n' $1 $(( EPOCHREALTIME - T0 )) >> $W/marks; }   # cut points for export.sh
back() { isfront $1 && $drive key 49 ctrl,opt; }   # the canvas's return hot key
