#!/bin/bash
set -u
NS3DIR=~/ns-allinone-3.48/ns-3.48
OUT=~/ns3work-sync/trust-beta-v9.csv
SEEDS="1 2 3 4 5"
CONFIGS="0:25 0:50 0:100 0.3:10 0.5:10 0.7:10"
cd "$NS3DIR" || exit 1
TMP=$(mktemp -d)
[ -f "$OUT" ] || echo "beta,minSample,mode,nodes,gateways,sources,area,range,speedMin,speedMax,pause,simTime,advInterval,advZone,entryLifetime,packetSize,cbrRate,seed,offered,sent,relayed,received,pdr,txPdr,gwAvail,delay_ms,noGateway,advSent,advFwd,solSent,solFwd,replies,control,gw0,gw1,malicious,droppedByMalicious,areaHeight,numMaliciousGw,dropFraction,trustAware,trustThreshold,dataViaMalicious,acksSent,acksDelivered" > "$OUT"
n=0
for c in $CONFIGS; do beta=${c%%:*}; ms=${c##*:}
  for seed in $SEEDS; do n=$((n+1))
    if awk -F, -v b="$beta" -v m="$ms" -v s="$seed" 'NR>1 && $1==b && $2==m && $18==s {f=1} END{exit !f}' "$OUT"; then echo "[$n/30] done already"; continue; fi
    printf "[%2d/30] beta=%s minSample=%s seed=%s ... " "$n" "$beta" "$ms" "$seed"
    f="$TMP/r$n.txt"
    ./ns3 run "scratch/gateway-trust-v9 --mode=hybrid --numManetNodes=15 --numGateways=2 --numSources=5 --areaSize=800 --areaHeight=500 --range=250 --nodeSpeedMin=3 --nodeSpeedMax=3 --pauseTime=60 --simTime=900 --advInterval=5 --advZone=3 --entryLifetime=15 --packetSize=512 --cbrRate=5 --maliciousGw=true --numMaliciousGw=1 --dropFraction=1.0 --trustAware=true --trustThreshold=0.5 --trustBeta=$beta --trustMinSample=$ms --solHoldoff=1 --RngRun=$seed" > "$f" 2>&1
    if grep -q "^RESULT," "$f"; then row=$(grep "^RESULT," "$f" | sed 's/^RESULT,//'); echo "$beta,$ms,$row" >> "$OUT"; sync; echo "PDR $(echo "$row" | cut -d, -f21)"; else echo "FAILED ($f)"; fi
  done
done
echo "Done: $(($(wc -l < "$OUT")-1)) rows"
