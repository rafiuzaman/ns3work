#!/bin/bash
#
# sweep-interval.sh -- advertisement-interval sweep, re-run with the corrected
# delivery metric, plus a targeted entry-lifetime experiment.
#
# This supersedes the first interval sweep, whose delivery ratio was computed
# against transmitted packets rather than offered load and therefore reported
# near-perfect delivery for configurations that were in fact delivering under a
# third of the traffic.
#
# Two deliberate economies over the first attempt:
#
#   1. Reactive gateways never advertise, so the advertisement interval has no
#      effect whatsoever on reactive mode -- the first sweep proved this by
#      producing six identical sets of numbers. It is therefore run at a single
#      interval, which reclaims 15 of 54 runs and pays for more seeds.
#
#   2. The entry-lifetime dimension is swept only for proactive mode at the
#      intervals where the cliff appears, rather than across the whole grid.
#
# The lifetime experiment tests a specific prediction. A node can only transmit
# while it holds an unexpired gateway entry, so the achievable send rate should
# be min(1, entryLifetime/advInterval). The first sweep matched that to within
# 2% at five of six points with a fixed 15 s lifetime. If the relation holds,
# doubling the lifetime to 30 s should move the cliff correspondingly -- which
# turns an empirical curve into a validated analytical model.
#
# Usage:
#   bash sweep-interval.sh [seeds]      # default 5

set -u

SEEDS="${1:-5}"

NS3DIR=~/ns-allinone-3.48/ns-3.48
OUTDIR=~/ns3work-sync
SCRATCH=$(mktemp -d)

# Held at the values the earlier baseline sweep identified as the operating
# point where gateway choice genuinely affects the outcome.
NODES=15
GW=2
SOURCES=5
AREA=750
RANGE=250
SIMTIME=200
SPEEDMIN=1
SPEEDMAX=6
PAUSE=2
PKTSIZE=512
CBRRATE=5
ADVZONE=3

INTERVALS="2 5 10 20 40 60"
LIFETIMES="15 30 60"

OUT="$OUTDIR/interval-sweep.csv"
HEADER="mode,nodes,gateways,sources,area,range,speedMin,speedMax,pause,simTime,advInterval,advZone,entryLifetime,packetSize,cbrRate,seed,offered,sent,relayed,received,pdr,txPdr,gwAvail,delay_ms,noGateway,advSent,advFwd,solSent,solFwd,replies,control,gw0,gw1,malicious,droppedByMalicious,areaHeight"
echo "$HEADER" > "$OUT"

cd "$NS3DIR" || { echo "cannot cd to $NS3DIR"; exit 1; }

run_one () {
    local mode="$1" adv="$2" life="$3" seed="$4" label="$5"
    local f="$SCRATCH/${mode}_${adv}_${life}_${seed}.txt"
    printf "%-46s " "$label"

    ./ns3 run "scratch/gateway-discovery \
               --mode=$mode \
               --numManetNodes=$NODES --numGateways=$GW --numSources=$SOURCES \
               --areaSize=$AREA --range=$RANGE \
               --nodeSpeedMin=$SPEEDMIN --nodeSpeedMax=$SPEEDMAX --pauseTime=$PAUSE \
               --simTime=$SIMTIME \
               --advInterval=$adv --advZone=$ADVZONE \
               --entryLifetime=$life \
               --packetSize=$PKTSIZE --cbrRate=$CBRRATE \
               --RngRun=$seed" > "$f" 2>&1

    if grep -q "^RESULT," "$f"; then
        # Strip the tag once, then index against the CSV header. Cutting the
        # tagged line directly shifts every field by one.
        local row=$(grep "^RESULT," "$f" | sed 's/^RESULT,//')
        echo "$row" >> "$OUT"
        local pdr=$(echo "$row" | cut -d, -f21)
        local avail=$(echo "$row" | cut -d, -f23)
        local ctrl=$(echo "$row" | cut -d, -f31)
        printf "PDR %6s%%  avail %6s%%  ctrl %5s\n" "$pdr" "$avail" "$ctrl"
    else
        echo "FAILED (see $f)"
    fi
}

echo "Part 1: advertisement interval, proactive and hybrid, lifetime 15 s"
echo
for mode in proactive hybrid; do
    for adv in $INTERVALS; do
        for seed in $(seq 1 "$SEEDS"); do
            run_one "$mode" "$adv" 15 "$seed" "[1] $mode adv=$adv seed=$seed"
        done
    done
done

echo
echo "Part 2: reactive (interval-independent, so run once)"
echo
for seed in $(seq 1 "$SEEDS"); do
    run_one reactive 5 15 "$seed" "[2] reactive seed=$seed"
done

echo
echo "Part 3: entry lifetime, proactive, at the intervals where the cliff appears"
echo
for life in $LIFETIMES; do
    for adv in 20 40 60; do
        for seed in 1 2 3; do
            run_one proactive "$adv" "$life" "$seed" "[3] proactive adv=$adv life=$life seed=$seed"
        done
    done
done

echo
echo "Wrote $OUT"
echo

echo "Part 1+2 -- delivery and overhead vs advertisement interval (lifetime 15 s):"
awk -F, 'NR>1 && $13==15 {
    k=$1","$11
    pdr[k]+=$21; av[k]+=$23; ctrl[k]+=$31; dly[k]+=$24; c[k]++
}
END {
    printf "%-10s %5s %9s %10s %10s %10s\n","mode","adv","PDR%","gwAvail%","delay_ms","control"
    for (k in c) { split(k,p,",")
        printf "%-10s %5s %9.2f %10.2f %10.2f %10.1f\n", p[1],p[2],pdr[k]/c[k],av[k]/c[k],dly[k]/c[k],ctrl[k]/c[k] }
}' "$OUT" | sort -k1,1 -k2,2n

echo
echo "Part 3 -- does gateway availability follow min(1, lifetime/interval)?"
awk -F, 'NR>1 && $1=="proactive" {
    k=$13","$11
    av[k]+=$23; c[k]++
}
END {
    printf "%10s %10s %12s %12s %8s\n","lifetime","interval","predicted%","observed%","ratio"
    for (k in c) { split(k,p,",")
        life=p[1]+0; adv=p[2]+0
        pred = (life/adv > 1) ? 100 : 100*life/adv
        obs = av[k]/c[k]
        printf "%10s %10s %12.1f %12.2f %8.3f\n", p[1], p[2], pred, obs, obs/pred }
}' "$OUT" | sort -k1,1n -k2,2n

echo
echo "To share: cd ~/ns3work-sync && git add interval-sweep.csv && git commit -m 'Corrected interval sweep' && git push"
