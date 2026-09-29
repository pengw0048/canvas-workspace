#!/bin/zsh
# Plays the promo storyboard on the real host. Usage: scripts/demo/director.sh <work-dir> [record-seconds]
# Needs Screen Recording and Accessibility. Real mouse/keyboard events are posted for the app steps.
set -u
root=${0:A:h:h:h}; W=$1; REC=${2:-0}
FX=$W/fixtures; T=${TMPDIR:-/tmp}
HS=$T/cw-demo.sock; CS=$T/cw-maya.sock
h() { $root/scripts/cw.sh $HS "$@"; }; m() { $root/scripts/cw.sh $CS "$@"; }
jid() { python3 -c "import json,sys; print(json.load(sys.stdin)['id'])"; }
xy() { python3 -c "import json,sys; d=json.load(sys.stdin); print(int(d['x']), int(d['y']))"; }
drive=$T/cw-drive; [[ $drive -nt $root/scripts/drive.swift ]] || swiftc -O $root/scripts/drive.swift -o $drive 2>/dev/null
front() { $drive front; }
win() { h windows | python3 -c "import json,sys; ws=[w for w in json.load(sys.stdin)['windows'] if w['title'].startswith('$1')]; print(ws[0]['id'] if ws else '')"; }

# --- setup (not recorded) ---
rm -rf $W/host $W/maya; mkdir -p $W
# Earlier takes leave windows with the same titles. Quit TextEdit and Preview, but only when every
# titled window belongs to a demo or test fixture; otherwise stop so nothing personal is lost.
aw=$T/cw-appwindows; [[ $aw -nt $root/scripts/demo/app-windows.swift ]] || swiftc -O $root/scripts/demo/app-windows.swift -o $aw 2>/dev/null
allowed='^(latency-chart.png|sample.png|Launch review.rtfd|metrics.csv.txt|data.txt|deliverable.rtfd|final.rtfd|final.rtf|report.txt|)$'
others=$($aw | sed 's/^[^|]*| //' | grep -Ev "$allowed")
if [[ -n "$others" ]]; then echo "refusing to reset: other TextEdit/Preview windows are open:"; echo "$others"; exit 1; fi
pkill -x TextEdit; pkill -x Preview; sleep 1.5
open -a TextEdit $FX/metrics.csv.txt; open -a Preview $FX/latency-chart.png; open -a TextEdit "$FX/Launch review.rtfd"; sleep 3
rm -f $HS $CS
CANVAS_DATA_DIR=$W $root/.build/debug/CanvasWorkspace --automation --profile demo > $W/demo.log 2>&1 &
until [[ -S $HS ]] && h state 2>/dev/null | grep -q objects; do sleep 0.2; done; sleep 1
FR_R=$(h 'create {"kind":"frame","x":-1650,"y":-520,"w":1560,"h":1000,"props":{"name":"Research"}}' | jid)
FR_E=$(h 'create {"kind":"frame","x":0,"y":-520,"w":1100,"h":1000,"props":{"name":"Evidence"}}' | jid)
PAGE=$(h page file://$FX/research.html reference | jid); h geom $PAGE -1600 -460 760 510 >/dev/null; h move $PAGE 0 0 $FR_R >/dev/null
CHART=$(h admit $(win latency-chart) -800 -200 | jid); h geom $CHART -800 -460 680 490 >/dev/null; h move $CHART 0 0 $FR_R >/dev/null
DATA=$(h admit $(win metrics.csv) -1250 250 | jid); h geom $DATA -1600 110 560 330 >/dev/null; h move $DATA 0 0 $FR_R >/dev/null
REVIEW=$(h admit $(win "Launch review") 1650 0 | jid)
Q=$(h 'create {"kind":"sticky","x":-1000,"y":150,"w":230,"h":170,"text":"Is the gain the same in every region?","props":{"color":"#FFE58A"}}' | jid); h move $Q 0 0 $FR_R >/dev/null
h 'create {"kind":"text","x":1250,"y":-520,"w":700,"h":60,"text":"Launch review","props":{"fontSize":40}}' >/dev/null
SC=$(h share $FR_E DEMO-CODE-2026 | python3 -c "import json,sys; print(json.load(sys.stdin)['scope'])"); sleep 1.5
PORT=$(h port $SC | python3 -c "import json,sys; print(json.load(sys.stdin)['port'])")
CANVAS_USER_NAME=Maya CANVAS_PASTEBOARD=cw-demo CANVAS_DATA_DIR=$W $root/.build/debug/CanvasWorkspace --windowed --automation --hidden --profile maya > $W/maya.log 2>&1 &
until [[ -S $CS ]] && m state 2>/dev/null | grep -q objects; do sleep 0.2; done; m join DEMO-CODE-2026 127.0.0.1:$PORT >/dev/null; sleep 3
h present on >/dev/null; h focus >/dev/null; h fit >/dev/null; sleep 3

# --- recording ---
if (( REC > 0 )); then screencapture -v -V$REC $W/demo.mov & REC_PID=$!; sleep 1.5; fi
sleep 2.5                                                    # overview
h fly -1000 -120 0.62 1.8; sleep 2.6                         # research
h captureto $CHART 0.03 0.14 0.94 0.8 60 -470 >/dev/null; sleep 1.6    # chart → evidence
h captureto $PAGE 0.0 0.2 0.62 0.32 60 60 >/dev/null; sleep 1.4          # headline card → evidence
for id in $(h state | python3 -c "import json,sys; print(' '.join(o['id'] for o in json.load(sys.stdin)['objects'] if o['kind']=='image'))"); do h move $id 0 0 $FR_E >/dev/null; done
h fly 520 -60 0.72 1.6; sleep 1.8                            # evidence
NOTE=$(h 'create {"kind":"sticky","x":740,"y":110,"w":320,"h":230,"text":"","props":{"color":"#B8E6B0"}}' | jid); h move $NOTE 0 0 $FR_E >/dev/null
h typeslow $NOTE 18 "p95 down ~60% in all four regions." >/dev/null; sleep 2.2
m pointer 1300 -300 >/dev/null; m glide 1300 -300 900 330 1.4 >/dev/null; sleep 1.6
m typeslow $NOTE 16 " Confirmed on sa-east. — Maya" >/dev/null; sleep 2.6
ARROW=$(h 'create {"kind":"shape","x":735,"y":190,"w":-170,"h":-150,"props":{"shape":"arrow","strokeWidth":5,"color":"#E5484D"}}' | jid); h move $ARROW 0 0 $FR_E >/dev/null; sleep 0.8
h select $(h state | python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(o['id'] for o in d['objects'] if o.get('parent')=='$FR_E' and o['kind'] in ('image','sticky','shape')))") >/dev/null
[[ $(front) == CanvasWorkspace ]] && $drive key 8 cmd; sleep 0.8   # real ⌘C
h flyto $REVIEW 160 1.6; sleep 2
P=($(h state | python3 -c "import json,sys; o=[o for o in json.load(sys.stdin)['objects'] if o['id']=='$REVIEW'][0]; print(o['x']+o['w']/2, o['y']+o['h']*0.6)"))
S=($(h screen ${P[1]} ${P[2]} | xy)); [[ $(front) == CanvasWorkspace ]] && $drive click ${S[1]} ${S[2]} double; sleep 1.4
[[ $(front) == TextEdit ]] && { $drive key 125 cmd; sleep 0.3; $drive key 9 cmd; }; sleep 1.8   # real ⌘V
[[ $(front) == TextEdit ]] && $drive key 1 cmd; sleep 1.2                                         # real ⌘S
[[ $(front) == TextEdit ]] && $drive key 49 ctrl,opt; sleep 1.4                                   # back to canvas
h fly -150 -40 0.36 2.2; sleep 2.6                                                                  # pull back
[[ $(front) == CanvasWorkspace ]] && $drive key 12 cmd; sleep 2.5                                 # leave
CANVAS_DATA_DIR=$W $root/.build/debug/CanvasWorkspace --automation --profile demo >> $W/demo.log 2>&1 &
until [[ -S $HS ]] && h state 2>/dev/null | grep -q objects; do sleep 0.2; done; h present on >/dev/null; sleep 4    # resume
if (( REC > 0 )); then wait $REC_PID; fi
echo "done: $W/demo.mov"
