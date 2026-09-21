#!/bin/bash
#
# sweep-speed.sh -- node-speed sweep, following the conventions used throughout
# this line of work: node speed on the x-axis, one scenario per node count,
# 900 s runs, 60 s pause time, five CBR sources.
#
# This is the sweep whose figures go into the paper as
#   "Packet Delivery Ratio vs Mobile Node Speed"
#   "Control Overhead vs Mobile Node Speed"
#   "Average End-to-End Delay vs Mobile Node Speed"
# one figure per metric per scenario, three curves per figure (one per
# discovery mechanism).
#
# Usage:
#   bash sweep-speed.sh <scenario> [seeds]
#
#   scenario : 1  -> 15 nodes, 2 gateways, 800x500     (sparse)
#              2  -> 25 nodes, 3 gateways, 1000x1000   (moderate)
#              3  -> 50 nodes, 5 gateways, 1200x1200   (dense)
#   seeds    : number of RNG runs per point, default 3
#
# Run scenario 1 on one machine and scenario 2 on the other to halve the
# wall-clock. Results land in a scenario-specific CSV so the two can simply be
# concatenated afterwards.

set -u

SCENARIO="${1:-1}"
SEEDS="${2:-3}"

NS3DIR=~/ns-allinone-3.48/ns-3.48
OUTDIR=~/ns3work-sync
SCRATCH=$(mktemp -d)

# Scenario geometry follows the published convention in this line of work.
# Note that scenario 1 is NOT square: 800 x 500 m is the field used for the
# fifteen-node case in the prior papers and in Hamidian's original study.
# Running it as 800 x 800 would make the area 60% larger and the network
# correspondingly sparser, which is a different experiment.
case "$SCENARIO" in
    1) NODES=15; GW=2; AREA=800;  AREAH=500  ;;
    2) NODES=25; GW=3; AREA=1000; AREAH=1000 ;;
    3) NODES=50; GW=5; AREA=1200; AREAH=1200 ;;
    *) echo "unknown scenario '$SCENARIO' (expected 1, 2 or 3)"; exit 1 ;;
esac

# Fixed parameters -- the house convention, matching the prior published work
# and Hamidian's original study so the comparison is like-for-like.
SIMTIME=900
PAUSE=60
SOURCES=5
RANGE=250
PKTSIZE=512
CBRRATE=5
ADVINTERVAL=5
ADVZONE=3
ENTRYLIFE=15

MODES="proactive reactive hybrid"
SPEEDS="1 2 3 4 5 6"

OUT="$OUTDIR/speed-scenario${SCENARIO}.csv"

echo "mode,nodes,gateways,sources,area,range,speedMin,speedMax,pause,simTime,advInterval,advZone,entryLifetime,packetSize,cbrRate,seed,offered,sent,relayed,received,pdr,txPdr,gwAvail,delay_ms,noGateway,advSent,advFwd,solSent,solFwd,replies,control,gw0,gw1,malicious,droppedByMalicious,areaHeight" > "$OUT"

cd "$NS3DIR" || { echo "cannot cd to $NS3DIR"; exit 1; }

total=0
for m in $MODES; do for s in $SPEEDS; do for r in $(seq 1 "$SEEDS"); do
    total=$((total+1))
done; done; done

echo "Scenario $SCENARIO: $NODES nodes, $GW gateways, ${AREA}x${AREAH} m"
echo "$total runs at simTime=${SIMTIME}s -> writing $OUT"
echo "Started: $(date)"
echo

n=0
started=$(date +%s)
for mode in $MODES; do
  for speed in $SPEEDS; do
    for seed in $(seq 1 "$SEEDS"); do
      n=$((n+1))
      f="$SCRATCH/${mode}_${speed}_${seed}.txt"
      printf "[%3d/%3d] %-9s speed=%s seed=%s ... " "$n" "$total" "$mode" "$speed" "$seed"

      # Speed is held constant rather than drawn from a range, so that the
      # x-axis value means exactly what the figure says it means.
      ./ns3 run "scratch/gateway-discovery \
                 --mode=$mode \
                 --numManetNodes=$NODES --numGateways=$GW --numSources=$SOURCES \
                 --areaSize=$AREA --areaHeight=$AREAH --range=$RANGE \
                 --nodeSpeedMin=$speed --nodeSpeedMax=$speed --pauseTime=$PAUSE \
                 --simTime=$SIMTIME \
                 --advInterval=$ADVINTERVAL --advZone=$ADVZONE \
                 --entryLifetime=$ENTRYLIFE \
                 --packetSize=$PKTSIZE --cbrRate=$CBRRATE \
                 --RngRun=$seed" > "$f" 2>&1

      if grep -q "^RESULT," "$f"; then
          # Strip the tag once, then index against the CSV header. Cutting the
          # tagged line directly shifts every field by one.
          row=$(grep "^RESULT," "$f" | sed 's/^RESULT,//')
          echo "$row" >> "$OUT"
          pdr=$(echo "$row" | cut -d, -f21)
          ctrl=$(echo "$row" | cut -d, -f31)
          elapsed=$(( $(date +%s) - started ))
          eta=$(( elapsed * (total - n) / n ))
          printf "PDR %6s%%  ctrl %6s   [ETA %dh%02dm]\n" \
                 "$pdr" "$ctrl" $((eta/3600)) $(( (eta%3600)/60 ))
      else
          echo "FAILED (see $f)"
          cp "$f" "$OUTDIR/failed_${mode}_${speed}_${seed}.txt"
      fi
    done
  done
done

echo
echo "Finished: $(date)"
echo "Wrote $OUT"
echo
echo "Means by mode and speed:"
awk -F, 'NR>1 {
    k=$1","$7
    pdr[k]+=$21; ctrl[k]+=$31; dly[k]+=$24; avail[k]+=$23; c[k]++
}
END {
    printf "%-10s %6s %9s %9s %10s %10s\n", "mode","speed","PDR%","gwAvail%","delay_ms","control"
    for (k in c) {
        split(k,p,",")
        printf "%-10s %6s %9.2f %9.2f %10.2f %10.1f\n", \
               p[1], p[2], pdr[k]/c[k], avail[k]/c[k], dly[k]/c[k], ctrl[k]/c[k]
    }
}' "$OUT" | sort -k1,1 -k2,2n

echo
echo "To share with the other machine:"
echo "    cd ~/ns3work-sync && git add $(basename "$OUT") && git commit -m 'Scenario $SCENARIO speed sweep' && git push"
