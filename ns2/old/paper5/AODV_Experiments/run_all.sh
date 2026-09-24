#!/usr/bin/env bash

# ============================================
# AODV Temporal Routing Dynamics Experiments
# FINAL CLEAN VERSION
# ============================================

SEEDS=(1 2 3 4 5)
MODELS=("RWP" "GM")
NODE_COUNTS=(50 100)

TOTAL_RUNS=$((${#SEEDS[@]} * ${#MODELS[@]} * ${#NODE_COUNTS[@]}))
CURRENT_RUN=0
START_TIME=$(date +%s)

mkdir -p traces
mkdir -p events

EVENTS_FILE="events/all_events.csv"

echo "time,event,model,nodes,seed" > "$EVENTS_FILE"

for nodes in "${NODE_COUNTS[@]}"
do
  for model in "${MODELS[@]}"
  do
    for seed in "${SEEDS[@]}"
    do

      CURRENT_RUN=$((CURRENT_RUN+1))

      TRACE="traces/AODV_${model}_${nodes}nodes_seed${seed}.tr"
      TMP="events/tmp_events.csv"

      echo "--------------------------------------------"
      echo "Run $CURRENT_RUN / $TOTAL_RUNS"
      echo "Model=$model Nodes=$nodes Seed=$seed"

      ns mobility.tcl $seed $model $nodes $TRACE

      if [ ! -f "$TRACE" ]; then
        echo "Simulation failed"
        continue
      fi

      awk '
      {
          if ($1=="s" && $0 ~ /-Nl RTR/) {

              if ($0 ~ /-Pc REQUEST/ && $0 ~ /-Pb 1/) {
                  for(i=1;i<=NF;i++)
                      if($i=="-t"){print $(i+1)",RREQ"}
              }

              else if ($0 ~ /-Pc REPLY/) {
                  for(i=1;i<=NF;i++)
                      if($i=="-t"){print $(i+1)",RREP"}
              }

              else if ($0 ~ /-Pc ERROR/) {
                  for(i=1;i<=NF;i++)
                      if($i=="-t"){print $(i+1)",RERR"}
              }

          }
      }' "$TRACE" > "$TMP"

      COUNT=$(wc -l < "$TMP")

      if [ "$COUNT" -gt 0 ]; then

          awk -v m="$model" -v n="$nodes" -v s="$seed" \
          -F',' '{print $1","$2","m","n","s}' \
          "$TMP" >> "$EVENTS_FILE"

          rm "$TRACE"
      else
          echo "WARNING: No events extracted. Trace kept."
      fi

      rm -f "$TMP"

      NOW=$(date +%s)
      ELAPSED=$((NOW - START_TIME))
      AVG=$((ELAPSED / CURRENT_RUN))
      REMAIN=$((TOTAL_RUNS - CURRENT_RUN))
      ETA=$((AVG * REMAIN))

      printf "Elapsed: %02dh:%02dm | ETA: %02dh:%02dm\n" \
      $((ELAPSED/3600)) $(((ELAPSED%3600)/60)) \
      $((ETA/3600)) $(((ETA%3600)/60))

    done
  done
done

echo "==========================================="
echo "All simulations completed"
echo "Dataset stored in:"
echo "$EVENTS_FILE"
echo "==========================================="
