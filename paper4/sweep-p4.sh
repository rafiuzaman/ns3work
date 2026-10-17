#!/bin/bash
#
# sweep-p4.sh -- Paper4: adaptive (fuzzy, GA-tuned) gateway discovery in Integrated Internet-MANET.
#
# Run inside the Ubuntu VM that has ns-3.48, from the repository checkout:
#   cd ~/ns3work-sync && git pull && git checkout paper4
#   ./paper4/sweep-p4.sh check            # 1 run: build check against the reference numbers
#   ./paper4/sweep-p4.sh smoke            # 4 short runs (240 s) that print the controller trace
#   ./paper4/sweep-p4.sh calib  [JOBS]    # STAGE 1: calibration runs for the GA cost model (80 runs, short)
#   ./paper4/sweep-p4.sh eval   [JOBS]    # STAGE 3: main evaluation (360 runs) -- needs paper4/fz-params.txt
#   ./paper4/sweep-p4.sh large  [JOBS]    # optional: zone sweep at 50 and 100 nodes
# Results go to paper4/results/ (git add / commit / push them when a stage finishes).
#
# Resumable: completed runs are appended to the CSV at once and skipped when the script
# is started again. JOBS (default 1) = simulations in parallel; use 1 on a 1-2 core VM.
#
# Scenarios:
#   S1  20 nodes, 1000 x 600 m,  2 gateways,  5 sources
#   S2  40 nodes, 1200 x 1000 m, 3 gateways,  8 sources
#   S3  50 nodes, 1300 x 1000 m, 4 gateways, 10 sources
#   S4 100 nodes, 2000 x 1300 m, 6 gateways, 20 sources
#
# Configurations in 'eval' (hybrid unless stated; T in s):
#   proactive, reactive                     references (T 5)
#   fixed-k2-T5, fixed-k3-T5                fixed advertisement zone
#   fixed-k2-T14                            fixed zone with the interval at its derived bound (L = 15 s)
#   msc                                     maximal source coverage (adaptMode 4), T 5
#   fuzzy-T                                 interval only (adaptMode 1), k 3
#   fuzzy-k                                 zone only (adaptMode 2), T 5
#   fuzzy-kT                                joint, proposed (adaptMode 3), k0 3, T0 5
# Speeds 1, 3 and 6 m/s for S1 and S2; 3 m/s for S3 and S4. Seeds 11-15 (RngRun). 900 s.
# 'calib': S1 and S2 at 3 m/s, seeds 11-15: hybrid zones 1-5 (T 5) and proactive at T 2, 5, 10.

set -u

WHAT="${1:-eval}"
JOBS="${2:-1}"
SEEDS="${SEEDS:-5}"

NS3DIR="${NS3DIR:-$HOME/ns-allinone-3.48/ns-3.48}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
OUTDIR="${OUTDIR:-$HERE/results}"
PROG=p4-adaptive-gw
SCRATCH=$(mktemp -d)

PAUSE=60
SIMTIME=900
RANGE=250
PKTSIZE=512
CBRRATE=5
ENTRYLIFE=15

# Fuzzy parameters from the GA (written by Claude to paper4/fz-params.txt after the calibration stage).
FZ=""; FZTAG=""
if [ -f "$HERE/fz-params.txt" ]; then
    FZTAG=$(sed -n 1p "$HERE/fz-params.txt"); FZ=$(sed -n 2p "$HERE/fz-params.txt")
fi
FZARGS="--fzTag=default"
[ -n "$FZ" ] && FZARGS="--fz=$FZ --fzTag=$FZTAG"

HEADER="mode,nodes,gateways,sources,area,range,speedMin,speedMax,pause,simTime,advInterval,advZone,entryLifetime,packetSize,cbrRate,seed,offered,sent,relayed,received,pdr,txPdr,gwAvail,delay_ms,noGateway,advSent,advFwd,solSent,solFwd,replies,control,gw0,gw1,malicious,droppedByMalicious,areaHeight,adaptMode,fzTag,meanK,meanT,epochs,kChanges,ctrlEpoch,config"

cd "$NS3DIR" || { echo "cannot cd to $NS3DIR (set NS3DIR=/path/to/ns-3.48)"; exit 1; }
cp "$HERE/$PROG.cc" "scratch/$PROG.cc" || { echo "cannot copy $PROG.cc into $NS3DIR/scratch"; exit 1; }
echo "Building..."
./ns3 build > "$SCRATCH/build.log" 2>&1 || { tail -30 "$SCRATCH/build.log"; echo "BUILD FAILED"; exit 1; }

scen () {   # sets N G A AH SRC for scenario $1
    case "$1" in
        1) N=20;  G=2; A=1000; AH=600;  SRC=5 ;;
        2) N=40;  G=3; A=1200; AH=1000; SRC=8 ;;
        3) N=50;  G=4; A=1300; AH=1000; SRC=10 ;;
        4) N=100; G=6; A=2000; AH=1300; SRC=20 ;;
    esac
}

run_args () {   # $1 scenario, $2 config, $3 speed, $4 seed, $5 simtime -> prints ns-3 arguments
    scen "$1"
    local base="--numManetNodes=$N --numGateways=$G --numSources=$SRC --areaSize=$A --areaHeight=$AH \
--range=$RANGE --nodeSpeedMin=$3 --nodeSpeedMax=$3 --pauseTime=$PAUSE --simTime=$5 \
--entryLifetime=$ENTRYLIFE --solHoldoff=1 --packetSize=$PKTSIZE --cbrRate=$CBRRATE --RngRun=$4"
    case "$2" in
        proactive)    echo "--mode=proactive --advInterval=5 --advZone=3 $base" ;;
        reactive)     echo "--mode=reactive --advInterval=5 --advZone=3 $base" ;;
        fixed-k1-T5)  echo "--mode=hybrid --advInterval=5 --advZone=1 $base" ;;
        fixed-k2-T5)  echo "--mode=hybrid --advInterval=5 --advZone=2 $base" ;;
        fixed-k3-T5)  echo "--mode=hybrid --advInterval=5 --advZone=3 $base" ;;
        fixed-k4-T5)  echo "--mode=hybrid --advInterval=5 --advZone=4 $base" ;;
        fixed-k5-T5)  echo "--mode=hybrid --advInterval=5 --advZone=5 $base" ;;
        fixed-k2-T14) echo "--mode=hybrid --advInterval=14 --advZone=2 $base" ;;
        pro-T2)       echo "--mode=proactive --advInterval=2 --advZone=3 $base" ;;
        pro-T5)       echo "--mode=proactive --advInterval=5 --advZone=3 $base" ;;
        pro-T10)      echo "--mode=proactive --advInterval=10 --advZone=3 $base" ;;
        msc)          echo "--mode=hybrid --advInterval=5 --advZone=3 --adaptMode=4 --fzTag=msc $base" ;;
        fuzzy-T)      echo "--mode=hybrid --advInterval=5 --advZone=3 --adaptMode=1 $FZARGS $base" ;;
        fuzzy-k)      echo "--mode=hybrid --advInterval=5 --advZone=3 --adaptMode=2 $FZARGS $base" ;;
        fuzzy-kT)     echo "--mode=hybrid --advInterval=5 --advZone=3 --adaptMode=3 $FZARGS $base" ;;
        *) echo "unknown config $2" >&2; return 1 ;;
    esac
}

# ---------------------------------------------------------------- check / smoke
if [ "$WHAT" = "check" ]; then
    # Reference run (hybrid, S1, zone 1, seed 1) -> PDR 96.4741, control 3294 on the cloud build.
    ./ns3 run --no-build "scratch/$PROG --mode=hybrid --numManetNodes=15 --numGateways=2 --numSources=5 \
        --areaSize=800 --areaHeight=500 --range=250 --nodeSpeedMin=3 --nodeSpeedMax=3 --pauseTime=60 \
        --simTime=900 --advInterval=5 --advZone=1 --entryLifetime=15 --solHoldoff=1 --packetSize=512 \
        --cbrRate=5 --RngRun=1" | grep "^RESULT" | cut -d, -f22,32
    echo "expected:  96.4741,3294   (if equal, this machine reproduces the reference build)"
    exit 0
fi
if [ "$WHAT" = "smoke" ]; then
    for cfg in msc fuzzy-T fuzzy-k fuzzy-kT; do
        echo "### $cfg"
        ./ns3 run --no-build "scratch/$PROG $(run_args 2 $cfg 3 11 240) --trace=1" | grep -E "^EPOCH|^Adaptive|^RESULT"
    done
    echo "EPOCH columns: time, gateway, sources, solicitations, SR, SRin, h90, hmax, M, dk, k, T"
    exit 0
fi

# ---------------------------------------------------------------- job lists
JOBLIST="$SCRATCH/jobs.txt"; : > "$JOBLIST"
if [ "$WHAT" = "calib" ]; then
    OUT="$OUTDIR/p4-calib2.csv"
    for seed in $(seq 11 $((10 + SEEDS))); do for sc in 1 2; do
        for cfg in fixed-k1-T5 fixed-k2-T5 fixed-k3-T5 fixed-k4-T5 fixed-k5-T5 pro-T2 pro-T5 pro-T10; do
            echo "$sc $cfg 3 $seed" >> "$JOBLIST"; done; done; done
elif [ "$WHAT" = "large" ]; then
    OUT="$OUTDIR/p4-large.csv"
    for sc in 3 4; do for seed in $(seq 11 13); do
        for cfg in fixed-k1-T5 fixed-k2-T5 fixed-k3-T5 fixed-k4-T5 fixed-k5-T5 proactive reactive; do
            echo "$sc $cfg 3 $seed" >> "$JOBLIST"; done; done; done
elif [ "$WHAT" = "eval" ]; then
    [ -n "$FZ" ] || { echo "paper4/fz-params.txt is missing: run 'calib', push the results, and wait for the GA parameters"; exit 1; }
    OUT="$OUTDIR/p4-eval.csv"
    CFGS="fuzzy-kT fixed-k2-T5 fixed-k3-T5 fixed-k2-T14 msc fuzzy-T fuzzy-k proactive reactive"
    for seed in $(seq 11 $((10 + SEEDS))); do
        for sc in 1 2; do for v in 1 3 6; do for cfg in $CFGS; do echo "$sc $cfg $v $seed" >> "$JOBLIST"; done; done; done
        for sc in 3 4; do for cfg in $CFGS; do echo "$sc $cfg 3 $seed" >> "$JOBLIST"; done; done
    done
else
    echo "unknown action $WHAT (check | smoke | calib | eval | large)"; exit 1
fi

mkdir -p "$OUTDIR"
DONE="$SCRATCH/done.txt"; : > "$DONE"
if [ -f "$OUT" ] && [ "$(head -1 "$OUT")" = "$HEADER" ]; then
    FIELDS=$(echo "$HEADER" | awk -F, '{print NF}')
    awk -F, -v n="$FIELDS" 'NR==1 || NF==n' "$OUT" > "$SCRATCH/clean.csv" && cp "$SCRATCH/clean.csv" "$OUT"
    awk -F, 'NR>1 {print $44","$2","$8","$16}' "$OUT" | sort -u > "$DONE"
    echo "Resuming: $(wc -l < "$DONE" | tr -d ' ') runs already in $OUT"
else
    [ -f "$OUT" ] && mv "$OUT" "$OUT.$(date +%Y%m%d-%H%M%S).bak"
    echo "$HEADER" > "$OUT"
fi
TOTAL=$(wc -l < "$JOBLIST")
echo "$TOTAL runs in the plan, $JOBS in parallel. Output: $OUT"

one () {   # $1 scenario $2 config $3 speed $4 seed
    scen "$1"
    if grep -qx "$2,$N,$3,$4" "$DONE"; then return; fi
    local f="$SCRATCH/$1_$2_$3_$4.txt"
    local t0=$(date +%s)
    ./ns3 run --no-build "scratch/$PROG $(run_args "$1" "$2" "$3" "$4" $SIMTIME)" > "$f" 2>&1
    if grep -q "^RESULT," "$f"; then
        local row="$(grep "^RESULT," "$f" | sed 's/^RESULT,//'),$2"
        ( flock 9; echo "$row" >> "$OUT"; sync ) 9>"$OUT.lock"
        printf "[S%s] %-13s v=%s seed=%s  PDR %6s  ctrl %6s  k %5s  T %5s  (%ss)\n" "$1" "$2" "$3" "$4" \
            "$(echo "$row" | cut -d, -f21)" "$(echo "$row" | cut -d, -f31)" \
            "$(echo "$row" | cut -d, -f39 | cut -c1-5)" "$(echo "$row" | cut -d, -f40 | cut -c1-5)" "$(( $(date +%s) - t0 ))"
    else
        echo "[S$1] $2 v=$3 seed=$4 FAILED (see $f)"
    fi
}

while read -r sc cfg v seed; do
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
    one "$sc" "$cfg" "$v" "$seed" &
done < "$JOBLIST"
wait

HAVE=$(( $(wc -l < "$OUT") - 1 ))
echo
echo "$HAVE of $TOTAL runs on file in $OUT. Run the same command again to fill any gaps."
echo "To share:  cd $HERE/.. && git add paper4/results/$(basename "$OUT") && git commit -m 'Paper4 $(basename "$OUT" .csv)' && git push origin paper4"
