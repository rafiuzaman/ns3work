#!/bin/bash
#
# build.sh -- run this INSIDE the Ubuntu VM.
#
# Chain of custody:
#
#   C:\ns3work                          Claude writes here (Windows bridge)
#        |  VMware shared folder
#        v
#   /mnt/hgfs/ns3work/                  what Claude just wrote
#        |  step 1
#        v
#   ~/ns3work-sync/                     git working copy (syncs to workstation)
#        |  step 2
#        v
#   ~/ns-allinone-3.48/ns-3.48/scratch/ the ONLY copy ns-3 compiles
#        |
#        v
#      ./ns3 build
#
# Skipping step 2 is what cost an afternoon on 18 Sep: ninja reports "no work
# to do" and silently reruns the OLD binary. This script makes that impossible
# by always copying, then verifying byte counts before it will build.

set -eu

SHARED=/mnt/hgfs/ns3work
REPO=~/ns3work-sync
NS3DIR=~/ns-allinone-3.48/ns-3.48

echo "1. Shared folder -> git repo"
cp -v "$SHARED"/ns-3.48/scratch/gateway-baseline.cc  "$REPO"/
cp -v "$SHARED"/ns-3.48/scratch/gateway-discovery.cc "$REPO"/
for s in calibrate.sh sweep-speed.sh sweep-interval.sh build.sh; do
    [ -f "$SHARED/$s" ] && cp -v "$SHARED/$s" "$REPO"/
done
chmod +x "$REPO"/*.sh

echo
echo "2. git repo -> ns-3 scratch"
cp -v "$REPO"/gateway-baseline.cc  "$NS3DIR"/scratch/
cp -v "$REPO"/gateway-discovery.cc "$NS3DIR"/scratch/

echo
echo "3. Verifying copies match"
for f in gateway-baseline.cc gateway-discovery.cc; do
    a=$(wc -c < "$SHARED/ns-3.48/scratch/$f")
    b=$(wc -c < "$NS3DIR/scratch/$f")
    if [ "$a" = "$b" ]; then
        echo "   OK   $f  ($a bytes)"
    else
        echo "   FAIL $f  shared=$a scratch=$b"
        exit 1
    fi
done

echo
echo "4. Building"
cd "$NS3DIR"
./ns3 build

echo
echo "Done. scratch/ matches what Claude wrote, and the build is current."
echo
echo "Push code to the workstation with:"
echo "    cd ~/ns3work-sync && git add -u && git add -A && git commit -m 'your message' && git push"
