#!/usr/bin/env bash

SEEDS=(1 2 3 4 5)
MODELS=("RD" "GM" "RWP")
NODE_COUNTS=(25 50 75 100 125)

TOTAL_RUNS=$((${#SEEDS[@]} * ${#MODELS[@]} * ${#NODE_COUNTS[@]}))
CURRENT_RUN=0
START_TIME=$(date +%s)

mkdir -p traces
mkdir -p results

OUTPUT_CSV="results/final_results_DSDV.csv"

echo "Nodes,Mobility,PDR_mean,PDR_std,Delay_mean,Delay_std,Throughput_mean,Throughput_std,NRL_mean,NRL_std" > "$OUTPUT_CSV"

for nodes in "${NODE_COUNTS[@]}"
do
  for model in "${MODELS[@]}"
  do

    PDR_VALUES=()
    DELAY_VALUES=()
    THROUGHPUT_VALUES=()
    NRL_VALUES=()

    for seed in "${SEEDS[@]}"
    do
      CURRENT_RUN=$((CURRENT_RUN+1))

      TRACE="$(pwd)/traces/DSDV_${model}_${nodes}nodes_seed${seed}.tr"

      echo "--------------------------------------------"
      echo "Run $CURRENT_RUN / $TOTAL_RUNS"
      echo "Protocol=DSDV | Model=$model | Nodes=$nodes | Seed=$seed"

      ns mobility.tcl $seed $model $nodes $TRACE

      if [ ! -f "$TRACE" ]; then
        echo "Simulation failed. Skipping..."
        continue
      fi

      awk -v simtime=1000 -f extract_metrics_DSDV.awk "$TRACE" > temp.txt

      pdr=$(grep "^PDR" temp.txt | awk '{print $2}')
      delay=$(grep "^Delay" temp.txt | awk '{print $2}')
      throughput=$(grep "^Throughput" temp.txt | awk '{print $2}')
      nrl=$(grep "^NRL" temp.txt | awk '{print $2}')

      PDR_VALUES+=($pdr)
      DELAY_VALUES+=($delay)
      THROUGHPUT_VALUES+=($throughput)
      NRL_VALUES+=($nrl)

      rm -f "$TRACE"

      # -------- ETA calculation --------
      NOW=$(date +%s)
      ELAPSED=$((NOW - START_TIME))
      AVG_TIME=$((ELAPSED / CURRENT_RUN))
      REMAINING=$((TOTAL_RUNS - CURRENT_RUN))
      ETA_SEC=$((AVG_TIME * REMAINING))

      printf "Elapsed: %02dh:%02dm | ETA: %02dh:%02dm\n" \
        $((ELAPSED/3600)) $(((ELAPSED%3600)/60)) \
        $((ETA_SEC/3600)) $(((ETA_SEC%3600)/60))

    done

    # -------- Mean & Std Dev Calculation --------

    calc_stats() {
      arr=("$@")
      n=${#arr[@]}
      sum=0

      for v in "${arr[@]}"; do
        sum=$(echo "$sum + $v" | bc -l)
      done

      mean=$(echo "$sum / $n" | bc -l)

      sq_diff=0
      for v in "${arr[@]}"; do
        diff=$(echo "$v - $mean" | bc -l)
        sq=$(echo "$diff * $diff" | bc -l)
        sq_diff=$(echo "$sq_diff + $sq" | bc -l)
      done

      variance=$(echo "$sq_diff / $n" | bc -l)
      std=$(echo "scale=8; sqrt($variance)" | bc -l)

      echo "$mean $std"
    }

    read pdr_mean pdr_std <<< $(calc_stats "${PDR_VALUES[@]}")
    read delay_mean delay_std <<< $(calc_stats "${DELAY_VALUES[@]}")
    read throughput_mean throughput_std <<< $(calc_stats "${THROUGHPUT_VALUES[@]}")
    read nrl_mean nrl_std <<< $(calc_stats "${NRL_VALUES[@]}")

    printf "%d,%s,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n" \
      "$nodes" "$model" \
      "$pdr_mean" "$pdr_std" \
      "$delay_mean" "$delay_std" \
      "$throughput_mean" "$throughput_std" \
      "$nrl_mean" "$nrl_std" \
      >> "$OUTPUT_CSV"

    echo "Completed DSDV: $model with $nodes nodes"

  done
done

rm -f temp.txt

echo "========================================="
echo "All DSDV experiments completed."
echo "Results saved in $OUTPUT_CSV"
echo "========================================="
