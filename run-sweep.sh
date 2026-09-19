#!/bin/bash
#
# run-sweep.sh -- parameter sweep for the gateway discovery comparison.
#
# Sweeps all three discovery mechanisms against advertisement interval, with
# several RNG seeds per point so the figures can carry error bars rather than
# resting on a single run. Writes one tidy CSV that plots directly.
#
# The advertisement-interval axis is the important one: it is what decides the
# relative cost of the three mechanisms. Proactive pays per advertisement, so
# its overhead falls as the interval grows; reactive pays per solicitation and
# is largely indifferent to it. Somewhere between them the curves cross, and
# that crossover is the result worth reporting -- a single interval only ever
# shows one side of it. Hamidian swept 2-60 s for the same reason.
#
# Usage:
#   bash /mnt/hgfs/ns3work/run-sweep.sh
#
# Output:
#   /mnt/hgfs/ns3work/results.csv

set -u

NS3DIR=~/ns-allinone-3.48/ns-3.48
SHARED=~/ns3work-sync
OUT=$SHARED/results.csv
SCRATCH=$(mktemp -d)

MODES="proactive reactive hybrid"
ADV_INTERVALS="2 5 10 20 40 60"
SEEDS="1 2 3"
SIMTIME=200
AREA=750

cd "$NS3DIR" || { echo "cannot cd to $NS3DIR"; exit 1; }

echo "mode,advInterval,seed,sent,relayed,received,pdr,delay_ms,noGateway,control,gw0,gw1" > "$OUT"

total=0
for m in $MODES; do for a in $ADV_INTERVALS; do for s in $SEEDS; do
    total=$((total+1))
done; done; done

n=0
for mode in $MODES; do
  for adv in $ADV_INTERVALS; do
    for seed in $SEEDS; do
      n=$((n+1))
      f="$SCRATCH/${mode}_${adv}_${seed}.txt"
      printf "[%2d/%2d] mode=%-9s advInterval=%-2s seed=%s ... " "$n" "$total" "$mode" "$adv" "$seed"

      ./ns3 run "scratch/gateway-discovery --mode=$mode --advInterval=$adv \
                 --simTime=$SIMTIME --areaSize=$AREA --RngRun=$seed" > "$f" 2>&1

      if ! grep -q "Packet Delivery Ratio" "$f"; then
        echo "FAILED (see $f)"
        continue
      fi

      sent=$(grep "Data packets sent:"     "$f" | awk '{print $4}')
      relayed=$(grep "Data packets relayed:"  "$f" | awk '{print $4}')
      received=$(grep "Data packets received:" "$f" | awk '{print $4}')
      pdr=$(grep "Packet Delivery Ratio"    "$f" | awk '{print $4}')
      delay=$(grep "Average End-to-End Delay" "$f" | awk '{print $4}')
      nogw=$(grep "no gateway known"        "$f" | awk '{print $6}')
      ctrl=$(grep "TOTAL control messages"  "$f" | awk '{print $4}')
      gw0=$(grep "gateway 0 "               "$f" | awk '{print $4}')
      gw1=$(grep "gateway 1 "               "$f" | awk '{print $4}')

      # delay is printed in seconds; milliseconds read better in a table
      delay_ms=$(awk -v d="$delay" 'BEGIN{printf "%.4f", d*1000}')

      echo "$mode,$adv,$seed,$sent,$relayed,$received,$pdr,$delay_ms,$nogw,$ctrl,$gw0,$gw1" >> "$OUT"
      echo "PDR ${pdr}%  ctrl ${ctrl}"
    done
  done
done

echo
echo "Done. Wrote $OUT"
echo
echo "Means by mode and advertisement interval:"
awk -F, 'NR>1 {
    key=$1","$2
    pdr[key]+=$7; ctrl[key]+=$10; dly[key]+=$8; cnt[key]++
}
END {
    printf "%-10s %5s %8s %10s %10s\n", "mode", "adv", "PDR%", "delay_ms", "control"
    for (k in cnt) {
        split(k, p, ",")
        printf "%-10s %5s %8.2f %10.3f %10.1f\n", p[1], p[2], pdr[k]/cnt[k], dly[k]/cnt[k], ctrl[k]/cnt[k]
    }
}' "$OUT" | sort -k1,1 -k2,2n
