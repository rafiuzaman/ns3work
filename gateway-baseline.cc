/*
 * gateway-baseline.cc
 *
 * Baseline scenario: MANET nodes running AODV, connected to the wired
 * Internet through gateway node(s), no adaptive/fuzzy gateway discovery
 * yet -- this is step 1, to confirm the topology and traffic flow work
 * end-to-end before we layer the Mamdani fuzzy controller on top.
 *
 * Topology mirrors the "sparse" scenario from the 2014 INDICON paper:
 *   - 15 MANET nodes, WiFi ad-hoc (802.11b), Random Waypoint mobility
 *   - 2 gateway nodes, each with a point-to-point link to a wired
 *     "Internet" node
 *   - AODV routing on the MANET side
 *   - CBR/UDP traffic from MANET nodes toward the Internet node
 *   - FlowMonitor collects PDR, delay, throughput
 *
 * Build/run (from ns-3.48 root):
 *   cp gateway-baseline.cc scratch/
 *   ./ns3 run scratch/gateway-baseline
 */

#include "ns3/core-module.h"
#include "ns3/network-module.h"
#include "ns3/mobility-module.h"
#include "ns3/wifi-module.h"
#include "ns3/internet-module.h"
#include "ns3/aodv-module.h"
#include "ns3/point-to-point-module.h"
#include "ns3/applications-module.h"
#include "ns3/flow-monitor-module.h"
#include "ns3/netanim-module.h"

#include <algorithm> // std::min, for clamping numSources to numManetNodes
#include <memory>    // std::unique_ptr, so the NetAnim trace can be optional
#include <string>

using namespace ns3;

NS_LOG_COMPONENT_DEFINE("GatewayBaseline");

int
main(int argc, char* argv[])
{
    // ---- DIAGNOSTIC LOGGING ----
    // Disabled by default now: it did its job (proved the RouteInputError
    // flood was fixed by the static-vs-AODV priority change) but made even a
    // short run painfully slow and produced multi-GB logs at simTime=900.
    // Re-enable via --diagLog=1 for a short, targeted debugging run only.
    bool diagLog = false;

    // ---- Simulation parameters (matching 2014_INDICON sparse scenario) ----
    uint32_t numManetNodes = 15;
    uint32_t numGateways = 2;
    double simTime = 900.0;       // seconds, matches original paper
    double areaSize = 1000.0;     // meters, square area side length
    double range = 250.0;         // meters, WiFi transmission range (Hamidian's value)
    uint32_t numSources = 5;      // CBR sources (Hamidian uses 5 of 15 nodes)
    uint32_t cbrRateBps = 20480;  // 5 packets/s x 512 bytes x 8 = 20480 bit/s
    bool enableAnim = false;      // NetAnim tracing is slow; opt in with --anim=1
    double nodeSpeedMin = 1.0;    // m/s
    double nodeSpeedMax = 6.0;    // m/s
    double pauseTime = 2.0;       // seconds
    uint16_t port = 9;

    // ---- Diagnostic switches ----
    // "target" decides WHERE the CBR traffic is sent, which splits the two
    // possible causes of the 0% delivery apart in a single fast run each:
    //   target=internet (default) -- sink is the wired Internet node, 10.2.1.2.
    //       Exercises the full path: multi-hop AODV across the MANET, then the
    //       gateway's point-to-point link.
    //   target=gateway -- sink is gateway 0's WiFi address, which is ON the
    //       MANET subnet. Exercises ONLY multi-hop AODV inside the WiFi cloud;
    //       the wired side is never touched.
    // If "gateway" delivers and "internet" does not, the fault is specific to
    // AODV over the point-to-point links. If BOTH fail, the MANET itself is not
    // carrying traffic (most likely the 1000x1000 m area leaves 15 nodes too
    // sparse to stay connected at ~250 m of radio range), which "areaSize"
    // then lets us confirm without another rebuild.
    std::string target = "internet";

    CommandLine cmd(__FILE__);
    cmd.AddValue("numManetNodes", "Number of MANET (mobile) nodes", numManetNodes);
    cmd.AddValue("numGateways", "Number of gateway nodes", numGateways);
    cmd.AddValue("simTime", "Simulation time (s)", simTime);
    cmd.AddValue("areaSize", "Side length of the square area (m)", areaSize);
    cmd.AddValue("range", "WiFi transmission range (m) for RangePropagationLossModel", range);
    cmd.AddValue("numSources", "How many MANET nodes generate CBR traffic", numSources);
    cmd.AddValue("cbrRateBps", "Per-source CBR rate in bit/s", cbrRateBps);
    cmd.AddValue("anim", "Write a NetAnim trace (slow; off by default)", enableAnim);
    cmd.AddValue("target", "Traffic sink: 'internet' (wired node) or 'gateway' (on-subnet)", target);
    cmd.AddValue("diagLog", "Enable verbose AODV/routing diagnostic logging (slow)", diagLog);
    cmd.Parse(argc, argv);

    if (diagLog)
    {
        LogComponentEnable("AodvRoutingProtocol", LOG_LEVEL_LOGIC);
        LogComponentEnable("Ipv4L3Protocol", LOG_LEVEL_LOGIC);
        LogComponentEnable("Ipv4StaticRouting", LOG_LEVEL_LOGIC);
        LogComponentEnable("Ipv4ListRouting", LOG_LEVEL_LOGIC);
    }

    NS_LOG_UNCOND("Config: area " << areaSize << "x" << areaSize << " m, range " << range
                                  << " m, sources " << numSources << "/" << numManetNodes << " at "
                                  << cbrRateBps << " bit/s, anim " << (enableAnim ? "on" : "off"));
    NS_LOG_UNCOND("Gateway Baseline: " << numManetNodes << " MANET nodes, "
                                        << numGateways << " gateways, "
                                        << simTime << "s simulation");

    // ---- Create node containers ----
    NodeContainer manetNodes;
    manetNodes.Create(numManetNodes);

    NodeContainer gatewayNodes;
    gatewayNodes.Create(numGateways);

    NodeContainer internetNode;
    internetNode.Create(1);

    // Gateways participate in both the MANET (WiFi) and the wired side,
    // so include them in the WiFi node set too.
    NodeContainer wifiNodes;
    wifiNodes.Add(manetNodes);
    wifiNodes.Add(gatewayNodes);

    // ---- WiFi (ad-hoc, 802.11b) on the MANET side ----
    WifiHelper wifi;
    wifi.SetStandard(WIFI_STANDARD_80211b);
    wifi.SetRemoteStationManager("ns3::ConstantRateWifiManager",
                                  "DataMode", StringValue("DsssRate11Mbps"),
                                  "ControlMode", StringValue("DsssRate1Mbps"));

    // Propagation: a hard-edged range model rather than YansWifiChannelHelper's
    // default log-distance one.
    //
    // This is what was actually killing the simulation. The default channel
    // combines LogDistancePropagationLossModel (exponent 3, 46.68 dB reference
    // loss at 1 m) with ~16 dBm of transmit power, and decoding DsssRate11Mbps
    // needs roughly -84 dBm at the receiver. Solving 16.02 - (46.68 +
    // 30*log10(d)) = -84 gives a usable range of about 58 METRES, not the 250 m
    // the scenario was written around. Fifteen nodes spread over 1000x1000 m at
    // 58 m of range have on average 0.16 neighbours each -- they are islands, so
    // every AODV route request went unanswered and every packet was dropped with
    // ROUTE_ERROR. No amount of routing configuration could have fixed that.
    //
    // RangePropagationLossModel gives a clean, deterministic disc of radius
    // "range": perfect reception inside it, nothing outside. That matches how
    // the transmission range is specified in Hamidian's thesis (250 m) and in
    // the INDICON paper this work extends, and it makes connectivity a property
    // we control rather than an accident of the link budget.
    YansWifiChannelHelper wifiChannel;
    wifiChannel.SetPropagationDelay("ns3::ConstantSpeedPropagationDelayModel");
    wifiChannel.AddPropagationLoss("ns3::RangePropagationLossModel",
                                    "MaxRange", DoubleValue(range));
    YansWifiPhyHelper wifiPhy;
    wifiPhy.SetChannel(wifiChannel.Create());

    WifiMacHelper wifiMac;
    wifiMac.SetType("ns3::AdhocWifiMac");

    NetDeviceContainer wifiDevices = wifi.Install(wifiPhy, wifiMac, wifiNodes);

    // ---- Mobility: Random Waypoint for MANET nodes, gateways fixed ----
    // RandomWaypointMobilityModel needs its own "PositionAllocator" attribute
    // (used internally to pick each new waypoint) in addition to the
    // MobilityHelper's allocator (used once, to place nodes at t=0). Building
    // it as an actual object via CreateObjectWithAttributes and passing it as
    // a PointerValue avoids ns-3.48's nested-object string-parsing assert
    // that a hand-written "ns3::Foo[X=...]" attribute string triggers.
    Ptr<UniformRandomVariable> posX = CreateObject<UniformRandomVariable>();
    posX->SetAttribute("Min", DoubleValue(0.0));
    posX->SetAttribute("Max", DoubleValue(areaSize));
    Ptr<UniformRandomVariable> posY = CreateObject<UniformRandomVariable>();
    posY->SetAttribute("Min", DoubleValue(0.0));
    posY->SetAttribute("Max", DoubleValue(areaSize));

    Ptr<RandomRectanglePositionAllocator> initialPositionAlloc =
        CreateObject<RandomRectanglePositionAllocator>();
    initialPositionAlloc->SetAttribute("X", PointerValue(posX));
    initialPositionAlloc->SetAttribute("Y", PointerValue(posY));

    Ptr<UniformRandomVariable> waypointX = CreateObject<UniformRandomVariable>();
    waypointX->SetAttribute("Min", DoubleValue(0.0));
    waypointX->SetAttribute("Max", DoubleValue(areaSize));
    Ptr<UniformRandomVariable> waypointY = CreateObject<UniformRandomVariable>();
    waypointY->SetAttribute("Min", DoubleValue(0.0));
    waypointY->SetAttribute("Max", DoubleValue(areaSize));

    Ptr<RandomRectanglePositionAllocator> waypointPositionAlloc =
        CreateObject<RandomRectanglePositionAllocator>();
    waypointPositionAlloc->SetAttribute("X", PointerValue(waypointX));
    waypointPositionAlloc->SetAttribute("Y", PointerValue(waypointY));

    MobilityHelper mobility;
    mobility.SetPositionAllocator(initialPositionAlloc);
    mobility.SetMobilityModel(
        "ns3::RandomWaypointMobilityModel",
        "Speed", StringValue("ns3::UniformRandomVariable[Min=" + std::to_string(nodeSpeedMin) +
                              "|Max=" + std::to_string(nodeSpeedMax) + "]"),
        "Pause", StringValue("ns3::ConstantRandomVariable[Constant=" + std::to_string(pauseTime) +
                              "]"),
        "PositionAllocator", PointerValue(waypointPositionAlloc));
    mobility.Install(manetNodes);

    // Gateways stay at fixed, spread-out positions (e.g. corners of the area)
    MobilityHelper gwMobility;
    Ptr<ListPositionAllocator> gwPositions = CreateObject<ListPositionAllocator>();
    for (uint32_t i = 0; i < numGateways; ++i)
    {
        double x = (i % 2 == 0) ? 0.0 : areaSize;
        double y = (i < 2) ? 0.0 : areaSize;
        gwPositions->Add(Vector(x, y, 0.0));
    }
    gwMobility.SetPositionAllocator(gwPositions);
    gwMobility.SetMobilityModel("ns3::ConstantPositionMobilityModel");
    gwMobility.Install(gatewayNodes);

    // The wired "Internet" node also needs a mobility model (fixed position)
    // -- otherwise NetAnim warns and its trace places the node at the origin.
    MobilityHelper internetMobility;
    Ptr<ListPositionAllocator> internetPosition = CreateObject<ListPositionAllocator>();
    internetPosition->Add(Vector(areaSize / 2.0, areaSize + 100.0, 0.0));
    internetMobility.SetPositionAllocator(internetPosition);
    internetMobility.SetMobilityModel("ns3::ConstantPositionMobilityModel");
    internetMobility.Install(internetNode);

    // ---- Internet stack: AODV on the MANET side, but every node also gets
    // an explicit static routing slot in its Ipv4ListRouting stack, because
    // Ipv4StaticRoutingHelper::GetStaticRouting() returns a null Ptr if the
    // node's routing stack has no static routing component to find -- and,
    // contrary to what we first assumed, plain AodvHelper does NOT add one
    // automatically. Both the MANET/gateway stack and the Internet node's
    // stack are built the same way (AODV or global + static) so the later
    // static-route calls on gateways and on the Internet node both succeed.
    Ipv4StaticRoutingHelper staticRoutingHelperForList;

    // AODV is installed on EVERY node -- MANET nodes, gateways, AND the wired
    // "Internet" node -- and on every interface, including the gateway<->Internet
    // point-to-point links.
    //
    // Why: the previous approach (static host route on each MANET node pointing
    // at the gateway's WiFi address) cannot work, and the logs proved it. A
    // static route's next hop must be reachable in ONE layer-2 hop, because
    // ns-3 then ARPs for that next-hop address on the given interface. The
    // gateways sit at fixed corners (0,0) and (1000,0) while the 15 MANET nodes
    // roam a 1000x1000 m area with roughly 250 m of radio range, so the large
    // majority of nodes are several hops away from any gateway. Their ARP
    // requests for 10.1.1.16 (broadcast, one hop only) were never answered, so
    // every Internet-bound packet was dropped at the source -- Tx 19920, Rx 0.
    //
    // Multi-hop forwarding is exactly what AODV exists to do, so the fix is to
    // stop routing around it and let it own the whole path. With AODV on the
    // Internet node too, a source's RREQ for 10.2.1.2 floods hop-by-hop across
    // the MANET, reaches a gateway, is rebroadcast out that gateway's p2p
    // interface, and the Internet node -- being the destination -- answers with
    // an RREP that travels the reverse path. One ordinary AODV route, end to
    // end, no static stand-ins and no L2 adjacency assumption.
    //
    // Static routing stays in the list at priority 0 purely as an unused
    // fallback slot, so Ipv4StaticRoutingHelper::GetStaticRouting() still
    // returns a valid pointer if later code (e.g. the trust-aware gateway
    // selection layer) wants to inject a route by hand.
    AodvHelper aodv;
    Ipv4ListRoutingHelper aodvListRouting;
    aodvListRouting.Add(staticRoutingHelperForList, 0);
    aodvListRouting.Add(aodv, 10); // AODV wins the lookup, as it normally should

    InternetStackHelper internetStackAodv;
    internetStackAodv.SetRoutingHelper(aodvListRouting);
    internetStackAodv.Install(manetNodes);
    internetStackAodv.Install(gatewayNodes);
    internetStackAodv.Install(internetNode);

    // ---- Assign IP addresses on the WiFi (MANET) subnet ----
    Ipv4AddressHelper ipv4;
    ipv4.SetBase("10.1.1.0", "255.255.255.0");
    Ipv4InterfaceContainer wifiInterfaces = ipv4.Assign(wifiDevices);

    // ---- Point-to-point links: each gateway <-> the Internet node ----
    PointToPointHelper p2p;
    p2p.SetDeviceAttribute("DataRate", StringValue("5Mbps"));
    p2p.SetChannelAttribute("Delay", StringValue("2ms"));

    std::vector<Ipv4InterfaceContainer> p2pInterfaces;
    for (uint32_t i = 0; i < numGateways; ++i)
    {
        NodeContainer link(gatewayNodes.Get(i), internetNode.Get(0));
        NetDeviceContainer devs = p2p.Install(link);

        std::ostringstream subnet;
        subnet << "10.2." << (i + 1) << ".0";
        Ipv4AddressHelper ipv4p2p;
        ipv4p2p.SetBase(subnet.str().c_str(), "255.255.255.0");
        p2pInterfaces.push_back(ipv4p2p.Assign(devs));
    }

    // ---- Routing is now entirely AODV's job ----
    // Every manual static route that used to live here has been removed. They
    // were all attempts to paper over the fact that the Internet node was not
    // running AODV: a network route on the Internet node back to 10.1.1.0/24,
    // a host route on each gateway out its p2p link, and a host route on every
    // MANET node pointing at the gateway's WiFi address. The last of those was
    // the fatal one -- it assumed the gateway was a single layer-2 hop away,
    // which for nodes roaming a 1000x1000 m area with ~250 m of range it almost
    // never is, so ARP for the next hop went unanswered and every packet died
    // at the source.
    //
    // With AODV installed on all three groups of nodes and on every interface,
    // route discovery spans the WiFi cloud and the wired links as one network,
    // and each of those routes is now learned dynamically in both directions.
    // Nothing needs to be hand-wired.

    // ---- Traffic: CBR/UDP from each MANET node toward the chosen sink ----
    // Default sink is the Internet node's address on the FIRST gateway's p2p
    // link (10.2.1.2). With --target=gateway the sink is instead gateway 0's
    // WiFi address, which keeps all traffic inside the MANET subnet so we can
    // tell a MANET-connectivity problem apart from a wired-side one.
    Ipv4Address sinkAddress;
    if (target == "gateway")
    {
        sinkAddress = wifiInterfaces.GetAddress(numManetNodes); // gateway 0, WiFi side
    }
    else
    {
        sinkAddress = p2pInterfaces[0].GetAddress(1); // Internet node, wired side
    }
    NS_LOG_UNCOND("Traffic sink: " << target << " (" << sinkAddress << ")");

    // A sink application is installed on the Internet node AND on every gateway,
    // so whichever address --target selects already has a listener on that port.
    PacketSinkHelper sinkHelper("ns3::UdpSocketFactory",
                                 InetSocketAddress(Ipv4Address::GetAny(), port));
    ApplicationContainer sinkApp = sinkHelper.Install(internetNode.Get(0));
    sinkApp.Add(sinkHelper.Install(gatewayNodes));
    sinkApp.Start(Seconds(0.0));
    sinkApp.Stop(Seconds(simTime));

    // CBR traffic following Hamidian's thesis: 5 packets/s of 512 bytes, which
    // is 5 * 512 * 8 = 20480 bit/s per source. Only the first --numSources of
    // the MANET nodes generate traffic (the thesis uses 5 of 15), not all of
    // them. Running all 15 as sources at 64 kbps, as this script originally
    // did, loads the shared 802.11b medium heavily enough that queue overflow
    // starts to dominate the results -- which would confound the later
    // trust-aware vs baseline comparison, where we want the difference to come
    // from gateway selection rather than from congestion.
    OnOffHelper onoff("ns3::UdpSocketFactory", InetSocketAddress(sinkAddress, port));
    onoff.SetAttribute("DataRate", DataRateValue(DataRate(cbrRateBps)));
    onoff.SetAttribute("PacketSize", UintegerValue(512));
    onoff.SetAttribute("OnTime", StringValue("ns3::ConstantRandomVariable[Constant=1]"));
    onoff.SetAttribute("OffTime", StringValue("ns3::ConstantRandomVariable[Constant=0]"));

    uint32_t actualSources = std::min(numSources, numManetNodes);
    ApplicationContainer sourceApps;
    for (uint32_t i = 0; i < actualSources; ++i)
    {
        sourceApps.Add(onoff.Install(manetNodes.Get(i)));
    }
    sourceApps.Start(Seconds(10.0));
    sourceApps.Stop(Seconds(simTime - 5.0));

    // ---- FlowMonitor for PDR / delay / throughput ----
    FlowMonitorHelper flowmonHelper;
    Ptr<FlowMonitor> flowMonitor = flowmonHelper.InstallAll();

    // ---- NetAnim trace (optional, for visual sanity-checking) ----
    // Off by default. AnimationInterface records every packet, which both slows
    // the run down substantially and blows past its own trace-file limit on any
    // reasonably long simulation ("Max Packets per trace file exceeded"). Enable
    // it only for short runs you actually intend to watch: --anim=1
    std::unique_ptr<AnimationInterface> anim;
    if (enableAnim)
    {
        anim = std::make_unique<AnimationInterface>("gateway-baseline.xml");
        anim->SetMaxPktsPerTraceFile(500000);
    }

    Simulator::Stop(Seconds(simTime));
    Simulator::Run();

    // ---- Print summary stats ----
    flowMonitor->CheckForLostPackets();
    Ptr<Ipv4FlowClassifier> classifier =
        DynamicCast<Ipv4FlowClassifier>(flowmonHelper.GetClassifier());
    FlowMonitor::FlowStatsContainer stats = flowMonitor->GetFlowStats();

    // Count ONLY the CBR data flows -- those addressed to the sink on our
    // application port. FlowMonitor sees every flow in the simulation, which
    // includes AODV's own RREQ/RREP control traffic on port 654 and its
    // broadcasts; summing all of them dilutes PDR with packets that were never
    // application data. (Before this filter a 5-source run reported Tx = 3172
    // where only ~2125 CBR packets had actually been generated.)
    double totalTxPackets = 0, totalRxPackets = 0, totalDelaySum = 0;
    double totalRxBytes = 0;
    uint32_t dataFlows = 0;
    for (auto const& flow : stats)
    {
        Ipv4FlowClassifier::FiveTuple t = classifier->FindFlow(flow.first);
        if (t.destinationAddress != sinkAddress || t.destinationPort != port)
        {
            continue;
        }
        ++dataFlows;
        totalTxPackets += flow.second.txPackets;
        totalRxPackets += flow.second.rxPackets;
        totalRxBytes += flow.second.rxBytes;
        totalDelaySum += flow.second.delaySum.GetSeconds();
    }

    // Aggregate throughput over the interval the sources were actually active.
    double trafficDuration = (simTime - 5.0) - 10.0;
    double throughputKbps =
        (trafficDuration > 0) ? (totalRxBytes * 8.0 / trafficDuration / 1000.0) : 0.0;

    double pdr = (totalTxPackets > 0) ? (totalRxPackets / totalTxPackets) * 100.0 : 0.0;
    double avgDelay = (totalRxPackets > 0) ? (totalDelaySum / totalRxPackets) : 0.0;

    NS_LOG_UNCOND("\n---- Baseline Results (CBR data flows only) ----");
    NS_LOG_UNCOND("Data flows: " << dataFlows);
    NS_LOG_UNCOND("Tx Packets: " << totalTxPackets);
    NS_LOG_UNCOND("Rx Packets: " << totalRxPackets);
    NS_LOG_UNCOND("Packet Delivery Ratio: " << pdr << " %");
    NS_LOG_UNCOND("Average End-to-End Delay: " << avgDelay << " s");
    NS_LOG_UNCOND("Aggregate Throughput: " << throughputKbps << " kbps");

    // ---- Per-flow breakdown with DROP REASONS ----
    // A bare "Rx = 0" says nothing about why. FlowMonitor already records a
    // per-reason drop histogram on every flow, so printing it costs one cheap
    // loop at the end of the run and replaces a whole round of verbose-logging
    // guesswork. DROP_NO_ROUTE dominating means AODV never resolved a route at
    // all; DROP_QUEUE means it did but the interface queue overflowed;
    // DROP_TTL_EXPIRE means packets are looping.
    NS_LOG_UNCOND("\n---- Per-flow detail (drop reasons) ----");
    NS_LOG_UNCOND("reason codes: 0=NO_ROUTE 1=TTL_EXPIRE 2=BAD_CHECKSUM "
                  "3=QUEUE 4=QUEUE_DISC 5=INTERFACE_DOWN 6=ROUTE_ERROR "
                  "7=FRAGMENT_TIMEOUT 8=INVALID_REASON");
    NS_LOG_UNCOND("flows recorded: " << stats.size());

    uint32_t shown = 0;
    for (auto const& flow : stats)
    {
        Ipv4FlowClassifier::FiveTuple t = classifier->FindFlow(flow.first);
        if (t.destinationAddress != sinkAddress || t.destinationPort != port)
        {
            continue; // skip AODV control traffic, show data flows only
        }
        if (shown++ >= 8)
        {
            NS_LOG_UNCOND("... (remaining data flows omitted)");
            break;
        }
        NS_LOG_UNCOND("Flow " << flow.first << "  " << t.sourceAddress << " -> "
                              << t.destinationAddress << "  Tx=" << flow.second.txPackets
                              << "  Rx=" << flow.second.rxPackets
                              << "  Lost=" << flow.second.lostPackets);
        for (uint32_t r = 0; r < flow.second.packetsDropped.size(); ++r)
        {
            if (flow.second.packetsDropped[r] > 0)
            {
                NS_LOG_UNCOND("      dropped[reason " << r
                                                      << "] = " << flow.second.packetsDropped[r]);
            }
        }
    }

    flowMonitor->SerializeToXmlFile("gateway-baseline-flowmon.xml", true, true);

    Simulator::Destroy();
    return 0;
}
