#!/bin/bash
#
# calibrate.sh -- measure how long a single run actually takes, at each of the
# scenario sizes we intend to sweep, before committing to a long job.
#
# A grand sweep is only worth launching if we know roughly when it will finish.
# Run time in ns-3 grows with both the simulated duration and, much more
# steeply, the node count -- AODV's control traffic scales super-linearly with
# density. Guessing at this is how an overnight job turns out to need three
# days. This script times one run per scenario and prints the projected total.
#
# Usage:  bash calibrate.sh
# Takes:  roughly 15-40 minutes depending on the machine.

set -u

NS3DIR=~/ns-allinone-3.48/ns-3.48
cd "$NS3DIR" || { echo "cannot cd to $NS3DIR"; exit 1; }

SIMTIME=900   # the house convention, as used in every prior paper

echo "Calibrating run times at simTime=${SIMTIME}s"
echo "(one run per scenario, proactive mode, mid-range speed)"
echo

declare -A SECONDS_PER_RUN

time_one () {
    local label="$1" nodes="$2" gw="$3" area="$4"
    printf "%-28s " "$label"
    local start=$(date +%s)
    ./ns3 run "scratch/gateway-discovery --mode=proactive \
               --numManetNodes=$nodes --numGateways=$gw --areaSize=$area \
               --simTime=$SIMTIME --nodeSpeedMin=3 --nodeSpeedMax=3 \
               --pauseTime=60 --RngRun=1" > /tmp/calib_${nodes}.txt 2>&1
    local end=$(date +%s)
    local elapsed=$((end - start))
    SECONDS_PER_RUN[$label]=$elapsed

    if grep -q "^RESULT," /tmp/calib_${nodes}.txt; then
        # Strip the RESULT tag first, so field numbers match the CSV header
        # rather than being shifted by one. Cutting the tagged line directly
        # is how the first version of this script reported packet counts as
        # percentages.
        local row=$(grep "^RESULT," /tmp/calib_${nodes}.txt | sed 's/^RESULT,//')
        local pdr=$(echo "$row" | cut -d, -f21)
        local avail=$(echo "$row" | cut -d, -f23)
        printf "%4d s   (PDR %s%%, gw avail %s%%)\n" "$elapsed" "$pdr" "$avail"
    else
        printf "%4d s   FAILED - see /tmp/calib_${nodes}.txt\n" "$elapsed"
    fi
}

time_one "S1: 15 nodes, 2 gw, 800x500"   15 2 800
time_one "S2: 25 nodes, 3 gw, 1000x1000" 25 3 1000
time_one "S3: 50 nodes, 5 gw, 1200x1200" 50 5 1200

echo
echo "Projected totals for a node-speed sweep"
echo "(3 modes x 6 speeds x 3 seeds = 54 runs per scenario):"
echo
for k in "${!SECONDS_PER_RUN[@]}"; do
    s=${SECONDS_PER_RUN[$k]}
    total=$((s * 54))
    printf "  %-28s %5d s/run  ->  %5.1f hours for 54 runs\n" \
           "$k" "$s" "$(echo "scale=2; $total/3600" | bc)"
done

echo
echo "Decide from these numbers which scenarios to sweep tonight, and on which"
echo "machine. Remember the workstation can run one scenario while the laptop"
echo "runs another -- they share code through git but results stay local until"
echo "committed."
