# ns-2 re-run kit (Papers A, B, C)

Corrected scripts for re-running the ns-2.35 experiments behind Papers 1–5.
The original scripts are kept unchanged in `../old/` for comparison.

| File | Purpose |
| --- | --- |
| `mobility.tcl` | One scenario script for AODV / DSDV / OLSR, RWP / RD / GM |
| `metrics.awk` | Per-run metrics from a trace (old trace format) |
| `events.awk` | AODV control-packet event log (Paper C) |
| `run.sh` | Runs a grid of experiments, resumable, optionally in parallel |
| `summarize.awk` | Mean, SD and 95 % CI across seeds |
| `check_movement.awk` | Confirms nodes actually move |

## What was wrong in the old scripts

1. **RD and GM nodes barely moved.** The loops read `X_`/`Y_` while the script
   was being built, so every step started from the initial position.
2. **Rate was hardcoded** (`set rate 128kb`), so the Paper 1 "64 kbps" AODV runs
   were really 128 kbps.
3. **Delay was wrong.** Packets were matched on field `$11`, which is always 0
   at the AGT layer. Now matched on the unique packet id `$6`.
4. **LBR counted RERR transmissions**, including forwarded copies. Now counts
   link failures reported by the MAC (drop reason `CBK`), one per link per second.
5. **PST paired the k-th RERR with the k-th RREP anywhere in the network.** Now:
   per flow, the length of each uninterrupted delivery period (a gap of more than
   1 s ends a period); periods still running at the end are reported separately
   as censored.
6. **Seeds did not control movement.** Tcl's `rand()` is not seeded by
   `ns-random`. All randomness now comes from one seeded RNG.
7. **Radio settings unstated.** Now explicit: 802.11 data and basic rate 1 Mb/s
   (the ns-2.35 default the original runs used), TwoRayGround, 250 m range.

Kept from the original on purpose: 5 CBR flows, 512-byte packets, 600 x 400 m,
1000 s, RWP pause 100 s (pass `PAUSE=100`), RD and GM without pauses.

## First: validate (about 5 minutes)

```bash
cd ~/ns2work/rerun
chmod +x run.sh
SEEDS="1" NODES="50" RATES="64" OUT=results/validate.csv KEEP=1 ./run.sh
cat results/validate.csv
cat logs/*.movement
```

Check:

* `logs/*.movement` — mean distance per node should be in the hundreds or
  thousands of metres for RWP, RD and GM (old scripts: ~10 m for RD/GM).
* `thr_kbps` at 64 kb/s with 5 flows should be close to `pdr/100 × 320`.
* `delay` should be tens of milliseconds or more, not 0.001.
* For OLSR, run once with `PROTOS="OLSR"` and check `ctrl` is not 0.

## Then: the campaigns

```bash
# Paper A (load x mobility): 3 protocols, 2 loads, 2 speed ranges
PROTOS="AODV DSDV OLSR" RATES="64 128" SPEEDS="1-3 1-20" \
  OUT=results/paperA.csv JOBS=2 nohup ./run.sh > paperA.log 2>&1 &

# Paper B (overhead scaling): wider node range, 4 speeds, one load
PROTOS="AODV DSDV OLSR" NODES="25 50 75 100 125 150 200" RATES="128" \
  SPEEDS="1-3 1-5 1-10 1-20" OUT=results/paperB.csv JOBS=2 nohup ./run.sh > paperB.log 2>&1 &

# Paper C (temporal events): AODV, event log on
PROTOS="AODV" NODES="50 100" RATES="128" SPEEDS="1-3 1-20" EVENTS=1 \
  OUT=results/paperC.csv EVOUT=results/paperC_events.csv ./run.sh
```

Set `JOBS` to the number of CPU cores the VM has (`nproc`). Runs already in the
output CSV are skipped, so after any interruption just run the same command again.

Summaries:

```bash
awk -F, -f summarize.awk results/paperA.csv > results/paperA_summary.csv
```

After each batch: `git add results && git commit -m "..." && git push`.
