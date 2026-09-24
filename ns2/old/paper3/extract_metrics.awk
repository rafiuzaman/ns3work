BEGIN {
    sent=0; received=0; routing=0;
}

{
    event=$1
    time=$2
    layer=$4
    type=$7
    pkt_size=$8
    seq=$11

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

    # Count only routing packets transmitted
    if (event=="s" && layer=="RTR" && type=="AODV") {
        routing++
    }
}

END {
    if (sent==0 || received==0) {
        print "PDR 0"
        print "Delay 0"
        print "Throughput 0"
        print "NRL 0"
        exit
    }

    pdr = (received/sent)*100
    avg_delay = delay/received
    throughput = (bytes*8)/simtime/1000000
    nrl = routing/received

    printf("PDR %.6f\n", pdr)
    printf("Delay %.15f\n", avg_delay)
    printf("Throughput %.6f\n", throughput)
    printf("NRL %.6f\n", nrl)
}
