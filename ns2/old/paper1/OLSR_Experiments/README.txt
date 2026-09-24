OLSR_Experiments - Paper 1
=============================

Directory structure mirrors the AODV_Experiments layout:

OLSR_Experiments/
├── extract_metrics.awk
├── mobility.tcl
├── run_experiments.sh
├── results/
└── traces/

Run one test before the full batch:

    ns mobility.tcl 1 RWP 25 traces/OLSR_RWP_25nodes_seed1.tr 128kb

Then inspect whether OLSR control packets appear:

    grep "OLSR" traces/OLSR_RWP_25nodes_seed1.tr | head

Then extract metrics:

    awk -v simtime=1000 -f extract_metrics.awk traces/OLSR_RWP_25nodes_seed1.tr

If the OLSR trace token is different in your OLSR implementation, the
routing-packet condition in extract_metrics.awk must be adjusted before
the full experiment.

Full experiments:

    ./run_experiments.sh 64
    ./run_experiments.sh 128

Outputs:

    results/OLSR_final_results_64kbps.csv
    results/OLSR_final_results_128kbps.csv

The script uses:
- Seeds: 1 2 3 4 5
- Mobility: RD, GM, RWP
- Nodes: 25, 50, 75, 100, 125
- Area: 600 x 400 m
- Simulation time: 1000 s
- Speed: 1-3 m/s
- RWP pause: 100 s
- GM alpha: 0.75
- 5 CBR/UDP flows
- Packet size: 512 bytes
- Traffic rate: 64 or 128 kbps per flow
- IEEE 802.11
- TwoRayGround
- DropTail/PriQueue, 50 packets
- Five runs per configuration

Important:
This script assumes your ns-2.35 build contains an OLSR implementation
registered as "OLSR". The supplied AODV experiment uses the same mobility,
traffic, queue, and trace configuration; only the routing protocol and
rate argument interface are changed.
