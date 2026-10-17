# Paper4 — adaptive (fuzzy, GA-tuned) gateway discovery in Integrated Internet-MANET

Branch `paper4`. Everything for Paper4 lives in this folder; nothing here depends on other papers' result files.

Scenarios (17 Oct): S1 20 nodes 1000x600 m 2 GW 5 sources; S2 40 nodes 1200x1000 m 3 GW 8 sources; S3 50 nodes; S4 100 nodes; seeds 11–15.
(The first calibration, p4-calib.csv, used the 15/25-node set-ups and is not used.)

## Files
- `p4-adaptive-gw.cc` — ns-3.48 program: proactive / reactive / hybrid gateway discovery with optional adaptive control at each
  gateway of the advertisement zone k and interval T (`--adaptMode` 0 off, 1 interval, 2 zone, 3 joint = proposed, 4 maximal
  source coverage). The sweep script copies it into ns-3's `scratch/` itself.
- `sweep-p4.sh` — all simulation runs (resumable).
- `fz-params.txt` — GA-tuned fuzzy parameters (line 1 tag, line 2 the 13 values). Added by Claude after stage 1.
- `results/` — CSV files pushed back from the workstation.

## Workflow (workstation, inside the Ubuntu VM with ns-3.48)
First time:
    cd ~/ns3work-sync && git fetch origin && git checkout paper4
(If ns-3.48 is not at ~/ns-allinone-3.48/ns-3.48:  export NS3DIR=/path/to/ns-3.48)

0. Build check (one run):          ./paper4/sweep-p4.sh check     -> must print 96.4741,3294
1. STAGE 1 — calibration (80 runs, 20/40 nodes, seeds 11–15, about 40–60 min):
       nohup ./paper4/sweep-p4.sh calib 1 > ~/p4-calib.log 2>&1 &
   then push:  git add paper4/results/p4-calib2.csv && git commit -m "Paper4 calib2" && git push origin paper4
2. STAGE 2 — Claude fits the cost model from p4-calib.csv, runs the GA and pushes paper4/fz-params.txt.
3. STAGE 3 — evaluation (360 runs; overnight, the 100-node runs take ~10 min each):
       git pull
       nohup ./paper4/sweep-p4.sh eval 1 > ~/p4-eval.log 2>&1 &
   then push:  git add paper4/results/p4-eval.csv && git commit -m "Paper4 eval" && git push origin paper4
   (Interrupted? Run the same command again; finished runs are skipped. Push partial results any time.)
Optional: ./paper4/sweep-p4.sh large 1  (zone sweep at 50/100 nodes, for the discussion of scale).

Watch progress: tail -f ~/p4-calib.log  or  tail -f ~/p4-eval.log
