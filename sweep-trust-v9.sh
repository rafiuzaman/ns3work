#!/bin/bash
#
# sweep-trust.sh -- evaluation campaign for trust-aware gateway selection.
#
# THE EXPERIMENT
# --------------
# A malicious gateway advertises honestly, accepts traffic, and then silently
# discards a fraction of the payload it was trusted to relay. The discard
# happens on the gateway's WIRED interface, so no node in the ad hoc network
# can overhear it: watchdog and promiscuous-monitoring schemes are blind to
# this attack by construction. The only evidence anywhere in the network is the
# absence of end-to-end delivery.
#
# The trust-aware policy has each source acknowledge-count its own deliveries
# per gateway and refuse gateways whose observed delivery ratio falls below a
# threshold. This sweep asks four questions:
#
#   A. Does it work at all?         baseline vs trust-aware, full dropper
#   B. Can it catch a partial one?  drop fraction 0.1 .. 1.0
#   C. How many can it survive?     1 .. G-1 malicious gateways
#   D. What does the threshold do?  0.1 .. 0.9
#
# Question B is the one reviewers will press on: a gateway dropping everything
# is trivial to spot, and a gateway dropping a tenth of the traffic is nearly
# indistinguishable from ordinary loss. Where the mechanism stops working is
# a result, not a failure, and the paper should report it as such.
#
# RESUME
# ------
# Every completed run is appended immediately and skipped on restart, so an
# interrupted sweep costs one run. Re-running the same command fills the gaps.
#
# Usage:  bash sweep-trust.sh [seeds]        # default 5

set -u
SEEDS="${1:-5}"

NS3DIR=~/ns-allinone-3.48/ns-3.48
OUTDIR=~/ns3work-sync
SCRATCH=$(mktemp -d)
OUT="$OUTDIR/trust-sweep-v9.csv"

# Held fixed so that the variable under test is the only thing moving.
MODE=hybrid
SPEED=3
PAUSE=60
SIMTIME=900
SOURCES=5
RANGE=250
PKTSIZE=512
CBRRATE=5
ADVINTERVAL=5
ADVZONE=3
ENTRYLIFE=15

HEADER="mode,nodes,gateways,sources,area,range,speedMin,speedMax,pause,simTime,advInterval,advZone,entryLifetime,packetSize,cbrRate,seed,offered,sent,relayed,received,pdr,txPdr,gwAvail,delay_ms,noGateway,advSent,advFwd,solSent,solFwd,replies,control,gw0,gw1,malicious,droppedByMalicious,areaHeight,numMaliciousGw,dropFraction,trustAware,trustThreshold,dataViaMalicious,acksSent,acksDelivered"

mkdir -p "$OUTDIR"
DONE="$SCRATCH/done.txt"; : > "$DONE"

if [ -f "$OUT" ] && [ "$(head -1 "$OUT")" = "$HEADER" ]; then
    NF=$(echo "$HEADER" | awk -F, '{print NF}')
    awk -F, -v n="$NF" 'NR==1 || NF==n' "$OUT" > "$SCRATCH/clean.csv"
    if [ "$(awk 'END{print NR}' "$SCRATCH/clean.csv")" != "$(awk 'END{print NR}' "$OUT")" ]; then
        echo "Discarding a truncated final row"
    fi
    cp "$SCRATCH/clean.csv" "$OUT"
    # key: nodes, numMaliciousGw, dropFraction, trustAware, trustThreshold, seed
    awk -F, 'NR>1 {print $2","$37","$38","$39","$40","$16}' "$OUT" | sort -u > "$DONE"
    echo "Resuming: $(wc -l < "$DONE" | tr -d ' ') runs already on file"
else
    [ -f "$OUT" ] && mv "$OUT" "$OUT.$(date +%Y%m%d-%H%M%S).bak"
    echo "$HEADER" > "$OUT"
fi

cd "$NS3DIR" || { echo "cannot cd to $NS3DIR"; exit 1; }
RAN=0; SKIPPED=0

run_one () {
    local N="$1" G="$2" A="$3" AH="$4" nmal="$5" drop="$6" trust="$7" thr="$8" seed="$9" label="${10}"
    local key="$N,$nmal,$drop,$trust,$thr,$seed"
    if grep -qx "$key" "$DONE" 2>/dev/null; then
        SKIPPED=$((SKIPPED+1)); printf "%-52s already done\n" "$label"; return
    fi
    local f="$SCRATCH/run_${N}_${nmal}_${drop}_${trust}_${thr}_${seed}.txt"
    printf "%-52s " "$label"

    ./ns3 run "scratch/gateway-trust-v9 \
               --mode=$MODE \
               --numManetNodes=$N --numGateways=$G --numSources=$SOURCES \
               --areaSize=$A --areaHeight=$AH --range=$RANGE \
               --nodeSpeedMin=$SPEED --nodeSpeedMax=$SPEED --pauseTime=$PAUSE \
               --simTime=$SIMTIME \
               --advInterval=$ADVINTERVAL --advZone=$ADVZONE \
               --entryLifetime=$ENTRYLIFE \
               --packetSize=$PKTSIZE --cbrRate=$CBRRATE \
               --maliciousGw=true --numMaliciousGw=$nmal --dropFraction=$drop \
               --trustAware=$trust --trustThreshold=$thr \
               --trustBeta=0.50 --trustMinSample=10 --solHoldoff=1 \
               --RngRun=$seed" > "$f" 2>&1

    if grep -q "^RESULT," "$f"; then
        row=$(grep "^RESULT," "$f" | sed 's/^RESULT,//')
        echo "$row" >> "$OUT"; sync
        echo "$key" >> "$DONE"; RAN=$((RAN+1))
        pdr=$(echo "$row" | cut -d, -f21)
        viaMal=$(echo "$row" | cut -d, -f41)
        sent=$(echo "$row" | cut -d, -f18)
        printf "PDR %6s%%   entrusted to attacker %6s/%s\n" "$pdr" "$viaMal" "$sent"
    else
        echo "FAILED (see $f)"
    fi
}

for sc in 1 2; do
    if [ "$sc" = "1" ]; then N=15; G=2; A=800; AH=500; else N=25; G=3; A=1000; AH=1000; fi
    echo; echo "##### Scenario $sc: $N nodes, $G gateways #####"

    echo; echo "--- A. does it work: full dropper, baseline vs trust-aware ---"
    for t in false true; do
        for seed in $(seq 1 "$SEEDS"); do
            run_one "$N" "$G" "$A" "$AH" 1 1.0 "$t" 0.5 "$seed" "[S$sc] trust=$t drop=1.0 seed=$seed"
        done
    done

    echo; echo "--- B. partial droppers (the hard case) ---"
    for drop in 0.1 0.25 0.5 0.75; do
        for t in false true; do
            for seed in $(seq 1 "$SEEDS"); do
                run_one "$N" "$G" "$A" "$AH" 1 "$drop" "$t" 0.5 "$seed" \
                        "[S$sc] trust=$t drop=$drop seed=$seed"
            done
        done
    done

    echo; echo "--- C. more than one attacker ---"
    MAXMAL=$((G-1))
    for nmal in $(seq 1 "$MAXMAL"); do
        for t in false true; do
            for seed in $(seq 1 "$SEEDS"); do
                run_one "$N" "$G" "$A" "$AH" "$nmal" 1.0 "$t" 0.5 "$seed" \
                        "[S$sc] trust=$t nmal=$nmal seed=$seed"
            done
        done
    done

    echo; echo "--- D. threshold sensitivity (trust-aware only) ---"
    for thr in 0.1 0.3 0.7 0.9; do
        for seed in $(seq 1 "$SEEDS"); do
            run_one "$N" "$G" "$A" "$AH" 1 0.5 true "$thr" "$seed" \
                    "[S$sc] thr=$thr drop=0.5 seed=$seed"
        done
    done
done

echo
echo "Wrote $OUT  ($RAN this time, $SKIPPED already on file)"
echo
echo "Headline comparison -- share of payload handed to the attacker:"
awk -F, 'NR>1 {
    k=$2","$39","$38
    pdr[k]+=$21; via[k]+=$41; sent[k]+=$18; c[k]++
}
END {
    printf "%6s %8s %8s %10s %14s %8s\n","nodes","trust","drop","PDR%","toAttacker%","runs"
    for (k in c) { split(k,p,",")
        printf "%6s %8s %8s %10.2f %14.2f %8d\n", p[1], p[2]=="1"?"yes":"no", p[3],
               pdr[k]/c[k], sent[k] ? 100*via[k]/sent[k] : 0, c[k] }
}' "$OUT" | sort -k1,1n -k3,3n -k2,2

echo
echo "The number to watch is toAttacker%. Delivery alone understates the"
echo "mechanism: what matters is how much payload was entrusted to a gateway"
echo "that discarded it, and how quickly the sources stopped doing so."
