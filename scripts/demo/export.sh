#!/bin/zsh
# Cuts a director take into a shareable clip: scripts/demo/export.sh <work-dir> <out.mp4>
# Drops the pre-roll, the gap between quitting and resuming (the desktop shows other windows then),
# and single-frame flashes where the recorder composited the desktop through the canvas.
set -eu
W=$1; OUT=$2
exec python3 - "$W" "$OUT" <<'PY'
import re, subprocess, sys
w, out = sys.argv[1], sys.argv[2]
mov = f"{w}/demo.mov"
marks = dict(l.split() for l in open(f"{w}/marks"))
s, q, r, e = (float(marks[k]) for k in ("start", "quit", "resumed", "end"))

def scene_changes():
    log = subprocess.run(["ffmpeg", "-v", "error", "-i", mov, "-vf", "scale=320:-1,select='gt(scene,0.08)',metadata=print:file=-",
                          "-an", "-f", "null", "-"], capture_output=True, text=True).stdout
    return [float(t) for t in re.findall(r"pts_time:([\d.]+)", log)]

def psnr(t0, t1):
    err = subprocess.run(["ffmpeg", "-ss", f"{t0}", "-i", mov, "-ss", f"{t1}", "-i", mov, "-frames:v", "1",
                          "-lavfi", "[0:v]scale=320:-1[a];[1:v]scale=320:-1[b];[a][b]psnr", "-f", "null", "-"], capture_output=True, text=True).stderr
    m = re.search(r"average:([\d.]+|inf)", err)
    return float("inf") if not m or m.group(1) == "inf" else float(m.group(1))

# A flash is a burst of changes shorter than 0.2 s after which the picture is what it was before.
cuts, burst = [], []
for t in scene_changes() + [1e9]:
    if burst and t - burst[-1] > 0.15:
        a, b = burst[0] - 0.04, burst[-1] + 0.04
        if len(burst) > 1 and b - a < 0.3 and psnr(a, b) > 30:
            cuts.append((a, b))
        burst = []
    burst.append(t)
cuts = [c for c in cuts if s < c[0] < q or r < c[0] < e]
print("flashes removed at:", ", ".join(f"{a:.2f}s" for a, _ in cuts) or "none")

def pieces(lo, hi):
    out, cur = [], lo
    for a, b in cuts:
        if lo < a < hi:
            out.append((cur, a)); cur = b
    return out + [(cur, hi)]

segs = pieces(s, q + 0.4)
tail = pieces(r, e)
f, labels = [], []
for i, (a, b) in enumerate(segs + tail):
    f.append(f"[0:v]trim={a}:{b},setpts=PTS-STARTPTS,fps=60,format=yuv420p[p{i}]")
    labels.append(f"[p{i}]")
n1 = len(segs)
f.append("".join(labels[:n1]) + f"concat=n={n1}:v=1[a]")
f.append("".join(labels[n1:]) + f"concat=n={len(tail)}:v=1[b]")
dur_a = sum(b - a for a, b in segs)
f.append(f"[a][b]xfade=transition=fade:duration=0.4:offset={dur_a - 0.4}[v]")
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", mov, "-filter_complex", ";".join(f), "-map", "[v]",
                "-c:v", "libx264", "-crf", "18", "-preset", "slow", "-movflags", "+faststart", out], check=True)
print("wrote", out)
PY
