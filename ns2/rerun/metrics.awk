# metrics.awk -- per-run metrics from an ns-2.35 wireless trace (OLD trace format)
#
# Usage:
#   awk -v tstart=20 -v tstop=1000 -v nn=50 -v gap=1.0 -f metrics.awk run.tr
#
# Works for AODV, DSDV and OLSR (routing packet types AODV / message / OLSR).
# Prints one line:  key=value key=value ...
#
# Fixes compared with the old extract_metrics*.awk:
#  * Delay: packets are matched on the unique packet id ($6). The old script
#    used $11, which is a MAC-header field that is always 0 at the AGT layer,
#    so every delay was "time since the most recent send by ANY flow"
#    (hence the 0-2.5 ms averages and exact zeros).
#  * Each packet is counted as received once, at its own destination.
#  * Throughput is payload bits delivered per second of traffic time, in kbps.
#  * Link failures: MAC-layer failures reported to the routing layer (drop
#    reason CBK), de-duplicated per link within a 1 s window. The old LBR
#    counted every RERR transmission, including forwarded copies.
#  * PST: per flow, the lengths of uninterrupted delivery periods. A period
#    ends when no packet of that flow arrives for more than `gap` seconds.
#    Periods still running at the end of the simulation are censored and
#    reported separately (reviewer question). The old PST paired the k-th
#    RERR with the k-th RREP anywhere in the network, which has no meaning.

function node_of(s) { gsub(/_/, "", s); return s + 0 }
function addr_of(s) { gsub(/\[/, "", s); split(s, a, ":"); return a[1] + 0 }

BEGIN {
    if (gap == "")    gap = 1.0
    if (tstart == "") tstart = 20
    if (tstop == "")  tstop = 1000
    sent = 0; recv = 0; bytes = 0; dsum = 0
    ctrl = 0; ctrl_bytes = 0
    rreq = 0; rrep = 0; rerr = 0
    lfail = 0
}

# ---------------- data: send ----------------
$1 == "s" && $4 == "AGT" && $7 == "cbr" {
    uid = $6
    if (!(uid in st)) {
        sent++
        st[uid] = $2
        dst_of[uid] = addr_of($15)
        flow_of[uid] = addr_of($14) "-" addr_of($15)
    }
    next
}

# ---------------- data: receive ----------------
$1 == "r" && $4 == "AGT" && $7 == "cbr" {
    uid = $6
    if ((uid in st) && !(uid in got) && node_of($3) == dst_of[uid]) {
        got[uid] = 1
        recv++
        dsum += $2 - st[uid]
        bytes += 512
        f = flow_of[uid]
        t = $2
        if (!(f in pstart)) {                 # first delivery of this flow
            pstart[f] = t
        } else if (t - plast[f] > gap) {      # delivery gap: period ended
            np++; psum += plast[f] - pstart[f]
            pstart[f] = t
        }
        plast[f] = t
    }
    next
}

# ---------------- routing control packets ----------------
$1 == "s" && $4 == "RTR" && ($7 == "AODV" || $7 == "message" || $7 == "OLSR") {
    ctrl++
    ctrl_bytes += $8
    # stock ns-2.35 prints (REQUEST)/(REPLY)/(ERROR); AODV+ builds print (RREQ)/(RREP)/(RERR)
    if ($NF == "(REQUEST)" || $NF == "(RREQ)") rreq++
    else if ($NF == "(REPLY)" || $NF == "(RREP)") rrep++
    else if ($NF == "(ERROR)" || $NF == "(RERR)") rerr++
    next
}

# ---------------- link failures (MAC callback drops) ----------------
$1 == "D" && $4 == "RTR" && $5 == "CBK" {
    link = $3 "-" $10          # node and next-hop MAC address
    if (!(link in lastf) || $2 - lastf[link] > 1.0) lfail++
    lastf[link] = $2
    next
}

END {
    T = tstop - tstart
    # close still-open delivery periods (censored)
    for (f in pstart) { nc++; csum += plast[f] - pstart[f] }

    pdr   = (sent > 0) ? 100.0 * recv / sent : 0
    delay = (recv > 0) ? dsum / recv : 0
    thr   = bytes * 8 / T / 1000.0
    nrl   = (recv > 0) ? ctrl / recv : 0
    cpns  = (nn > 0) ? ctrl / nn / T : 0
    lbr   = lfail / T
    pst   = (np > 0) ? psum / np : 0
    pst_all = (np + nc > 0) ? (psum + csum) / (np + nc) : 0

    printf "sent=%d recv=%d pdr=%.4f delay=%.6f thr_kbps=%.4f ", sent, recv, pdr, delay, thr
    printf "ctrl=%d ctrl_bytes=%d nrl=%.6f ctrl_per_node_s=%.6f ", ctrl, ctrl_bytes, nrl, cpns
    printf "rreq=%d rrep=%d rerr=%d link_fail=%d lbr=%.6f ", rreq, rrep, rerr, lfail, lbr
    printf "pst=%.4f pst_n=%d pst_censored_n=%d pst_incl_censored=%.4f\n", pst, np + 0, nc + 0, pst_all
}
