# ==========================================================
# mobility.tcl - OLSR version for Paper 1
# Usage:
# ns mobility.tcl <seed> <model> <nodes> <tracefile> <rate>
# Example:
# ns mobility.tcl 1 RWP 25 traces/OLSR_RWP_25nodes_seed1.tr 128kb
# ==========================================================

if {$argc != 5} {
    puts "Usage: ns mobility.tcl <seed> <model> <nodes> <tracefile> <rate>"
    exit 1
}

set seed      [lindex $argv 0]
set model     [lindex $argv 1]
set val(nn)   [lindex $argv 2]
set tracefile [lindex $argv 3]
set rate      [lindex $argv 4]

# ---------------- Simulation Parameters ----------------
set val(chan) Channel/WirelessChannel
set val(prop) Propagation/TwoRayGround
set val(netif) Phy/WirelessPhy
set val(mac) Mac/802_11
set val(ifq) Queue/DropTail/PriQueue
set val(ll) LL
set val(ant) Antenna/OmniAntenna
set val(ifqlen) 50
set val(rp) OLSR

# Topology
set val(x) 600
set val(y) 400
set val(stop) 1000

# Mobility Parameters
set pause 100
set speed_min 1
set speed_max 3
set alpha 0.75

ns-random $seed
set ns [new Simulator]

# Create trace directory if needed
set dirname [file dirname $tracefile]
if {![file exists $dirname]} {
    file mkdir $dirname
}

set tracefd [open $tracefile w]
$ns trace-all $tracefd

set topo [new Topography]
$topo load_flatgrid $val(x) $val(y)
create-god $val(nn)

set chan [new $val(chan)]

$ns node-config \
    -adhocRouting $val(rp) \
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
    -macTrace OFF

# ---------------- Create Nodes ----------------
for {set i 0} {$i < $val(nn)} {incr i} {
    set node_($i) [$ns node]
    $node_($i) set X_ [expr rand()*$val(x)]
    $node_($i) set Y_ [expr rand()*$val(y)]
    $node_($i) set Z_ 0
}

# ==========================================================
# ===================== MOBILITY ===========================
# ==========================================================

if {$model == "RWP"} {

    for {set i 0} {$i < $val(nn)} {incr i} {
        set t 0
        while {$t < $val(stop)} {

            set nx [expr rand()*$val(x)]
            set ny [expr rand()*$val(y)]
            set speed [expr $speed_min + rand()*($speed_max-$speed_min)]

            set x [$node_($i) set X_]
            set y [$node_($i) set Y_]

            set dx [expr $nx - $x]
            set dy [expr $ny - $y]
            set dist [expr sqrt($dx*$dx + $dy*$dy)]
            set travel_time [expr $dist / $speed]

            $ns at $t "$node_($i) setdest $nx $ny $speed"

            set t [expr $t + $travel_time + $pause]
        }
    }
}

if {$model == "RD"} {

    for {set i 0} {$i < $val(nn)} {incr i} {

        set angle [expr rand()*6.28318]
        set speed [expr $speed_min + rand()*($speed_max-$speed_min)]

        for {set t 0} {$t < $val(stop)} {set t [expr $t + 5]} {

            set x [$node_($i) set X_]
            set y [$node_($i) set Y_]

            set nx [expr $x + $speed*cos($angle)*5]
            set ny [expr $y + $speed*sin($angle)*5]

            if {$nx < 1 || $nx > $val(x)-1} {
                set angle [expr 3.14159 - $angle]
            }
            if {$ny < 1 || $ny > $val(y)-1} {
                set angle [expr -$angle]
            }

            set nx [expr max(1, min($val(x)-1, $nx))]
            set ny [expr max(1, min($val(y)-1, $ny))]

            $ns at $t "$node_($i) setdest $nx $ny $speed"
        }
    }
}

if {$model == "GM"} {

    for {set i 0} {$i < $val(nn)} {incr i} {

        set speed [expr $speed_min + rand()*($speed_max-$speed_min)]
        set angle [expr rand()*6.28318]

        for {set t 0} {$t < $val(stop)} {set t [expr $t + 5]} {

            set speed [expr $alpha*$speed + (1-$alpha)*($speed_min + rand()*($speed_max-$speed_min))]
            set angle [expr $alpha*$angle + (1-$alpha)*(rand()*6.28318)]

            set x [$node_($i) set X_]
            set y [$node_($i) set Y_]

            set nx [expr $x + $speed*cos($angle)*5]
            set ny [expr $y + $speed*sin($angle)*5]

            set nx [expr max(1, min($val(x)-1, $nx))]
            set ny [expr max(1, min($val(y)-1, $ny))]

            $ns at $t "$node_($i) setdest $nx $ny $speed"
        }
    }
}

# ==========================================================
# ===================== TRAFFIC ============================
# ==========================================================

set packetSize 512

for {set i 0} {$i < 5} {incr i} {

    set src $i
    set dst [expr ($i + 20) % $val(nn)]

    set udp_($i) [new Agent/UDP]
    $ns attach-agent $node_($src) $udp_($i)

    set null_($i) [new Agent/Null]
    $ns attach-agent $node_($dst) $null_($i)

    $ns connect $udp_($i) $null_($i)

    set cbr_($i) [new Application/Traffic/CBR]
    $cbr_($i) set packetSize_ $packetSize
    $cbr_($i) set rate_ $rate
    $cbr_($i) attach-agent $udp_($i)

    $ns at 20.0 "$cbr_($i) start"
}

$ns at $val(stop) "finish"

proc finish {} {
    global ns tracefd
    $ns flush-trace
    close $tracefd
    exit 0
}

$ns run
