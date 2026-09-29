#!/bin/zsh
# Plays the promo storyboard on the real host. Usage: scripts/demo/director.sh <work-dir> [record-seconds]
# <work-dir>/fixtures comes from make-fixtures.sh; <work-dir>/native holds Latency.numbers and
# "Launch review.key", saved once from the generated .xlsx/.pptx by Numbers and Keynote.
# Needs Screen Recording and Accessibility. Real mouse/keyboard events are posted for the app steps.
set -u
zmodload zsh/datetime
root=${0:A:h:h:h}; W=${1:A}; REC=${2:-0}
FX=$W/fixtures; NATIVE=$W/native; TK=$W/take; T=${TMPDIR:-/tmp}
HS=$T/cw-demo.sock; CS=$T/cw-maya.sock
# Unbundled, so it runs with the terminal's Screen Recording and Accessibility grants (swift build -c release).
APP=${CANVAS_APP:-$root/.build/release/CanvasWorkspace}
h() { $root/scripts/cw.sh $HS "$@"; }; m() { $root/scripts/cw.sh $CS "$@"; }
jid() { python3 -c "import json,sys; print(json.load(sys.stdin)['id'])"; }
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

# --- setup (not recorded) ---
pkill -f 'CanvasWorkspace.*--profile (demo|maya)'; for i in {1..50}; do pgrep -f 'CanvasWorkspace.*--profile (demo|maya)' >/dev/null || break; sleep 0.2; done
[[ -f $FX/research.html && -f $NATIVE/Latency.numbers && -f "$NATIVE/Launch review.key" ]] || { echo "missing fixtures or native documents under $W"; exit 1; }
# Earlier takes leave windows with the same titles. Quit Numbers and Keynote only when every titled
# window is a demo fixture; otherwise stop so nothing personal is lost.
others=$($aw Numbers Keynote | sed 's/^[^|]*| //' | grep -Ev '^(Latency.numbers|Launch review(.key)?|Window)?$')
if [[ -n "$others" ]]; then echo "refusing to reset: other Numbers/Keynote windows are open:"; echo "$others"; exit 1; fi
pkill -x Numbers; pkill -x Keynote
for i in {1..50}; do pgrep -x "Numbers|Keynote" >/dev/null || break; sleep 0.2; done
# Earlier load-test windows: end their shell, then close the finished window without a prompt.
[[ -f $FX/cache-service/.pid ]] && kill -HUP $(cat $FX/cache-service/.pid) 2>/dev/null; sleep 1; $axclose Terminal "cache-service" >/dev/null
rm -rf $W/demo $W/maya $TK; mkdir -p $TK; cp -R $NATIVE/Latency.numbers "$NATIVE/Launch review.key" $TK/
open -b com.apple.Numbers $TK/Latency.numbers --args -ApplePersistenceIgnoreState YES
open -b com.apple.Keynote "$TK/Launch review.key" --args -ApplePersistenceIgnoreState YES
open -a Terminal $FX/cache-service/load-test.command; sleep 5
$resize Numbers Latency 1260 720; $resize Keynote "Launch review" 1200 640
rm -f $HS $CS
CANVAS_USER_NAME=Alex CANVAS_DATA_DIR=$W $APP --automation --profile demo > $W/demo.log 2>&1 &
until [[ -S $HS ]] && h state 2>/dev/null | grep -q objects; do sleep 0.2; done; sleep 1
FR_ALL=$(h 'create {"kind":"frame","x":-1780,"y":-720,"w":4120,"h":1300,"props":{"name":"Cache launch"}}' | jid)
FR_R=$(h 'create {"kind":"frame","x":-1700,"y":-560,"w":1560,"h":1060,"props":{"name":"Research"}}' | jid)
FR_E=$(h 'create {"kind":"frame","x":0,"y":-560,"w":1100,"h":1060,"props":{"name":"Evidence"}}' | jid)
PAGE=$(h page file://$FX/research.html reference | jid); h geom $PAGE -1650 -500 700 470 >/dev/null; h move $PAGE 0 0 $FR_R >/dev/null
NUM=$(h admit $(win Numbers Latency) -900 -300 | jid); h geom $NUM -910 -500 720 411 >/dev/null; h move $NUM 0 0 $FR_R >/dev/null
TERM=$(h admit $(win Terminal cache-service) -1400 250 | jid); h geom $TERM -1650 30 620 400 >/dev/null; h move $TERM 0 0 $FR_R >/dev/null
KEY=$(h admit $(win Keynote "Launch review") 1800 0 | jid); h geom $KEY 1250 -330 1000 533 >/dev/null; h move $KEY 0 0 $FR_ALL >/dev/null
Q=$(h 'create {"kind":"sticky","x":-880,"y":90,"w":250,"h":180,"text":"Is the gain the same in every region?","props":{"color":"#FFE58A"}}' | jid); h move $Q 0 0 $FR_R >/dev/null
TITLE=$(h 'create {"kind":"text","x":1250,"y":-440,"w":700,"h":60,"text":"Launch review","props":{"fontSize":40}}' | jid)
for id in $FR_R $FR_E $TITLE; do h move $id 0 0 $FR_ALL >/dev/null; done
h live $TERM >/dev/null
# The whole board is shared; its windows stream live to Maya.
SC=$(h share $FR_ALL DEMO-CODE-2026 | python3 -c "import json,sys; print(json.load(sys.stdin)['scope'])"); sleep 1.5
PORT=$(h port $SC | python3 -c "import json,sys; print(json.load(sys.stdin)['port'])")
for id in $TERM $NUM $KEY $PAGE; do h liveshare $id >/dev/null; done
HOST_ID=$(h identity | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
CANVAS_USER_NAME=Maya CANVAS_PASTEBOARD=cw-demo CANVAS_DATA_DIR=$W $APP --windowed --automation --pip --profile maya > $W/maya.log 2>&1 &
until [[ -S $CS ]] && m state 2>/dev/null | grep -q objects; do sleep 0.2; done; m join DEMO-CODE-2026 127.0.0.1:$PORT >/dev/null; sleep 3
m present on >/dev/null; m follow $HOST_ID >/dev/null                        # Maya follows Alex's view
h present on >/dev/null; h focus >/dev/null; h fit >/dev/null; sleep 3
# Check the member side too: Maya must hold every window surface and be receiving its live frames.
fresh=$(m remoteframes | python3 -c "import json,sys; f=json.load(sys.stdin)['frames']; print(sum(1 for i in '$TERM $NUM $KEY'.split() if f.get(i, 99) < 3))")
(( fresh == 3 )) || { echo "Maya is not receiving live frames for all windows ($fresh of 3)"; exit 1; }

# --- recording ---
rm -f $W/marks $W/demo.mov
if (( REC > 0 )); then T0=$EPOCHREALTIME; screencapture -v -V$REC $W/demo.mov & REC_PID=$!; sleep 1.5; fi
mark start
sleep 2.5                                                             # overview
h flyto $TERM 160 1.4; sleep 1.8; mark term-activate; dbl $TERM; sleep 1.4                # into the real Terminal
isfront Terminal && { $drive keys 15 "cache-loadtest --regions all"; sleep 0.3; $drive key 36; }; sleep 3
mark term-back; back Terminal; sleep 1.2                                              # canvas; the test keeps streaming
h fly -920 -60 0.62 1.6; sleep 2.2                                    # research
mark capture; h captureto $NUM 0.36 0.22 0.54 0.47 60 -500 >/dev/null; sleep 1.6    # chart → evidence
h captureto $TERM 0.0 0.08 1.0 0.5 60 80 >/dev/null; sleep 1.4        # live results → evidence
for id in $(h state | python3 -c "import json,sys; print(' '.join(o['id'] for o in json.load(sys.stdin)['objects'] if o['kind']=='image'))"); do h move $id 0 0 $FR_E >/dev/null; done
h fly 700 -40 0.7 1.6; sleep 1.8                                      # evidence
NOTE=$(h 'create {"kind":"sticky","x":740,"y":130,"w":320,"h":230,"text":"","props":{"color":"#B8E6B0"}}' | jid); h move $NOTE 0 0 $FR_E >/dev/null
h typeslow $NOTE 18 "p95 down ~60% in all four regions." >/dev/null; sleep 2.2
m pointer 1300 -300 >/dev/null; m glide 1300 -300 1040 70 1.4 >/dev/null; sleep 1.6
mark chat; m chat 18 "sa-east matches my run too" >/dev/null; sleep 2.4             # cursor chat
m typeslow $NOTE 16 " Confirmed on sa-east. — Maya" >/dev/null; sleep 2.2
S=($(h screen 600 330 | xy)); isfront CanvasWorkspace && { $drive hover $S[1] $S[2]; $drive key 44; sleep 0.3; $drive keys 25 "thanks, adding it to the deck"; sleep 0.4; $drive key 36; }; sleep 1.2   # real cursor chat reply
ARROW=$(h 'create {"kind":"shape","x":735,"y":210,"w":-150,"h":-160,"props":{"shape":"arrow","strokeWidth":5,"color":"#E5484D"}}' | jid); h move $ARROW 0 0 $FR_E >/dev/null; sleep 0.8
h select $(h state | python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(o['id'] for o in d['objects'] if o.get('parent')=='$FR_E' and o['kind'] in ('image','sticky','shape')))") >/dev/null
mark copy; isfront CanvasWorkspace && $drive key 8 cmd; sleep 0.8      # real ⌘C
h flyto $KEY 160 1.6; sleep 2; mark key-activate; dbl $KEY; sleep 1.4                    # into the real Keynote
F=($(frame Keynote "Launch review")); echo "keynote frame: $F" >&2
isfront Keynote && { $drive click $((F[1] + 82)) $((F[2] + 148)); sleep 0.6; $drive click $((F[1] + F[3] / 2 - 60)) $((F[2] + F[4] - 90)); sleep 0.4; }
mark paste; isfront Keynote && $drive key 9 cmd; sleep 1.8              # real ⌘V onto slide 2
isfront Keynote && $drive key 1 cmd; sleep 1.2              # real ⌘S
mark key-back; back Keynote; sleep 1.4
h fly -300 -40 0.34 2.2; sleep 2.6                                    # pull back
mark quit; isfront CanvasWorkspace && $drive key 12 cmd; sleep 2.5     # leave
CANVAS_USER_NAME=Alex CANVAS_DATA_DIR=$W $APP --automation --profile demo >> $W/demo.log 2>&1 &
until [[ -S $HS ]] && h state 2>/dev/null | grep -q objects; do sleep 0.2; done; h present on >/dev/null
h live $TERM >/dev/null; for id in $TERM $NUM $KEY $PAGE; do h liveshare $id >/dev/null; done; sleep 0.8; mark resumed; sleep 4.5; mark end                                    # resume; the load test is still running
if (( REC > 0 )); then wait $REC_PID; fi
echo "done: $W/demo.mov"
