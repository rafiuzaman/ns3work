#!/usr/bin/env bash
# ==========================================================================
# run.sh -- one runner for every ns-2 experiment (Papers A, B, C)
#
# The grid is set with environment variables; anything not set uses the
# default shown. Examples:
#
#   # quick validation: 1 run per model, keep traces
#   SEEDS="1" NODES="50" RATES="64" KEEP=1 ./run.sh
#
#   # Paper A (load x mobility), AODV/DSDV/OLSR, 10 seeds, 2 CPU cores
#   PROTOS="AODV DSDV OLSR" RATES="64 128" SPEEDS="1-3 1-20" JOBS=2 ./run.sh
#
#   # Paper C (temporal events), AODV only, event log on
#   PROTOS="AODV" NODES="50 100" RATES="128" EVENTS=1 OUT=results/paperC.csv ./run.sh
#
# Output: one CSV row per run (no averaging here -- use summarize.awk).
# Resumable: runs already present in $OUT are skipped, so re-running the same
# command after an interruption only fills the gaps.
# ==========================================================================

cd "$(dirname "$0")"

PROTOS=${PROTOS:-"AODV"}
MODELS=${MODELS:-"RWP RD GM"}
NODES=${NODES:-"25 50 75 100 125"}
SEEDS=${SEEDS:-"1 2 3 4 5 6 7 8 9 10"}
RATES=${RATES:-"64 128"}          # per-flow CBR rate, kbps
SPEEDS=${SPEEDS:-"1-3"}           # vmin-vmax in m/s, space-separated list
PAUSE=${PAUSE:-0}                 # pause time (s) for RWP and RD
JOBS=${JOBS:-1}                   # parallel runs (<= number of CPU cores)
KEEP=${KEEP:-0}                   # 1 = keep trace files
EVENTS=${EVENTS:-0}               # 1 = also write AODV event log (Paper C)
OUT=${OUT:-results/runs.csv}
EVOUT=${EVOUT:-results/events.csv}
TSTART=20
TSTOP=1000

mkdir -p traces results logs pos "$(dirname "$OUT")"

HEADER="proto,model,nodes,seed,rate_kb,vmin,vmax,pause,sent,recv,pdr,delay,thr_kbps,ctrl,ctrl_bytes,nrl,ctrl_per_node_s,rreq,rrep,rerr,link_fail,lbr,pst,pst_n,pst_censored_n,pst_incl_censored"
[ -f "$OUT" ] || echo "$HEADER" > "$OUT"
if [ "$EVENTS" = "1" ] && [ ! -f "$EVOUT" ]; then
    echo "time,event,node,hop,dst,model,nodes,seed,speed" > "$EVOUT"
fi

run_one() {
    local proto=$1 model=$2 nodes=$3 seed=$4 rate=$5 speed=$6
    local vmin=${speed%-*} vmax=${speed#*-}
    local key="$proto,$model,$nodes,$seed,$rate,$vmin,$vmax,$PAUSE,"
    if grep -q "^$key" "$OUT"; then return 0; fi

    local tag="${proto}_${model}_${nodes}n_s${seed}_${rate}kb_v${speed}_p${PAUSE}"
    local tr="traces/$tag.tr"

    if ! ns mobility.tcl "$proto" "$model" "$nodes" "$seed" "$rate" "$vmin" "$vmax" "$PAUSE" "$tr" \
            > "logs/$tag.log" 2>&1 || [ ! -s "$tr" ]; then
        echo "FAILED $tag (see logs/$tag.log)"
        echo "$tag" >> results/failed.txt
        return 1
    fi

    local m
    m=$(awk -v tstart=$TSTART -v tstop=$TSTOP -v nn="$nodes" -f metrics.awk "$tr" \
        | tr ' ' '\n' | cut -d= -f2 | paste -sd, -)
    ( flock 9; echo "$key$m" >> "$OUT" ) 9>>"$OUT.lock"

    if [ "$EVENTS" = "1" ] && [ "$proto" = "AODV" ]; then
        local tmp="traces/$tag.events"
        awk -v model="$model" -v nodes="$nodes" -v seed="$seed" -v speed="$speed" \
            -f events.awk "$tr" > "$tmp"
        ( flock 9; cat "$tmp" >> "$EVOUT" ) 9>>"$EVOUT.lock"
        rm -f "$tmp"
    fi

    # node positions are small: always keep them (gzipped) for the
    # geometric link-break analysis; traces are only kept with KEEP=1
    gzip -c "$tr.pos" > "pos/$tag.pos.gz"
    if [ "$KEEP" = "1" ]; then
        awk -f check_movement.awk "$tr.pos" > "logs/$tag.movement" 2>&1
    else
        rm -f "$tr" "$tr.pos"
    fi
    echo "done   $tag"
}
export -f run_one
export OUT EVOUT EVENTS KEEP PAUSE TSTART TSTOP

# build the job list, then run JOBS at a time.
# Seed is the OUTER loop: the whole grid is done for seed 1, then seed 2, ...
# so a campaign stopped early still has complete grids with fewer seeds.
JOBLIST=$(mktemp)
for seed in $SEEDS; do for proto in $PROTOS; do for model in $MODELS; do
for nodes in $NODES; do for rate in $RATES; do for speed in $SPEEDS; do
    echo "$proto $model $nodes $seed $rate $speed"
done; done; done; done; done; done > "$JOBLIST"

TOTAL=$(wc -l < "$JOBLIST")
echo "Jobs in grid: $TOTAL  (already done ones are skipped)  parallel: $JOBS"
START=$(date +%s)
xargs -P "$JOBS" -L 1 bash -c 'run_one "$@"' _ < "$JOBLIST"
rm -f "$JOBLIST"

ELAPSED=$(( $(date +%s) - START ))
DONE=$(( $(wc -l < "$OUT") - 1 ))
printf "Finished in %dh %02dm. Rows in %s: %d\n" $((ELAPSED/3600)) $(((ELAPSED%3600)/60)) "$OUT" "$DONE"
[ -f results/failed.txt ] && echo "Some runs failed: see results/failed.txt"
