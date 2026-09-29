#!/bin/zsh
# Plays the promo storyboard on the real host. Usage: scripts/demo/director.sh <work-dir> [record-seconds]
# <work-dir>/fixtures comes from make-fixtures.sh; <work-dir>/native holds Latency.numbers and
# "Launch review.key", saved once from the generated .xlsx/.pptx by Numbers and Keynote.
# Needs Screen Recording and Accessibility. Real mouse/keyboard events are posted for the app steps.
set -u
zmodload zsh/datetime
root=${0:A:h:h:h}; W=${1:A}; REC=${2:-0}
FX=$W/fixtures; NATIVE=$W/native; TK=$W/take; T=${TMPDIR:-/tmp}
source ${0:A:h}/lib.sh

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
CANVAS_USER_NAME=Alex CANVAS_DATA_DIR=$W $APP --automation --keycast --profile demo > $W/demo.log 2>&1 &
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
m present on >/dev/null; m 'fly -300 -300 0.9 0.01' >/dev/null                # Maya starts on the research notes
h present on >/dev/null; h focus >/dev/null; h fit >/dev/null; sleep 3
# Check the member side too: Maya must hold every window surface and be receiving its live frames.
fresh=$(m remoteframes | python3 -c "import json,sys; f=json.load(sys.stdin)['frames']; print(sum(1 for i in '$TERM $NUM $KEY'.split() if f.get(i, 99) < 3))")
(( fresh == 3 )) || { echo "Maya is not receiving live frames for all windows ($fresh of 3)"; exit 1; }

[[ -n ${SETUP_ONLY:-} ]] && { echo "setup done"; exit 0; }
wpt() { h state | python3 -c "import json,sys; o=[o for o in json.load(sys.stdin)['objects'] if o['id']=='$1'][0]; print(o['x']+o['w']*$2, o['y']+o['h']*$3)"; }
MPX=-500; MPY=-420; m pointer $MPX $MPY >/dev/null
mxy() { m glide $MPX $MPY $1 $2 ${3:-0.8} >/dev/null; MPX=$1; MPY=$2; }
mto() { local p=($(wpt $1 $2 $3)); mxy $p[1] $p[2] ${4:-0.8}; }
chat() { local S=($(h screen $1 $2 | xy)); isfront CanvasWorkspace && { $drive hover $S[1] $S[2]; $drive key 44; sleep 0.3; $drive typeu 45 "$3"; sleep 0.4; $drive key 36; }; }

# --- recording ---
rm -f $W/marks $W/demo.mov
if (( REC > 0 )); then T0=$EPOCHREALTIME; screencapture -v -V$REC $W/demo.mov & REC_PID=$!; sleep 1.5; fi
mark start
m 'fly -700 -260 0.9 3' >/dev/null; mto $PAGE 0.3 0.4 2.4; sleep 1.2                  # Maya reads the research page
chat -900 -150 "Maya, follow me, I'll rerun the load test"; sleep 0.6
mark follow; m follow $HOST_ID >/dev/null; sleep 0.5; mto $TERM 0.6 0.5 0.8; m chat 18 "ok, following" >/dev/null; sleep 1.2
h flyto $TERM 160 1.4; sleep 1.8; mark term-activate; dbl $TERM; sleep 1.2          # into the real Terminal
isfront Terminal && { $drive keys 15 "cache-loadtest --regions all"; sleep 0.3; $drive key 36; }; sleep 2.6
mark term-back; back Terminal; sleep 1
h fly -920 -60 0.62 1.4; sleep 1.6                                                   # research
# Real region capture of the chart: select, ⇧⌘R, drag.
P=($(wpt $NUM 0.5 0.5)); S=($(h screen $P[1] $P[2] | xy)); isfront CanvasWorkspace && $drive click $S[1] $S[2]; sleep 0.3
mark capture; isfront CanvasWorkspace && $drive key 15 cmd,shift; sleep 0.7
A=($(wpt $NUM 0.36 0.22)); B=($(wpt $NUM 0.9 0.69)); SA=($(h screen $A[1] $A[2] | xy)); SB=($(h screen $B[1] $B[2] | xy))
isfront CanvasWorkspace && $drive drag $SA[1] $SA[2] $SB[1] $SB[2] 200 100; sleep 2.2
h captureto $TERM 0.0 0.08 1.0 0.5 60 80 >/dev/null; sleep 1.6                         # live results → evidence
for id in $(h state | python3 -c "import json,sys; print(' '.join(o['id'] for o in json.load(sys.stdin)['objects'] if o['kind']=='image'))"); do h move $id 0 0 $FR_E >/dev/null; done
h fly 700 -40 0.7 1.4; sleep 1.6                                                     # evidence
NOTE=$(h 'create {"kind":"sticky","x":740,"y":130,"w":320,"h":230,"text":"","props":{"color":"#B8E6B0"}}' | jid); h move $NOTE 0 0 $FR_E >/dev/null
h typeslow $NOTE 18 "p95 down ~60% in all four regions." >/dev/null; sleep 2.2
# Maya leaves to check one region herself, on Alex's real Terminal.
mark unfollow; m follow >/dev/null; m chat 18 "let me check sa-east on your terminal" >/dev/null
m 'fly -1340 230 1.0 1.4' >/dev/null; mto $TERM 0.5 0.6 1.4; sleep 0.6
mark control; m requestcontrol $TERM >/dev/null; sleep 1.8                          # editors get control at once
m input $TERM key 0 0 "8 ctrl" >/dev/null; sleep 0.6                                  # ⌃C stops the run
m input $TERM text 0 0 "cache-loadtest --regions sa-east" >/dev/null; sleep 0.5; m input $TERM key 0 0 36 >/dev/null; sleep 2.6
m chat 18 "sa-east holds at ~21 ms ✓" >/dev/null; sleep 1.6
h reclaim $TERM >/dev/null; back Terminal; sleep 1
h fly 700 -40 0.7 1.2; sleep 0.8; m 'fly 880 160 0.9 1.2' >/dev/null; mto $NOTE 0.6 0.7 1.3; sleep 0.4   # Maya comes back to the notes
m typeslow $NOTE 16 " sa-east confirmed. — Maya" >/dev/null; sleep 2
chat 600 330 "thanks, adding it to the deck"; sleep 1
ARROW=$(h 'create {"kind":"shape","x":735,"y":210,"w":-150,"h":-160,"props":{"shape":"arrow","strokeWidth":5,"color":"#E5484D"}}' | jid); h move $ARROW 0 0 $FR_E >/dev/null; sleep 0.8
h select $(h state | python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(o['id'] for o in d['objects'] if o.get('parent')=='$FR_E' and o['kind'] in ('image','sticky','shape')))") >/dev/null
mark copy; isfront CanvasWorkspace && $drive key 8 cmd; sleep 0.9                      # real ⌘C
m follow $HOST_ID >/dev/null; mto $KEY 0.7 0.3 1.2                                      # Maya follows to watch the deck
h flyto $KEY 160 1.6; sleep 2; mark key-activate; dbl $KEY; sleep 1.4                    # into the real Keynote
F=($(frame Keynote "Launch review"))
isfront Keynote && { $drive click $((F[1] + 82)) $((F[2] + 148)); sleep 0.6; $drive click $((F[1] + F[3] / 2 - 60)) $((F[2] + F[4] - 90)); sleep 0.4; }
mark paste; isfront Keynote && $drive key 9 cmd; sleep 1.8                              # real ⌘V onto slide 2
isfront Keynote && $drive key 1 cmd; sleep 1.2                                          # real ⌘S
mark key-back; back Keynote; sleep 1.2
mto $KEY 0.5 0.55 0.8; m chat 18 "deck looks great 🚀" >/dev/null
h fly -300 -40 0.34 2.2; sleep 3; mark end                                                # pull back
if (( REC > 0 )); then wait $REC_PID; fi
# Close everything the take opened.
pkill -f 'CanvasWorkspace.*--profile (demo|maya)'; pkill -x Numbers; pkill -x Keynote
[[ -f $FX/cache-service/.pid ]] && kill -HUP $(cat $FX/cache-service/.pid) 2>/dev/null; sleep 1; $axclose Terminal "cache-service" >/dev/null; sleep 1.5
[[ -z "$($aw Terminal | sed 's/^[^|]*| //' | grep -v '^$')" ]] && pkill -x Terminal
echo "done: $W/demo.mov"
