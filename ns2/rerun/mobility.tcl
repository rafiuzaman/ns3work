# ==========================================================================
# mobility.tcl  --  unified, corrected scenario script for ns-2.35
#
# Usage:
#   ns mobility.tcl <proto> <model> <nodes> <seed> <rate_kb> <vmin> <vmax> <pause> <tracefile>
#
#   proto   : AODV | DSDV | OLSR          (OLSR needs the UM-OLSR patch)
#   model   : RWP | RD | GM
#   rate_kb : per-flow CBR rate in kbps (e.g. 64 or 128)
#   vmin/vmax : node speed range in m/s
#   pause   : pause time in s (RWP and RD; ignored by GM)
#
# Example:
#   ns mobility.tcl AODV GM 50 1 64 1 20 0 traces/AODV_GM_50_s1.tr
#
# Fixes compared with the earlier scripts:
#   1. Node positions are tracked in Tcl arrays. The old loops read X_/Y_
#      while the script was being built, so RD and GM nodes never left
#      the neighbourhood of their start point.
#   2. All randomness comes from one RNG seeded with <seed>. Tcl's rand()
#      is NOT seeded by ns-random, so old runs were not reproducible.
#   3. Traffic rate, speed range, pause and protocol are arguments.
#   4. Flow pairs are random but seed-controlled, and are logged.
#   5. Every scheduled waypoint is written to <tracefile>.pos so movement
#      can be checked (see check_movement.awk).
# ==========================================================================

if {$argc != 9} {
    puts "Usage: ns mobility.tcl <proto> <model> <nodes> <seed> <rate_kb> <vmin> <vmax> <pause> <tracefile>"
    exit 1
}

set proto     [lindex $argv 0]
set model     [lindex $argv 1]
set val(nn)   [lindex $argv 2]
set seed      [lindex $argv 3]
set rate_kb   [lindex $argv 4]
set vmin      [expr double([lindex $argv 5])]
set vmax      [expr double([lindex $argv 6])]
set pause     [expr double([lindex $argv 7])]
set tracefile [lindex $argv 8]

# ---------------- Fixed parameters ----------------
set val(chan)   Channel/WirelessChannel
set val(prop)   Propagation/TwoRayGround
set val(netif)  Phy/WirelessPhy
set val(mac)    Mac/802_11
set val(ll)     LL
set val(ant)    Antenna/OmniAntenna
set val(ifqlen) 50
set val(x)      600
set val(y)      400
set val(stop)   1000.0
set nflows      5
set pktsize     512
set alpha       0.75     ;# Gauss-Markov memory
set gm_dt       1.0      ;# Gauss-Markov update interval (s)
set margin      1.0      ;# keep waypoints inside the area

set val(ifq)    Queue/DropTail/PriQueue

# Radio: stated explicitly so the paper can report them (reviewer request).
# ns-2.35 defaults are 1 Mb for both; 2 Mb data rate is the classic CMU setup.
# Default Phy/WirelessPhy thresholds with TwoRayGround give a 250 m range.
Mac/802_11 set dataRate_  2Mb
Mac/802_11 set basicRate_ 1Mb

# ---------------- Randomness ----------------
ns-random $seed
set rng [new RNG]
$rng seed $seed
proc U {a b} { global rng; return [$rng uniform $a $b] }
proc Nrm {}  { global rng; return [$rng normal 0.0 1.0] }

# ---------------- Simulator and traces ----------------
set ns [new Simulator]
set dirname [file dirname $tracefile]
if {![file exists $dirname]} { file mkdir $dirname }
set tracefd [open $tracefile w]
$ns trace-all $tracefd
set posfd [open "$tracefile.pos" w]
puts $posfd "# t node x y speed"

set topo [new Topography]
$topo load_flatgrid $val(x) $val(y)
create-god $val(nn)
set chan [new $val(chan)]

$ns node-config \
    -adhocRouting $proto \
    -llType $val(ll) \
    -macType $val(mac) \
    -ifqType $val(ifq) \
    -ifqLen $val(ifqlen) \
    -antType $val(ant) \
    -propType $val(prop) \
    -phyType $val(netif) \
    -channel $chan \
    -topoInstance $topo \
    -agentTrace ON \
    -routerTrace ON \
    -macTrace OFF \
    -movementTrace OFF

# ---------------- Nodes ----------------
for {set i 0} {$i < $val(nn)} {incr i} {
    set node_($i) [$ns node]
    $node_($i) random-motion 0
    set px($i) [U $margin [expr $val(x) - $margin]]
    set py($i) [U $margin [expr $val(y) - $margin]]
    $node_($i) set X_ $px($i)
    $node_($i) set Y_ $py($i)
    $node_($i) set Z_ 0.0
    puts $posfd "0.0 $i $px($i) $py($i) 0"
}

# Schedule one move and update the tracked position
proc move {i t nx ny spd} {
    global ns node_ px py posfd
    if {$spd < 0.01} { set spd 0.01 }
    $ns at $t "$node_($i) setdest $nx $ny $spd"
    puts $posfd "$t $i $nx $ny $spd"
    set px($i) $nx
    set py($i) $ny
}

# Distance from (x,y) to the area boundary along angle th
proc dist_to_edge {x y th} {
    global val margin
    set cx [expr cos($th)]
    set cy [expr sin($th)]
    set dmax 1e9
    if {$cx > 1e-9}  { set d [expr ($val(x) - $margin - $x) / $cx]; if {$d < $dmax} { set dmax $d } }
    if {$cx < -1e-9} { set d [expr ($margin - $x) / $cx];           if {$d < $dmax} { set dmax $d } }
    if {$cy > 1e-9}  { set d [expr ($val(y) - $margin - $y) / $cy]; if {$d < $dmax} { set dmax $d } }
    if {$cy < -1e-9} { set d [expr ($margin - $y) / $cy];           if {$d < $dmax} { set dmax $d } }
    if {$dmax < 0} { set dmax 0 }
    return $dmax
}

set PI 3.14159265358979

# ---------------- Mobility ----------------
for {set i 0} {$i < $val(nn)} {incr i} {
    set t 0.0

    if {$model == "RWP"} {
        # Random Waypoint: random destination, random speed, pause
        while {$t < $val(stop)} {
            set nx  [U $margin [expr $val(x) - $margin]]
            set ny  [U $margin [expr $val(y) - $margin]]
            set spd [U $vmin $vmax]
            set d   [expr hypot($nx - $px($i), $ny - $py($i))]
            move $i $t $nx $ny $spd
            set t [expr $t + $d / $spd + $pause]
        }

    } elseif {$model == "RD"} {
        # Random Direction (Royer et al.): pick a direction, travel to the
        # boundary, pause, pick a new direction
        while {$t < $val(stop)} {
            set th  [U 0 [expr 2 * $PI]]
            set d   [dist_to_edge $px($i) $py($i) $th]
            if {$d < 1.0} { set t [expr $t + 0.1]; continue }
            set nx  [expr $px($i) + $d * cos($th)]
            set ny  [expr $py($i) + $d * sin($th)]
            set spd [U $vmin $vmax]
            move $i $t $nx $ny $spd
            set t [expr $t + $d / $spd + $pause]
        }

    } elseif {$model == "GM"} {
        # Gauss-Markov (Liang & Haas; Camp et al. edge handling)
        set smean [expr ($vmin + $vmax) / 2.0]
        set ssd   [expr ($vmax - $vmin) / 4.0]
        set dsd   [expr $PI / 4.0]
        set s     [U $vmin $vmax]
        set th    [U 0 [expr 2 * $PI]]
        set dmean $th
        set k     [expr sqrt(1.0 - $alpha * $alpha)]
        while {$t < $val(stop)} {
            # near an edge: steer mean direction back towards the centre
            set ex [expr $val(x) * 0.1]
            set ey [expr $val(y) * 0.1]
            if {$px($i) < $ex || $px($i) > $val(x) - $ex || $py($i) < $ey || $py($i) > $val(y) - $ey} {
                set dmean [expr atan2($val(y) / 2.0 - $py($i), $val(x) / 2.0 - $px($i))]
            }
            set s  [expr $alpha * $s  + (1 - $alpha) * $smean + $k * $ssd * [Nrm]]
            set th [expr $alpha * $th + (1 - $alpha) * $dmean + $k * $dsd * [Nrm]]
            if {$s < $vmin} { set s $vmin }
            if {$s > $vmax} { set s $vmax }
            set nx [expr $px($i) + $s * cos($th) * $gm_dt]
            set ny [expr $py($i) + $s * sin($th) * $gm_dt]
            # reflect at the boundary
            if {$nx < $margin}                { set nx [expr 2 * $margin - $nx];             set th [expr $PI - $th] }
            if {$nx > $val(x) - $margin}      { set nx [expr 2 * ($val(x) - $margin) - $nx]; set th [expr $PI - $th] }
            if {$ny < $margin}                { set ny [expr 2 * $margin - $ny];             set th [expr -$th] }
            if {$ny > $val(y) - $margin}      { set ny [expr 2 * ($val(y) - $margin) - $ny]; set th [expr -$th] }
            set d [expr hypot($nx - $px($i), $ny - $py($i))]
            move $i $t $nx $ny [expr $d / $gm_dt]
            set t [expr $t + $gm_dt]
        }

    } else {
        puts "Unknown mobility model: $model"
        exit 1
    }
}

# ---------------- Traffic ----------------
# nflows CBR/UDP flows, random distinct source-destination pairs
set used {}
for {set f 0} {$f < $nflows} {incr f} {
    while {1} {
        set src [expr int([U 0 $val(nn)])]
        set dst [expr int([U 0 $val(nn)])]
        if {$src != $dst && [lsearch $used "$src-$dst"] < 0} { break }
    }
    lappend used "$src-$dst"
    puts $posfd "# flow $f $src -> $dst"

    set udp_($f) [new Agent/UDP]
    $ns attach-agent $node_($src) $udp_($f)
    set null_($f) [new Agent/Null]
    $ns attach-agent $node_($dst) $null_($f)
    $ns connect $udp_($f) $null_($f)

    set cbr_($f) [new Application/Traffic/CBR]
    $cbr_($f) set packetSize_ $pktsize
    $cbr_($f) set rate_ ${rate_kb}kb
    $cbr_($f) attach-agent $udp_($f)
    # stagger starts so route discoveries do not collide
    $ns at [expr 20.0 + $f * 0.5] "$cbr_($f) start"
    $ns at $val(stop) "$cbr_($f) stop"
}

# ---------------- Finish ----------------
for {set i 0} {$i < $val(nn)} {incr i} {
    $ns at $val(stop) "$node_($i) reset"
}
$ns at [expr $val(stop) + 0.01] "finish"

proc finish {} {
    global ns tracefd posfd
    $ns flush-trace
    close $tracefd
    close $posfd
    exit 0
}

$ns run
