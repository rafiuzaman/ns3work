# ============================================================
# extract_metrics.awk
# Paper 1 - OLSR
#
# Metric definitions are kept consistent with the AODV
# extractor used in the Paper 1 experiments.
#
# Metrics:
#   PDR
#   Average End-to-End Delay
#   Throughput
#   Normalized Routing Load (NRL)
#
# OLSR trace observation:
#   OLSR control packets appear at the RTR layer as:
#
#       type = undefined
#       size = 48
#
#   and are identified by payload:
#
#       [HELLO ...]
#       [TC ...]
#
# Therefore, transmitted HELLO and TC packets are counted
# as OLSR routing-control transmissions.
# ============================================================


BEGIN {
    sent = 0
    received = 0
    routing = 0
}


{
    event = $1
    time  = $2
    layer = $4
    type  = $7
    pkt_size = $8
    seq = $11


    # --------------------------------------------------------
    # DATA PACKETS TRANSMITTED
    # --------------------------------------------------------

    if (event == "s" &&
        layer == "AGT" &&
        type == "cbr") {

        sent++

        # Store transmission time using the same packet
        # sequence field ($11) used by the AODV extractor.
        send_time[seq] = time
    }


    # --------------------------------------------------------
    # DATA PACKETS RECEIVED
    # --------------------------------------------------------

    if (event == "r" &&
        layer == "AGT" &&
        type == "cbr") {

        received++

        # End-to-end delay
        if (seq in send_time) {

            delay += (time - send_time[seq])

            delete send_time[seq]
        }

        # Received data bytes
        bytes += pkt_size
    }


    # --------------------------------------------------------
    # OLSR ROUTING-CONTROL TRANSMISSIONS
    # --------------------------------------------------------
    #
    # In the actual OLSR trace:
    #
    #   s ... RTR ... undefined 48 ... [HELLO ...]
    #   s ... RTR ... undefined 48 ... [TC ...]
    #
    # Count only transmitted routing-control packets.
    #
    # Do NOT count received control packets because one
    # transmission can be received by multiple nodes.
    #

    if (event == "s" &&
        layer == "RTR" &&
        type == "undefined" &&
        ($0 ~ /\[HELLO/ || $0 ~ /\[TC/)) {

        routing++
    }
}


END {

    # --------------------------------------------------------
    # Avoid division by zero
    # --------------------------------------------------------

    if (sent == 0 || received == 0) {

        print "PDR 0"
        print "Delay 0"
        print "Throughput 0"
        print "NRL 0"

        exit
    }


    # --------------------------------------------------------
    # Packet Delivery Ratio
    # --------------------------------------------------------

    pdr = (received / sent) * 100


    # --------------------------------------------------------
    # Average End-to-End Delay
    # --------------------------------------------------------

    avg_delay = delay / received


    # --------------------------------------------------------
    # Throughput
    #
    # Same definition as AODV:
    #
    #   throughput = received bits / simulation time
    #
    # Output unit: Mbps
    # --------------------------------------------------------

    throughput = (bytes * 8) / simtime / 1000000


    # --------------------------------------------------------
    # Normalized Routing Load
    #
    # Same definition as AODV:
    #
    #   NRL = routing-control transmissions /
    #         received data packets
    # --------------------------------------------------------

    nrl = routing / received


    # --------------------------------------------------------
    # Output
    # --------------------------------------------------------

    printf("PDR %.6f\n", pdr)
    printf("Delay %.15f\n", avg_delay)
    printf("Throughput %.6f\n", throughput)
    printf("NRL %.6f\n", nrl)
}
