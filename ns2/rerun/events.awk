# events.awk -- AODV control-packet event log for Paper 5 (OLD trace format)
#
# Usage:
#   awk -v model=RWP -v nodes=50 -v seed=1 -v speed=1-3 -f events.awk run.tr >> events.csv
#
# Output columns: time,event,node,hop,dst,model,nodes,seed,speed
#   event : RREQ | RREP | RERR | LFAIL
#   hop   : RREQ hop count (1 = originated by this node, >1 = forwarded)
#   dst   : RREQ target destination
#   LFAIL : link failure seen by the routing layer (drop reason CBK),
#           so RREQ bursts can be attributed to link breaks vs timeouts.
# Every event is tagged with its run, so per-run analysis is always possible.

$1 == "s" && $4 == "RTR" && $7 == "AODV" {
    node = $3; gsub(/_/, "", node)
    ev = ""; hop = ""; dst = ""
    if ($NF == "(REQUEST)" || $NF == "(RREQ)") {
        ev = "RREQ"
        for (i = 1; i <= NF; i++) if ($i == "[0x2") { hop = $(i + 1); dst = $(i + 3); break }
        gsub(/\[/, "", dst)
    } else if ($NF == "(REPLY)" || $NF == "(RREP)") {
        ev = "RREP"
    } else if ($NF == "(ERROR)" || $NF == "(RERR)") {
        ev = "RERR"
    }
    if (ev != "")
        print $2 "," ev "," node "," hop "," dst "," model "," nodes "," seed "," speed
    next
}

$1 == "D" && $4 == "RTR" && $5 == "CBK" {
    node = $3; gsub(/_/, "", node)
    print $2 ",LFAIL," node ",,," model "," nodes "," seed "," speed
}
