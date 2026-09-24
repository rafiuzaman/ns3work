BEGIN {
    sent=0; received=0; routing=0;
    bytes=0; delay=0;

    link_breaks=0;
    route_start=0; route_fail=0;
    pst_total=0;
}

{
    event=$1
    time=$2
    layer=$4
    type=$7
    pkt_size=$8
    seq=$11
    last_field=$NF

    # -------------------------------
    # Data Packets (AGT Layer)
    # -------------------------------
    if (event=="s" && layer=="AGT" && type=="cbr") {
        sent++
        send_time[seq]=time
    }

    if (event=="r" && layer=="AGT" && type=="cbr") {
        received++
        if (seq in send_time) {
            delay += (time - send_time[seq])
            delete send_time[seq]
        }
        bytes += pkt_size
    }

    # -------------------------------
    # Routing Load (NRL)
    # -------------------------------
    if (event=="s" && layer=="RTR" && type=="AODV") {
        routing++
    }

    # -------------------------------
    # Link Breakage Rate (RERR events)
    # -------------------------------
    if (event=="s" && layer=="RTR" && type=="AODV" && last_field=="(ERROR)") {
        link_breaks++
        route_fail++
        if (route_fail in route_time) {
            pst_total += (time - route_time[route_fail])
        }
    }

    # -------------------------------
    # Route Establishment (RREP)
    # -------------------------------
    if (event=="s" && layer=="RTR" && type=="AODV" && last_field=="(REPLY)") {
        route_start++
        route_time[route_start] = time
    }
}

END {

    if (sent==0 || received==0) {
        print "PDR 0"
        print "Delay 0"
        print "Throughput 0"
        print "NRL 0"
        print "LBR 0"
        print "PST 0"
        exit
    }

    # -------------------------------
    # QoS Metrics
    # -------------------------------
    pdr = (received/sent)*100
    avg_delay = delay/received
    throughput = (bytes*8)/(simtime*1000000)
    nrl = routing/received

    # -------------------------------
    # Mobility-Aware Metrics
    # -------------------------------
    lbr = link_breaks / simtime

    if (route_fail > 0)
        pst = pst_total / route_fail
    else
        pst = 0

    # -------------------------------
    # Print Results
    # -------------------------------
    printf("PDR %.6f\n", pdr)
    printf("Delay %.15f\n", avg_delay)
    printf("Throughput %.6f\n", throughput)
    printf("NRL %.6f\n", nrl)
    printf("LBR %.6f\n", lbr)
    printf("PST %.6f\n", pst)
}
