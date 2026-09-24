# check_movement.awk -- sanity check for mobility.tcl
# Usage: awk -f check_movement.awk traces/<run>.tr.pos
# Prints mean distance travelled per node and the offered load of the flows.
# With the old scripts, RD and GM nodes travelled only ~5-15 m in 1000 s.
# With the fix, expect hundreds to thousands of metres per node.

/^# flow/ { flows++; print; next }
/^#/      { next }
{
    t = $1; n = $2; x = $3; y = $4
    if (n in lx) {
        dist[n] += sqrt((x - lx[n])^2 + (y - ly[n])^2)
    }
    lx[n] = x; ly[n] = y
    if (!(n in seen)) { seen[n] = 1; nodes++ }
}
END {
    tot = 0; mn = 1e18; mx = 0
    for (n in seen) {
        d = dist[n] + 0
        tot += d
        if (d < mn) mn = d
        if (d > mx) mx = d
    }
    printf "nodes=%d  flows=%d\n", nodes, flows
    printf "distance per node (m): mean=%.1f  min=%.1f  max=%.1f\n", tot / nodes, mn, mx
}
