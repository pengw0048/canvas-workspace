#!/bin/zsh
# Plays the family trip storyboard. Usage: scripts/demo/japan/director.sh <work-dir> [record-seconds]
# <work-dir>/fixtures comes from make-fixtures.sh; <work-dir>/native holds 旅行预算.numbers and 日本行程.pages,
# saved once from the generated .xlsx/.docx by Numbers and Pages.
set -u
zmodload zsh/datetime
root=${0:A:h:h:h:h}; W=${1:A}; REC=${2:-0}
FX=$W/fixtures; NATIVE=$W/native; TK=$W/take; T=${TMPDIR:-/tmp}
HS=$T/cw-trip.sock; CS=$T/cw-mama.sock; BS=$T/cw-gege.sock
source $root/scripts/demo/lib.sh

# --- setup (not recorded) ---
pkill -f 'CanvasWorkspace.*--profile (trip|mama|gege|demo|maya)'; for i in {1..50}; do pgrep -f 'CanvasWorkspace.*--profile (trip|mama|gege)' >/dev/null || break; sleep 0.2; done
[[ -f $FX/booking.html && -e $NATIVE/旅行预算.numbers && -e $NATIVE/日本行程.pages ]] || { echo "missing fixtures or native documents under $W"; exit 1; }
# Quit the apps only when every titled window is a demo fixture, so nothing personal is lost.
others=$($aw Numbers Pages Preview Maps Weather Calculator | sed 's/^[^|]*| //' | grep -Ev '^(旅行预算(.numbers)?|日本行程(.pages)?|新幹線.*|Latency.numbers|latency-chart.png|sample.png|Maps|Kyoto|Calculator|Untitled|Window)?$')
if [[ -n "$others" ]]; then echo "refusing to reset: other windows are open:"; echo "$others"; exit 1; fi
pkill -x Numbers; pkill -x Pages; pkill -x Preview; pkill -x Maps; pkill -x Weather; pkill -x Calculator
for i in {1..50}; do pgrep -x "Numbers|Pages|Preview|Maps|Weather|Calculator" >/dev/null || break; sleep 0.2; done
rm -rf $W/trip $W/mama $W/gege $TK; mkdir -p $TK; cp -R $NATIVE/旅行预算.numbers $NATIVE/日本行程.pages $TK/
open -b com.apple.Numbers $TK/旅行预算.numbers --args -ApplePersistenceIgnoreState YES
open -b com.apple.Pages $TK/日本行程.pages --args -ApplePersistenceIgnoreState YES
open -a Preview $FX/新幹線きっぷ.pdf --args -ApplePersistenceIgnoreState YES
open "maps://?ll=34.99,135.76&z=11"; open -a Calculator; open -a Weather; sleep 7
open -a Calculator; isfront Calculator && { $drive key 53; $drive key 53; }                  # clear the last calculation
# Weather shows Kyoto through its own search (real input, before recording).
F=($(swift -e 'import CoreGraphics; for w in (CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as! [[String:Any]]) where (w["kCGWindowOwnerName"] as? String)=="Weather" && (w["kCGWindowLayer"] as? Int)==0 { let b = w["kCGWindowBounds"] as! [String:Double]; print(Int(b["X"]!), Int(b["Y"]!)); break }')); open -a Weather; isfront Weather && { $drive click $((F[1] + 135)) $((F[2] + 80)); sleep 0.5; $drive typeu 40 Kyoto; sleep 2.5; $drive click $((F[1] + 73)) $((F[2] + 122)); sleep 2; }
# Maps: search the trip's route by driving (real input, before recording); the take only switches to transit.
$resize Maps Maps 1100 760; open -b com.apple.Maps; sleep 1
MF=($(swift -e 'import CoreGraphics; for w in (CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as! [[String:Any]]) where (w["kCGWindowOwnerName"] as? String)=="Maps" && (w["kCGWindowName"] as? String)=="Maps" { let b = w["kCGWindowBounds"] as! [String:Double]; print(Int(b["X"]!), Int(b["Y"]!)); break }'))
isfront Maps && {
  $drive key 3 cmd; sleep 0.5; $drive typeu 30 "Nara Park"; sleep 2; $drive key 36; sleep 2.5
  $drive click $((MF[1] + 293)) $((MF[2] + 148)); sleep 2
  $drive click $((MF[1] + 304)) $((MF[2] + 116)); sleep 1.2; $drive typeu 30 "Kyoto Station"; sleep 2.2
  $drive click $((MF[1] + 308)) $((MF[2] + 132)); sleep 2.5; }
$resize Numbers 旅行预算 1260 720; $resize Pages 日本行程 1000 760; $resize Preview 新幹線 700 420; $resize Maps Maps 1100 760
rm -f $HS $CS $BS
# The booking page is served like a website.
pkill -f 'http.server 8765'; (cd $FX && python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1 &); sleep 0.5
CANVAS_USER_NAME=小安 CANVAS_DATA_DIR=$W $APP --automation --keycast --profile trip > $W/trip.log 2>&1 &
until [[ -S $HS ]] && h state 2>/dev/null | grep -q objects; do sleep 0.2; done; sleep 1
sticky() { h "create {\"kind\":\"sticky\",\"x\":$1,\"y\":$2,\"w\":230,\"h\":150,\"text\":\"$3\",\"props\":{\"color\":\"$4\"}}" | jid; }
BOARD=$(h 'create {"kind":"frame","x":-1900,"y":-760,"w":4300,"h":1420,"props":{"name":"日本 · 四月"}}' | jid)
FR_TK=$(h 'create {"kind":"frame","x":-1860,"y":-680,"w":620,"h":1300,"props":{"name":"东京"}}' | jid)
FR_KY=$(h 'create {"kind":"frame","x":-1200,"y":-680,"w":1160,"h":1300,"props":{"name":"京都 · 奈良"}}' | jid)
FR_BG=$(h 'create {"kind":"frame","x":0,"y":-680,"w":1000,"h":560,"props":{"name":"预算"}}' | jid)
FR_BK=$(h 'create {"kind":"frame","x":0,"y":-80,"w":1000,"h":700,"props":{"name":"预订"}}' | jid)
FR_DOC=$(h 'create {"kind":"frame","x":1040,"y":-680,"w":1320,"h":1300,"props":{"name":"行程单"}}' | jid)
for f in $FR_TK $FR_KY $FR_BG $FR_BK $FR_DOC; do h move $f 0 0 $BOARD >/dev/null; done
for s in "-1820 -620 羽田到达，住浅草 #FFE58A" "-1560 -620 晴空塔看夜景 #FFE58A"; do
  a=(${=s}); id=$(sticky $a[1] $a[2] $a[3] $a[4]); h move $id 0 0 $FR_TK >/dev/null; done
MAPS=$(h admit $(win Maps Maps) -900 -300 | jid); h geom $MAPS -1160 -620 740 511 >/dev/null; h move $MAPS 0 0 $FR_KY >/dev/null
for s in "-380 -620 伏见稻荷要早点去 #FFE58A"; do
  a=(${=s}); id=$(sticky $a[1] $a[2] $a[3] $a[4]); h move $id 0 0 $FR_KY >/dev/null; done
NUM=$(h admit $(win Numbers 旅行预算) 300 -400 | jid); h geom $NUM 40 -620 560 320 >/dev/null; h move $NUM 0 0 $FR_BG >/dev/null
CALC=$(h admit $(win Calculator Calculator) 700 -500 | jid); h geom $CALC 630 -620 330 200 >/dev/null; h move $CALC 0 0 $FR_BG >/dev/null
WEATHER=$(h admit $(win Weather Kyoto) -300 -200 | jid); h geom $WEATHER -400 -60 340 208 >/dev/null; h move $WEATHER 0 0 $FR_KY >/dev/null
BOOK=$(h page http://localhost:8765/booking.html sharedRuntime | jid); h geom $BOOK 40 -20 480 322 >/dev/null; h move $BOOK 0 0 $FR_BK >/dev/null
TICKET=$(h admit $(win Preview 新幹線) 600 100 | jid); h geom $TICKET 560 -20 400 240 >/dev/null; h move $TICKET 0 0 $FR_BK >/dev/null
PAGES=$(h admit $(win Pages 日本行程) 1500 0 | jid); h geom $PAGES 1080 -620 1000 760 >/dev/null; h move $PAGES 0 0 $FR_DOC >/dev/null
SC=$(h share $BOARD TRIP-CODE-2026 | python3 -c "import json,sys; print(json.load(sys.stdin)['scope'])"); sleep 1.5
PORT=$(h port $SC | python3 -c "import json,sys; print(json.load(sys.stdin)['port'])")
for id in $MAPS $NUM $CALC $WEATHER $BOOK $TICKET $PAGES; do h liveshare $id >/dev/null; done
HOST_ID=$(h identity | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
CANVAS_USER_NAME=妈妈 CANVAS_PASTEBOARD=cw-demo CANVAS_DATA_DIR=$W $APP --windowed --automation --pip --profile mama > $W/mama.log 2>&1 &
CANVAS_USER_NAME=哥哥 CANVAS_PASTEBOARD=cw-demo CANVAS_DATA_DIR=$W $APP --windowed --automation --hidden --profile gege > $W/gege.log 2>&1 &
until [[ -S $CS ]] && m state 2>/dev/null | grep -q objects; do sleep 0.2; done; m join TRIP-CODE-2026 127.0.0.1:$PORT >/dev/null
until [[ -S $BS ]] && b state 2>/dev/null | grep -q objects; do sleep 0.2; done; b join TRIP-CODE-2026 127.0.0.1:$PORT >/dev/null; sleep 3
m present on >/dev/null; m 'fly -1580 -520 0.85 0.01' >/dev/null; m pointer -1700 -560 >/dev/null
# Notes written earlier by the others carry their names.
note() { $1 "create {\"kind\":\"sticky\",\"x\":$2,\"y\":$3,\"w\":230,\"h\":150,\"text\":\"$4\",\"parent\":\"$5\",\"scope\":\"$SC\",\"props\":{\"color\":\"$6\"}}" >/dev/null; }
note m -1820 -430 上野公园赏樱🌸 $FR_TK "#FFC8DD"; note b -1560 -430 筑地市场吃早餐 $FR_TK "#B8E6B0"; note m -380 -440 想吃抹茶🍵 $FR_KY "#B8E6B0"
b pointer 2200 500 >/dev/null
h present on >/dev/null; h focus >/dev/null; h fit >/dev/null; sleep 3
# Both members must hold the window surfaces and be receiving live frames.
for c in m b; do
  fresh=$($c remoteframes | python3 -c "import json,sys; f=json.load(sys.stdin)['frames']; print(sum(1 for i in '$MAPS $NUM $PAGES'.split() if f.get(i, 99) < 3))")
  (( fresh == 3 )) || { echo "$c is not receiving live frames for all windows ($fresh of 3)"; exit 1; }
done

[[ -n ${SETUP_ONLY:-} ]] && { echo "setup done"; exit 0; }
# 妈妈's pointer glides to a spot on an object, so it stays inside what she is looking at.
wpt() { h state | python3 -c "import json,sys; o=[o for o in json.load(sys.stdin)['objects'] if o['id']=='$1'][0]; print(o['x']+o['w']*$2, o['y']+o['h']*$3)"; }
MPX=-1700; MPY=-560
mxy() { m glide $MPX $MPY $1 $2 ${3:-0.8} >/dev/null; MPX=$1; MPY=$2; }           # glide to a world point
mto() { local p=($(wpt $1 $2 $3)); mxy $p[1] $p[2] ${4:-0.8}; }                    # glide onto part of an object
# --- recording ---
rm -f $W/marks $W/demo.mov
if (( REC > 0 )); then T0=$EPOCHREALTIME; screencapture -v -V$REC $W/demo.mov & REC_PID=$!; sleep 1.5; fi
mark start
m 'fly -1580 -330 0.85 3' >/dev/null; mxy -1450 -380 2.6; sleep 2.5   # 妈妈 reads the Tokyo notes
S=($(h screen -700 -150 | xy)); isfront CanvasWorkspace && { $drive hover $S[1] $S[2]; $drive key 44; sleep 0.3; $drive typeu 90 "妈妈您跟着我的屏幕，我讲一下路线"; sleep 0.4; $drive key 36; }; sleep 1.2
mark follow; m follow $HOST_ID >/dev/null; sleep 0.6; mto $MAPS 0.8 0.3 0.9; sleep 0.8             # 妈妈 follows 小安's view
m chat 14 "好的，第三天能去奈良吗？" >/dev/null; sleep 2.2
h flyto $MAPS 160 1.4; sleep 1.8; mark maps; dbl $MAPS; sleep 1.4                    # into the real Maps: search the route
F=($(frame Maps Maps)); isfront Maps && { $drive click $((F[1] + 403)) $((F[2] + 80)); sleep 2.6; }   # the one real step: switch to transit
back Maps; sleep 1.2
# Real region capture: select the surface, ⇧⌘R, drag over the route.
P=($(wpt $MAPS 0.5 0.5)); S=($(h screen $P[1] $P[2] | xy)); isfront CanvasWorkspace && $drive click $S[1] $S[2]; sleep 0.4
mark capture; isfront CanvasWorkspace && $drive key 15 cmd,shift; sleep 0.8
A=($(wpt $MAPS 0.46 0.1)); B=($(wpt $MAPS 0.99 0.97)); SA=($(h screen $A[1] $A[2] | xy)); SB=($(h screen $B[1] $B[2] | xy))
isfront CanvasWorkspace && $drive drag $SA[1] $SA[2] $SB[1] $SB[2] 200 100; sleep 2.4
ROUTE=$(h state | python3 -c "import json,sys; print([o['id'] for o in json.load(sys.stdin)['objects'] if o['kind']=='image'][-1])"); h move $ROUTE 0 0 $FR_KY >/dev/null
b glide 2200 500 -260 -190 1.4 >/dev/null; sleep 1.5                                  # 哥哥 adds a note
GG=$(b "create {\"kind\":\"sticky\",\"x\":-380,\"y\":-270,\"w\":230,\"h\":150,\"text\":\"\",\"parent\":\"$FR_KY\",\"scope\":\"$SC\",\"props\":{\"color\":\"#FFC8DD\"}}" | jid)
b typeslow $GG 10 "奈良喂小鹿 🦌" >/dev/null; sleep 1.6
h flyto $NUM 160 1.4; sleep 1.8; mark numbers; dbl $NUM; sleep 1.2                 # into the real Numbers
F=($(frame Numbers 旅行预算)); isfront Numbers && { $drive click $((F[1] + 333)) $((F[2] + 191)); sleep 0.6; $drive key 53; sleep 0.3; $drive typeu 60 "4"; sleep 0.3; $drive key 36; }; sleep 2.2
back Numbers; sleep 1.2
h flyto $CALC 140 1.0; sleep 1.4; mark calc; dbl $CALC; sleep 1.2                    # real Calculator: per person
isfront Calculator && { $drive key 53; $drive keys 110 "27200/3="; }; sleep 0.9
back Calculator; sleep 0.6
mto $CALC 0.3 0.8 0.6; m chat 14 "每人九千多，可以！" >/dev/null; sleep 1.8
h fly 428 217 2.1 1.2; sleep 1.6; mark booking                                         # book the extra night
P=($(h state | python3 -c "import json,sys; o=[o for o in json.load(sys.stdin)['objects'] if o['id']=='$BOOK'][0]; print(o['x']+60, o['y']+40)")); S=($(h screen $P[1] $P[2] | xy)); $drive hover $S[1] $S[2]; sleep 0.8   # hover shows the full address
# Real clicks and typing in the embedded page (page points map onto the surface).
el() { h js $BOOK "var r=document.getElementById('$1').getBoundingClientRect(); (r.x+r.width/2)+','+(r.y+r.height/2)" | python3 -c "import json,sys; x,y=json.load(sys.stdin)['result'].split(','); print(float(x)/1280, float(y)/860)"; }
dbl $BOOK; sleep 0.8
E=($(el out)); P=($(wpt $BOOK $E[1] $E[2])); S=($(h screen $P[1] $P[2] | xy)); $drive click $S[1] $S[2]; sleep 0.3; $drive key 0 cmd; $drive typeu 80 "2026-04-16"; sleep 0.6
E=($(el book)); P=($(wpt $BOOK $E[1] $E[2])); S=($(h screen $P[1] $P[2] | xy)); $drive click $S[1] $S[2]; sleep 1.6
h deactivate >/dev/null; h liveshare $BOOK >/dev/null; h liveshare $BOOK >/dev/null; sleep 0.6
P=($(wpt $BOOK 0.5 0.5)); S=($(h screen $P[1] $P[2] | xy)); isfront CanvasWorkspace && $drive click $S[1] $S[2]; sleep 0.3
isfront CanvasWorkspace && $drive key 15 cmd,shift; sleep 0.6
R=($(h js $BOOK "var r=document.getElementById('ok').getBoundingClientRect(); [(r.x-12)/1280,(r.y-12)/860,(r.right+12)/1280,(r.bottom+12)/860].join(' ')" | python3 -c "import json,sys; print(json.load(sys.stdin)['result'])"))
A=($(wpt $BOOK $R[1] $R[2])); B=($(wpt $BOOK $R[3] $R[4])); SA=($(h screen $A[1] $A[2] | xy)); SB=($(h screen $B[1] $B[2] | xy))
isfront CanvasWorkspace && $drive drag $SA[1] $SA[2] $SB[1] $SB[2] 200 100; sleep 2.4
CONF=$(h state | python3 -c "import json,sys; print([o['id'] for o in json.load(sys.stdin)['objects'] if o['kind']=='image'][-1])"); h move $CONF 0 0 $FR_KY >/dev/null
# 妈妈 stops following and looks at Tokyo on her own while 小安 keeps editing.
mark unfollow; m follow >/dev/null; m 'fly -1560 -520 0.85 1.2' >/dev/null; mxy -1700 -560 1.1
m chat 14 "我去看看东京那边" >/dev/null; sleep 1.2; m 'fly -1560 -330 0.85 2.4' >/dev/null; mxy -1450 -380 2.2; sleep 2.6
# 妈妈 operates 小安's Numbers remotely; as an editor she gets control at once and her input runs on 小安's Mac.
m 'fly 320 -460 1.05 1.2' >/dev/null; mto $NUM 0.5 0.6 1.1; sleep 0.4
m chat 14 "东京酒店应该住3晚，我来改" >/dev/null; sleep 1.2
mark control; m requestcontrol $NUM >/dev/null; sleep 1.2
sleep 1.6                                                                             # editors get control without a prompt
cell() { m input $NUM $1 0.264 0.248 >/dev/null; }
mto $NUM 0.264 0.248 0.6; cell move; sleep 0.4; cell down; cell up; sleep 0.5; m input $NUM key 0 0 53 >/dev/null; sleep 0.3; m input $NUM text 0 0 3 >/dev/null; sleep 0.4; m input $NUM key 0 0 36 >/dev/null
sleep 2; m chat 14 "改好了 👌" >/dev/null; sleep 1.2
m 'fly -780 -120 0.62 2.4' >/dev/null; mto $ROUTE 0.5 0.4 2.2                          # then she looks over the route and notes
h reclaim $NUM >/dev/null; back Numbers; sleep 1.2
h fly -620 -40 0.52 1.4; sleep 1.6
h select $(h state | python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(o['id'] for o in d['objects'] if o.get('parent')=='$FR_KY' and o['kind'] in ('image','sticky','app')))") >/dev/null
mark copy; isfront CanvasWorkspace && $drive key 8 cmd,opt; sleep 0.8                # real ⌥⌘C: copy as one image
chat() { local S=($(h screen $1 $2 | xy)); isfront CanvasWorkspace && { $drive hover $S[1] $S[2]; $drive key 44; sleep 0.3; $drive typeu 60 "$3"; sleep 0.4; $drive key 36; }; }
chat -700 -150 "妈妈，我把行程放进行程单了，您看看"; sleep 0.6
m follow $HOST_ID >/dev/null; m chat 14 "好，我看看" >/dev/null                          # 妈妈 follows to the document
h flyto $PAGES 120 1.6; sleep 1.6; mto $PAGES 0.3 0.4 0.8; mark pages; dbl $PAGES; sleep 1.4   # into the real Pages
F=($(frame Pages 日本行程)); isfront Pages && { $drive click $((F[1] + 300)) $((F[2] + F[4] - 60)); sleep 0.4; $drive key 125 cmd; sleep 0.3; $drive key 36; $drive key 9 cmd; }; sleep 2   # real ⌘V at the end
isfront Pages && $drive key 1 cmd; sleep 0.6                                        # real ⌘S
mto $PAGES 0.35 0.6 1.2; m chat 14 "行程单很清楚，打印出来带着走" >/dev/null; sleep 1.6    # 妈妈 reads the itinerary
isfront Pages && $drive key 35 cmd; sleep 3                                         # print preview
isfront Pages && $drive key 53; sleep 1
mark pages-back; back Pages; sleep 1.2
h fit >/dev/null; h fly -700 -40 0.3 0.01 >/dev/null; sleep 0.2; h 'fly 250 -60 0.33 2' >/dev/null; sleep 3; mark end   # pull back
if (( REC > 0 )); then wait $REC_PID; fi
# Close everything the take opened.
pkill -f 'http.server 8765'; pkill -f 'CanvasWorkspace.*--profile (trip|mama|gege)'; for a in Numbers Pages Preview Maps Weather Calculator; do pkill -x $a; done
echo "done: $W/demo.mov"
