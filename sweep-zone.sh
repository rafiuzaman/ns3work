#!/bin/bash
#
# sweep-zone.sh -- how much of the hybrid mechanism's advantage depends on the
# advertisement zone radius?
#
# WHY THIS EXPERIMENT EXISTS
# --------------------------
# The paper's headline claim is that the hybrid mechanism matches the delivery
# of the proactive mechanism at substantially lower control overhead. That
# result was obtained with the advertisement zone fixed at three hops, which is
# the value used in Hamidian's original study.
#
# The obvious objection is that three hops may cover most of the network in the
# scenarios simulated, in which case hybrid is simply behaving like a cheaper
# proactive mechanism and the advantage is an artefact of the topology rather
# than a property of the mechanism. If that were so, the advantage should
# disappear as the zone shrinks: at one hop, only the gateways' immediate
# neighbours are covered and almost every node must solicit, so hybrid should
# converge towards reactive behaviour and cost.
#
# This sweep tests that directly. It varies the zone radius from one to five
# hops in both scenarios and reports, for each, the delivery, the gateway
# availability, the control overhead, and the split of that overhead between
# advertisement and solicitation. That last column is the diagnostic: it shows
# how the mechanism's character shifts from advertisement-driven to
# solicitation-driven as the zone contracts.
#
# The proactive and reactive mechanisms are run once per scenario as reference
# lines, since neither has an advertisement zone.
#
# RESUME
# ------
# This script is resumable. Every completed run is appended to the CSV
# immediately, and on start-up the script reads back whatever is already there
# and skips those runs. If the machine sleeps, loses power or is interrupted
# with Ctrl-C, just run the same command again: only the runs that are actually
# missing are executed, and at most one in-flight run is lost.
#
# That also means you can sample cheaply first and refine later. Run it with
# three seeds to see the trend in about forty-five minutes, then run it again
# with five; the first three seeds are kept and only seeds 4 and 5 are added.
#
# Usage:
#   bash sweep-zone.sh [seeds]        # default 5
#
# Cost from cold: with five seeds, 5 radii x 2 scenarios x 5 seeds = 50 hybrid
# runs plus 20 reference runs. At roughly 60 s and 90 s per run for the two
# scenarios that is about 75 minutes in total.

set -u

SEEDS="${1:-5}"

NS3DIR=~/ns-allinone-3.48/ns-3.48
OUTDIR=~/ns3work-sync
SCRATCH=$(mktemp -d)

# Held at the mid-range speed so that the zone radius is the only variable.
SPEED=3
PAUSE=60
SIMTIME=900
SOURCES=5
RANGE=250
PKTSIZE=512
CBRRATE=5
ADVINTERVAL=5
ENTRYLIFE=15

ZONES="1 2 3 4 5"

OUT="$OUTDIR/zone-sweep.csv"
HEADER="mode,nodes,gateways,sources,area,range,speedMin,speedMax,pause,simTime,advInterval,advZone,entryLifetime,packetSize,cbrRate,seed,offered,sent,relayed,received,pdr,txPdr,gwAvail,delay_ms,noGateway,advSent,advFwd,solSent,solFwd,replies,control,gw0,gw1,malicious,droppedByMalicious,areaHeight"

mkdir -p "$OUTDIR"

# ---------------------------------------------------------------- resume set
# A run is identified by mode, node count, zone radius and seed: fields 1, 2,
# 12 and 16 of the CSV. Anything already present is not run again.
DONE="$SCRATCH/done.txt"
: > "$DONE"

if [ -f "$OUT" ]; then
    if [ "$(head -1 "$OUT")" != "$HEADER" ]; then
        BAK="$OUT.$(date +%Y%m%d-%H%M%S).bak"
        echo "Existing $OUT has a different header; moving it to $BAK"
        mv "$OUT" "$BAK"
        echo "$HEADER" > "$OUT"
    else
        # Drop any truncated final line -- a run killed mid-write.
        FIELDS=$(echo "$HEADER" | awk -F, '{print NF}')
        awk -F, -v n="$FIELDS" 'NR==1 || NF==n' "$OUT" > "$SCRATCH/clean.csv"
        if [ "$(wc -l < "$SCRATCH/clean.csv")" != "$(wc -l < "$OUT")" ]; then
            echo "Discarding a truncated final row from $OUT"
        fi
        cp "$SCRATCH/clean.csv" "$OUT"
        awk -F, 'NR>1 {print $1","$2","$12","$16}' "$OUT" | sort -u > "$DONE"
        echo "Resuming: $(wc -l < "$DONE" | tr -d ' ') runs already on file in $OUT"
    fi
else
    echo "$HEADER" > "$OUT"
fi

cd "$NS3DIR" || { echo "cannot cd to $NS3DIR"; exit 1; }

SKIPPED=0
RAN=0

run_one () {
    local mode="$1" nodes="$2" gw="$3" area="$4" areah="$5" zone="$6" seed="$7" label="$8"

    if grep -qx "$mode,$nodes,$zone,$seed" "$DONE" 2>/dev/null; then
        SKIPPED=$((SKIPPED + 1))
        printf "%-44s already done\n" "$label"
        return
    fi

    local f="$SCRATCH/${mode}_${nodes}_${zone}_${seed}.txt"
    printf "%-44s " "$label"

    ./ns3 run "scratch/gateway-discovery \
               --mode=$mode \
               --numManetNodes=$nodes --numGateways=$gw --numSources=$SOURCES \
               --areaSize=$area --areaHeight=$areah --range=$RANGE \
               --nodeSpeedMin=$SPEED --nodeSpeedMax=$SPEED --pauseTime=$PAUSE \
               --simTime=$SIMTIME \
               --advInterval=$ADVINTERVAL --advZone=$zone \
               --entryLifetime=$ENTRYLIFE \
               --packetSize=$PKTSIZE --cbrRate=$CBRRATE \
               --RngRun=$seed" > "$f" 2>&1

    if grep -q "^RESULT," "$f"; then
        row=$(grep "^RESULT," "$f" | sed 's/^RESULT,//')
        # Append and flush before printing, so an interruption immediately
        # after this point still leaves the run recorded.
        echo "$row" >> "$OUT"
        sync
        echo "$mode,$nodes,$zone,$seed" >> "$DONE"
        RAN=$((RAN + 1))
        pdr=$(echo "$row" | cut -d, -f21)
        ctrl=$(echo "$row" | cut -d, -f31)
        adv=$(echo "$row" | cut -d, -f27)
        sol=$(echo "$row" | cut -d, -f29)
        printf "PDR %6s%%  ctrl %6s  (advFwd %5s / solFwd %5s)\n" "$pdr" "$ctrl" "$adv" "$sol"
    else
        echo "FAILED (see $f)"
    fi
}

for sc in 1 2; do
    if [ "$sc" = "1" ]; then N=15; G=2; A=800;  AH=500;  else N=25; G=3; A=1000; AH=1000; fi
    echo
    echo "### Scenario $sc: $N nodes, $G gateways, ${A}x${AH} m ###"
    echo

    for z in $ZONES; do
        for seed in $(seq 1 "$SEEDS"); do
            run_one hybrid "$N" "$G" "$A" "$AH" "$z" "$seed" "[S$sc] hybrid zone=$z seed=$seed"
        done
    done

    echo
    for seed in $(seq 1 "$SEEDS"); do
        run_one proactive "$N" "$G" "$A" "$AH" 3 "$seed" "[S$sc] proactive (reference) seed=$seed"
    done
    for seed in $(seq 1 "$SEEDS"); do
        run_one reactive "$N" "$G" "$A" "$AH" 3 "$seed" "[S$sc] reactive (reference) seed=$seed"
    done
done

echo
echo "Wrote $OUT  ($RAN run this time, $SKIPPED already on file)"
echo

TOTAL=$(( (5 * SEEDS + 2 * SEEDS) * 2 ))
HAVE=$(( $(wc -l < "$OUT") - 1 ))
if [ "$HAVE" -lt "$TOTAL" ]; then
    echo "NOTE: $HAVE of $TOTAL runs are on file. The sweep is incomplete --"
    echo "      run the same command again to fill in the rest."
    echo
fi

echo "Hybrid against zone radius, with the two reference mechanisms:"
awk -F, 'NR>1 {
    key=$2","$1","$12
    pdr[key]+=$21; av[key]+=$23; ctrl[key]+=$31; advf[key]+=$27; solf[key]+=$29; c[key]++
}
END {
    printf "%6s %-10s %6s %9s %10s %10s %10s %10s %6s\n", \
           "nodes","mode","zone","PDR%","gwAvail%","control","advFwd","solFwd","seeds"
    for (k in c) { split(k,p,",")
        printf "%6s %-10s %6s %9.2f %10.2f %10.1f %10.1f %10.1f %6d\n", \
               p[1], p[2], (p[2]=="hybrid" ? p[3] : "-"), \
               pdr[k]/c[k], av[k]/c[k], ctrl[k]/c[k], advf[k]/c[k], solf[k]/c[k], c[k] }
}' "$OUT" | sort -k1,1n -k2,2 -k3,3n

echo
echo "Read the advFwd / solFwd columns together: as the zone shrinks, the"
echo "mechanism should shift from advertisement-driven to solicitation-driven."
echo "If the total control overhead rises to meet the reactive reference as the"
echo "zone approaches one hop, the hybrid advantage is a function of the zone"
echo "covering the network, and the paper must say so."
echo
echo "To share: cd ~/ns3work-sync && git add zone-sweep.csv && git commit -m 'Zone radius sweep' && git push"
