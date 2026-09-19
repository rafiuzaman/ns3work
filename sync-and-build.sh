#!/bin/bash
#
# sync-and-build.sh -- copy synced source files from the git repo folder into
# ns-3's scratch/ directory and rebuild, in one step.
#
# Why this exists: earlier in this project a stale scratch/ file (edited in
# one place, built from another) cost a full afternoon of debugging that
# turned out to be nothing but an out-of-date binary. This script makes that
# class of bug structurally impossible: it always copies fresh from the repo
# right before building, so what you run is always what's in git.
#
# Usage:
#   bash sync-and-build.sh
#
# Run this from anywhere; it finds both directories from the variables below.
# Edit REPO and NS3DIR once for each machine (they'll differ between your
# workstation and laptop) and never think about it again.

set -eu

# --- machine-specific paths: edit these two lines per machine ---
REPO=~/ns3work-sync
NS3DIR=~/ns-allinone-3.48/ns-3.48
# ------------------------------------------------------------------

SCRATCH="$NS3DIR/scratch"

echo "Pulling latest from git..."
git -C "$REPO" pull

echo "Copying source files into ns-3 scratch/..."
cp -v "$REPO"/gateway-baseline.cc  "$SCRATCH"/
cp -v "$REPO"/gateway-discovery.cc "$SCRATCH"/

echo "Building..."
cd "$NS3DIR"
./ns3 build

echo
echo "Done. scratch/ now matches the repo, and the build is up to date."
echo "Run a scenario with, e.g.:"
echo "  ./ns3 run \"scratch/gateway-discovery --mode=proactive\""
