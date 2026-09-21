/*
 * gateway-discovery.cc
 *
 * AODV+ style gateway discovery for MANET-Internet integration, implemented
 * in ns-3 at the application layer, covering all three discovery mechanisms
 * described in Hamidian's thesis:
 *
 *   proactive -- gateways periodically flood GWADV advertisements
 *   reactive  -- gateways stay silent; nodes flood GWSOL solicitations and
 *                gateways answer with a unicast advertisement
 *   hybrid    -- gateways advertise within a limited ADVERTISEMENT_ZONE, and
 *                nodes outside that zone fall back to solicitation
 *
 * Why application layer rather than surgery inside ns-3's AODV: the data path
 * is carried by ordinary AODV routes to the *gateway's own address*, which is
 * on the MANET subnet and therefore something AODV can resolve multi-hop. The
 * gateway then relays the payload onward to the wired Internet host. This is
 * the same idea as AODV+'s encapsulation, and it has two properties we need:
 * the Internet host does not have to run AODV (so the scenario is honest --
 * a real Internet host does not speak an ad hoc routing protocol), and the
 * node's CHOICE of gateway genuinely determines the data path, which is what
 * makes gateway selection measurable at all.
 *
 * Metrics are collected from sequence numbers and timestamps carried in the
 * payload rather than from FlowMonitor, because FlowMonitor sees the relayed
 * traffic as two separate flows (source->gateway, gateway->Internet) and so
 * cannot report true end-to-end delivery. Carrying our own counters also lets
 * us attribute every delivered packet to the gateway that relayed it, which is
 * what shows a malicious gateway being avoided.
 *
 * Build/run (from ns-3.48 root):
 *   cp gateway-discovery.cc scratch/
 *   ./ns3 build
 *   ./ns3 run "scratch/gateway-discovery --mode=proactive --areaSize=750"
 */

#include "ns3/aodv-module.h"
#include "ns3/applications-module.h"
#include "ns3/core-module.h"
#include "ns3/flow-monitor-module.h"
#include "ns3/internet-module.h"
#include "ns3/mobility-module.h"
#include "ns3/netanim-module.h"
#include "ns3/network-module.h"
#include "ns3/point-to-point-module.h"
#include "ns3/wifi-module.h"

#include <algorithm>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <vector>

using namespace ns3;

NS_LOG_COMPONENT_DEFINE("GatewayDiscovery");

// ---------------------------------------------------------------------------
// Control message header
// ---------------------------------------------------------------------------

enum GwMsgType : uint8_t
{
    GW_ADV = 1, // gateway advertisement (Hamidian's GWADV / RREP_I)
    GW_SOL = 2  // gateway solicitation  (Hamidian's GWSOL / RREQ_I)
};

/**
 * Control header shared by advertisements and solicitations.
 *
 * hopCount accumulates as the message is rebroadcast, so a node learns its
 * distance to the gateway. For a solicitation this matters as much as for an
 * advertisement: the solicitation counts hops on its way TO the gateway, and
 * the gateway simply echoes that count back in its unicast reply. That is how
 * the reactive mode establishes a hop count without a second network-wide
 * flood.
 *
 * ttl is the remaining rebroadcast budget. Proactive and reactive floods start
 * with the full network diameter; hybrid advertisements start with the
 * advertisement-zone radius, which is exactly what makes them hybrid.
 */
class GwMsgHeader : public Header
{
  public:
    GwMsgHeader()
        : m_type(GW_ADV),
          m_gwAddr(0),
          m_origin(0),
          m_seqNo(0),
          m_hopCount(0),
          m_ttl(0)
    {
    }

    static TypeId GetTypeId()
    {
        static TypeId tid = TypeId("GwMsgHeader").SetParent<Header>().AddConstructor<GwMsgHeader>();
        return tid;
    }

    TypeId GetInstanceTypeId() const override
    {
        return GetTypeId();
    }

    uint32_t GetSerializedSize() const override
    {
        return 1 + 4 + 4 + 4 + 1 + 1; // type, gwAddr, origin, seqNo, hopCount, ttl
    }

    void Serialize(Buffer::Iterator start) const override
    {
        start.WriteU8(m_type);
        start.WriteHtonU32(m_gwAddr);
        start.WriteHtonU32(m_origin);
        start.WriteHtonU32(m_seqNo);
        start.WriteU8(m_hopCount);
        start.WriteU8(m_ttl);
    }

    uint32_t Deserialize(Buffer::Iterator start) override
    {
        m_type = start.ReadU8();
        m_gwAddr = start.ReadNtohU32();
        m_origin = start.ReadNtohU32();
        m_seqNo = start.ReadNtohU32();
        m_hopCount = start.ReadU8();
        m_ttl = start.ReadU8();
        return GetSerializedSize();
    }

    void Print(std::ostream& os) const override
    {
        os << (m_type == GW_ADV ? "ADV" : "SOL") << " gw=" << Ipv4Address(m_gwAddr)
           << " origin=" << Ipv4Address(m_origin) << " seq=" << m_seqNo
           << " hops=" << (uint32_t)m_hopCount << " ttl=" << (uint32_t)m_ttl;
    }

    void SetType(GwMsgType t)
    {
        m_type = t;
    }

    GwMsgType GetType() const
    {
        return static_cast<GwMsgType>(m_type);
    }

    void SetGateway(Ipv4Address a)
    {
        m_gwAddr = a.Get();
    }

    Ipv4Address GetGateway() const
    {
        return Ipv4Address(m_gwAddr);
    }

    void SetOrigin(Ipv4Address a)
    {
        m_origin = a.Get();
    }

    Ipv4Address GetOrigin() const
    {
        return Ipv4Address(m_origin);
    }

    void SetSeqNo(uint32_t s)
    {
        m_seqNo = s;
    }

    uint32_t GetSeqNo() const
    {
        return m_seqNo;
    }

    void SetHopCount(uint8_t h)
    {
        m_hopCount = h;
    }

    uint8_t GetHopCount() const
    {
        return m_hopCount;
    }

    void SetTtl(uint8_t t)
    {
        m_ttl = t;
    }

    uint8_t GetTtl() const
    {
        return m_ttl;
    }

  private:
    uint8_t m_type;
    uint32_t m_gwAddr;
    uint32_t m_origin;
    uint32_t m_seqNo;
    uint8_t m_hopCount;
    uint8_t m_ttl;
};

// ---------------------------------------------------------------------------
// Data payload header (end-to-end instrumentation)
// ---------------------------------------------------------------------------

/**
 * Carried inside every CBR data packet so the sink can compute true end-to-end
 * delivery and delay across the relay hop, and attribute each packet to the
 * gateway that relayed it.
 */
class DataTagHeader : public Header
{
  public:
    DataTagHeader()
        : m_srcId(0),
          m_seqNo(0),
          m_sendTimeNs(0),
          m_viaGw(0)
    {
    }

    static TypeId GetTypeId()
    {
        static TypeId tid =
            TypeId("DataTagHeader").SetParent<Header>().AddConstructor<DataTagHeader>();
        return tid;
    }

    TypeId GetInstanceTypeId() const override
    {
        return GetTypeId();
    }

    uint32_t GetSerializedSize() const override
    {
        return 4 + 4 + 8 + 4;
    }

    void Serialize(Buffer::Iterator start) const override
    {
        start.WriteHtonU32(m_srcId);
        start.WriteHtonU32(m_seqNo);
        start.WriteHtonU64(m_sendTimeNs);
        start.WriteHtonU32(m_viaGw);
    }

    uint32_t Deserialize(Buffer::Iterator start) override
    {
        m_srcId = start.ReadNtohU32();
        m_seqNo = start.ReadNtohU32();
        m_sendTimeNs = start.ReadNtohU64();
        m_viaGw = start.ReadNtohU32();
        return GetSerializedSize();
    }

    void Print(std::ostream& os) const override
    {
        os << "src=" << m_srcId << " seq=" << m_seqNo << " via=" << Ipv4Address(m_viaGw);
    }

    void SetSrcId(uint32_t v)
    {
        m_srcId = v;
    }

    uint32_t GetSrcId() const
    {
        return m_srcId;
    }

    void SetSeqNo(uint32_t v)
    {
        m_seqNo = v;
    }

    uint32_t GetSeqNo() const
    {
        return m_seqNo;
    }

    void SetSendTime(Time t)
    {
        m_sendTimeNs = t.GetNanoSeconds();
    }

    Time GetSendTime() const
    {
        return NanoSeconds(m_sendTimeNs);
    }

    void SetViaGw(Ipv4Address a)
    {
        m_viaGw = a.Get();
    }

    Ipv4Address GetViaGw() const
    {
        return Ipv4Address(m_viaGw);
    }

  private:
    uint32_t m_srcId;
    uint32_t m_seqNo;
    uint64_t m_sendTimeNs;
    uint32_t m_viaGw;
};

// ---------------------------------------------------------------------------
// Shared statistics
// ---------------------------------------------------------------------------

struct GwStats
{
    uint64_t dataSent = 0;
    uint64_t dataRelayed = 0;
    uint64_t dataReceived = 0;
    uint64_t dataDroppedByMalicious = 0;
    uint64_t advSent = 0;
    uint64_t advForwarded = 0;
    uint64_t solSent = 0;
    uint64_t solForwarded = 0;
    uint64_t advReplies = 0;
    uint64_t noGatewayAtSendTime = 0;
    Time delaySum = Seconds(0);
    std::map<uint32_t, uint64_t> deliveredViaGw; // gateway address -> packets

    uint64_t ControlOverhead() const
    {
        return advSent + advForwarded + solSent + solForwarded + advReplies;
    }
};

static GwStats g_stats;

enum DiscoveryMode
{
    MODE_PROACTIVE,
    MODE_REACTIVE,
    MODE_HYBRID
};

static DiscoveryMode g_mode = MODE_PROACTIVE;

static const uint16_t GW_CTRL_PORT = 6543; // advertisements / solicitations
static const uint16_t GW_RELAY_PORT = 6544; // node -> gateway data
static const uint16_t SINK_PORT = 9;        // gateway -> Internet host

// ---------------------------------------------------------------------------
// GatewayAgent -- runs on each gateway
// ---------------------------------------------------------------------------

/**
 * Advertises the gateway and relays data toward the wired Internet host.
 *
 * In proactive and hybrid mode it broadcasts a GWADV every advInterval; hybrid
 * differs only in that the advertisement's TTL is limited to the advertisement
 * zone rather than the network diameter. In reactive mode it never advertises
 * unsolicited and only answers solicitations.
 *
 * A "malicious" gateway behaves normally for discovery -- it advertises just as
 * attractively as an honest one, and may even advertise more often -- but
 * silently discards a configurable fraction of the data it is trusted to relay.
 * That is the behaviour the trust metric has to detect, and it is invisible to
 * hop-count-based selection.
 */
class GatewayAgent : public Application
{
  public:
    static TypeId GetTypeId()
    {
        static TypeId tid = TypeId("GatewayAgent")
                                .SetParent<Application>()
                                .AddConstructor<GatewayAgent>();
        return tid;
    }


    void Setup(Ipv4Address myWifiAddr,
               Ipv4Address broadcastAddr,
               Ipv4Address internetAddr,
               Time advInterval,
               uint8_t advTtl,
               bool malicious,
               double dropFraction)
    {
        m_myAddr = myWifiAddr;
        m_broadcast = broadcastAddr;
        m_internet = internetAddr;
        m_advInterval = advInterval;
        m_advTtl = advTtl;
        m_malicious = malicious;
        m_dropFraction = dropFraction;
    }

  private:
    void StartApplication() override
    {
        // Control socket: broadcasts advertisements, listens for solicitations.
        m_ctrlSocket = Socket::CreateSocket(GetNode(), UdpSocketFactory::GetTypeId());
        m_ctrlSocket->SetAllowBroadcast(true);
        m_ctrlSocket->Bind(InetSocketAddress(Ipv4Address::GetAny(), GW_CTRL_PORT));
        m_ctrlSocket->SetRecvCallback(MakeCallback(&GatewayAgent::HandleCtrl, this));

        // Relay socket: receives data from MANET nodes that selected us.
        m_relaySocket = Socket::CreateSocket(GetNode(), UdpSocketFactory::GetTypeId());
        m_relaySocket->Bind(InetSocketAddress(Ipv4Address::GetAny(), GW_RELAY_PORT));
        m_relaySocket->SetRecvCallback(MakeCallback(&GatewayAgent::HandleRelay, this));

        // Outbound socket toward the wired Internet host.
        m_outSocket = Socket::CreateSocket(GetNode(), UdpSocketFactory::GetTypeId());
        m_outSocket->Connect(InetSocketAddress(m_internet, SINK_PORT));

        m_rand = CreateObject<UniformRandomVariable>();

        if (g_mode != MODE_REACTIVE)
        {
            // Stagger the first advertisement so the two gateways do not
            // collide on the shared medium every single interval.
            Time jitter = MilliSeconds(m_rand->GetInteger(0, 200));
            m_advEvent = Simulator::Schedule(jitter, &GatewayAgent::SendAdvertisement, this);
        }
    }

    void StopApplication() override
    {
        Simulator::Cancel(m_advEvent);
        if (m_ctrlSocket)
        {
            m_ctrlSocket->Close();
        }
        if (m_relaySocket)
        {
            m_relaySocket->Close();
        }
        if (m_outSocket)
        {
            m_outSocket->Close();
        }
    }

    void SendAdvertisement()
    {
        GwMsgHeader hdr;
        hdr.SetType(GW_ADV);
        hdr.SetGateway(m_myAddr);
        hdr.SetOrigin(m_myAddr);
        hdr.SetSeqNo(++m_seqNo);
        hdr.SetHopCount(0);
        hdr.SetTtl(m_advTtl);

        Ptr<Packet> p = Create<Packet>();
        p->AddHeader(hdr);
        m_ctrlSocket->SendTo(p, 0, InetSocketAddress(m_broadcast, GW_CTRL_PORT));
        ++g_stats.advSent;

        m_advEvent = Simulator::Schedule(m_advInterval, &GatewayAgent::SendAdvertisement, this);
    }

    void HandleCtrl(Ptr<Socket> socket)
    {
        Ptr<Packet> packet;
        Address from;
        while ((packet = socket->RecvFrom(from)))
        {
            GwMsgHeader hdr;
            packet->RemoveHeader(hdr);

            if (hdr.GetType() != GW_SOL)
            {
                continue; // gateways ignore each other's advertisements
            }

            // Answer each solicitation once. A flooded solicitation reaches a
            // gateway by several paths, and without this check the gateway
            // replies to every copy -- which inflated reactive mode's measured
            // overhead to ~4.5 replies per solicitation. Nodes already suppress
            // duplicates on (origin, sequence number) when forwarding; gateways
            // must do the same before answering, or the overhead comparison
            // between the three mechanisms is not a fair one.
            auto key = std::make_pair(hdr.GetOrigin().Get(), hdr.GetSeqNo());
            if (m_seenSol.count(key))
            {
                continue;
            }
            m_seenSol.insert(key);

            // Answer the solicitation directly, echoing back the hop count the
            // solicitation accumulated on its way here. That count IS the
            // distance from the soliciting node to this gateway, so the node
            // learns its hop distance without us flooding a reply.
            GwMsgHeader reply;
            reply.SetType(GW_ADV);
            reply.SetGateway(m_myAddr);
            reply.SetOrigin(m_myAddr);
            reply.SetSeqNo(++m_seqNo);
            reply.SetHopCount(hdr.GetHopCount());
            reply.SetTtl(0); // unicast, never rebroadcast

            Ptr<Packet> p = Create<Packet>();
            p->AddHeader(reply);

            Ptr<Socket> unicast = Socket::CreateSocket(GetNode(), UdpSocketFactory::GetTypeId());
            unicast->Connect(InetSocketAddress(hdr.GetOrigin(), GW_CTRL_PORT));
            unicast->Send(p);
            ++g_stats.advReplies;
        }
    }

    void HandleRelay(Ptr<Socket> socket)
    {
        Ptr<Packet> packet;
        Address from;
        while ((packet = socket->RecvFrom(from)))
        {
            if (m_malicious && m_rand->GetValue(0.0, 1.0) < m_dropFraction)
            {
                // Accepted the traffic, then quietly discarded it. Nothing
                // observable at the IP layer; only the absence of end-to-end
                // delivery reveals it.
                ++g_stats.dataDroppedByMalicious;
                continue;
            }

            // Stamp which gateway relayed this packet, so the sink can report
            // delivery per gateway.
            DataTagHeader tag;
            packet->RemoveHeader(tag);
            tag.SetViaGw(m_myAddr);
            packet->AddHeader(tag);

            m_outSocket->Send(packet);
            ++g_stats.dataRelayed;
        }
    }

    Ipv4Address m_myAddr;
    Ipv4Address m_broadcast;
    Ipv4Address m_internet;
    Time m_advInterval{Seconds(5)};
    uint8_t m_advTtl{30};
    bool m_malicious{false};
    double m_dropFraction{0.0};
    uint32_t m_seqNo{0};
    Ptr<Socket> m_ctrlSocket;
    Ptr<Socket> m_relaySocket;
    Ptr<Socket> m_outSocket;
    Ptr<UniformRandomVariable> m_rand;
    EventId m_advEvent;
    std::set<std::pair<uint32_t, uint32_t>> m_seenSol;
};

// ---------------------------------------------------------------------------
// NodeAgent -- runs on each MANET node
// ---------------------------------------------------------------------------

/**
 * Maintains the node's view of available gateways and sends its CBR traffic to
 * whichever one it currently prefers.
 *
 * Advertisements are rebroadcast while their TTL allows, with duplicate
 * suppression keyed on (origin, sequence number), which is the standard way to
 * keep a flood from looping. Every rebroadcast increments the hop count, so the
 * count a node stores is its true distance to that gateway.
 *
 * Solicitation is driven by need rather than by a timer: if the node is about
 * to send and has no fresh gateway entry, it solicits. In hybrid mode that
 * happens precisely for the nodes sitting outside every gateway's advertisement
 * zone, which is the behaviour that distinguishes hybrid from proactive.
 */
class NodeAgent : public Application
{
  public:
    static TypeId GetTypeId()
    {
        static TypeId tid =
            TypeId("NodeAgent").SetParent<Application>().AddConstructor<NodeAgent>();
        return tid;
    }


    void Setup(Ipv4Address myAddr,
               Ipv4Address broadcastAddr,
               uint32_t srcId,
               bool isSource,
               Time cbrInterval,
               uint32_t packetSize,
               Time entryLifetime,
               uint8_t solTtl)
    {
        m_myAddr = myAddr;
        m_broadcast = broadcastAddr;
        m_srcId = srcId;
        m_isSource = isSource;
        m_cbrInterval = cbrInterval;
        m_packetSize = packetSize;
        m_entryLifetime = entryLifetime;
        m_solTtl = solTtl;
    }

  private:
    struct GwEntry
    {
        uint8_t hopCount;
        Time lastHeard;
        uint32_t lastSeq;
    };

    void StartApplication() override
    {
        m_ctrlSocket = Socket::CreateSocket(GetNode(), UdpSocketFactory::GetTypeId());
        m_ctrlSocket->SetAllowBroadcast(true);
        m_ctrlSocket->Bind(InetSocketAddress(Ipv4Address::GetAny(), GW_CTRL_PORT));
        m_ctrlSocket->SetRecvCallback(MakeCallback(&NodeAgent::HandleCtrl, this));

        m_dataSocket = Socket::CreateSocket(GetNode(), UdpSocketFactory::GetTypeId());

        m_rand = CreateObject<UniformRandomVariable>();

        if (m_isSource)
        {
            Time jitter = MilliSeconds(m_rand->GetInteger(0, 500));
            m_sendEvent = Simulator::Schedule(jitter, &NodeAgent::SendData, this);
        }
    }

    void StopApplication() override
    {
        Simulator::Cancel(m_sendEvent);
        if (m_ctrlSocket)
        {
            m_ctrlSocket->Close();
        }
        if (m_dataSocket)
        {
            m_dataSocket->Close();
        }
    }

    void HandleCtrl(Ptr<Socket> socket)
    {
        Ptr<Packet> packet;
        Address from;
        while ((packet = socket->RecvFrom(from)))
        {
            GwMsgHeader hdr;
            packet->RemoveHeader(hdr);

            if (hdr.GetType() == GW_ADV)
            {
                HandleAdvertisement(hdr);
            }
            else
            {
                HandleSolicitation(hdr);
            }
        }
    }

    void HandleAdvertisement(GwMsgHeader hdr)
    {
        uint8_t hops = hdr.GetHopCount() + 1; // one more hop to reach us

        Ipv4Address gw = hdr.GetGateway();
        auto it = m_gateways.find(gw.Get());
        if (it == m_gateways.end() || hdr.GetSeqNo() > it->second.lastSeq ||
            hops < it->second.hopCount)
        {
            m_gateways[gw.Get()] = GwEntry{hops, Simulator::Now(), hdr.GetSeqNo()};
        }

        // Rebroadcast if this is a flooded advertisement with budget left and
        // we have not already forwarded this particular one.
        if (hdr.GetTtl() > 1 && !AlreadySeen(hdr.GetOrigin(), hdr.GetSeqNo()))
        {
            GwMsgHeader fwd = hdr;
            fwd.SetHopCount(hops);
            fwd.SetTtl(hdr.GetTtl() - 1);

            Ptr<Packet> p = Create<Packet>();
            p->AddHeader(fwd);
            // A small random delay before rebroadcasting spreads the flood out
            // in time; without it every receiver fires simultaneously and the
            // resulting collisions swallow much of the advertisement.
            Simulator::Schedule(MicroSeconds(m_rand->GetInteger(1000, 20000)),
                                &NodeAgent::Rebroadcast,
                                this,
                                p);
            ++g_stats.advForwarded;
        }
    }

    void HandleSolicitation(GwMsgHeader hdr)
    {
        if (hdr.GetTtl() <= 1 || AlreadySeen(hdr.GetOrigin(), hdr.GetSeqNo()))
        {
            return;
        }

        GwMsgHeader fwd = hdr;
        fwd.SetHopCount(hdr.GetHopCount() + 1);
        fwd.SetTtl(hdr.GetTtl() - 1);

        Ptr<Packet> p = Create<Packet>();
        p->AddHeader(fwd);
        Simulator::Schedule(MicroSeconds(m_rand->GetInteger(1000, 20000)),
                            &NodeAgent::Rebroadcast,
                            this,
                            p);
        ++g_stats.solForwarded;
    }

    void Rebroadcast(Ptr<Packet> p)
    {
        m_ctrlSocket->SendTo(p, 0, InetSocketAddress(m_broadcast, GW_CTRL_PORT));
    }

    bool AlreadySeen(Ipv4Address origin, uint32_t seq)
    {
        auto key = std::make_pair(origin.Get(), seq);
        if (m_seen.count(key))
        {
            return true;
        }
        m_seen.insert(key);
        return false;
    }

    void SendSolicitation()
    {
        GwMsgHeader hdr;
        hdr.SetType(GW_SOL);
        hdr.SetGateway(Ipv4Address::GetAny());
        hdr.SetOrigin(m_myAddr);
        hdr.SetSeqNo(++m_solSeq);
        hdr.SetHopCount(0);
        hdr.SetTtl(m_solTtl);

        Ptr<Packet> p = Create<Packet>();
        p->AddHeader(hdr);
        m_ctrlSocket->SendTo(p, 0, InetSocketAddress(m_broadcast, GW_CTRL_PORT));
        ++g_stats.solSent;
    }

    /**
     * Baseline selection policy: fewest hops, ties broken by freshness.
     * The trust-aware policy will replace this comparator while leaving the
     * rest of the machinery untouched, so the two are directly comparable.
     */
    bool SelectGateway(Ipv4Address& chosen)
    {
        bool found = false;
        uint8_t bestHops = 255;
        Time bestHeard = Seconds(0);

        for (auto it = m_gateways.begin(); it != m_gateways.end();)
        {
            if (Simulator::Now() - it->second.lastHeard > m_entryLifetime)
            {
                it = m_gateways.erase(it); // stale entry, forget it
                continue;
            }
            if (!found || it->second.hopCount < bestHops ||
                (it->second.hopCount == bestHops && it->second.lastHeard > bestHeard))
            {
                bestHops = it->second.hopCount;
                bestHeard = it->second.lastHeard;
                chosen = Ipv4Address(it->first);
                found = true;
            }
            ++it;
        }
        return found;
    }

    void SendData()
    {
        Ipv4Address gw;
        if (!SelectGateway(gw))
        {
            // No usable gateway. Proactive mode just waits for the next
            // advertisement; the other two modes solicit one.
            ++g_stats.noGatewayAtSendTime;
            if (g_mode != MODE_PROACTIVE)
            {
                SendSolicitation();
            }
        }
        else
        {
            DataTagHeader tag;
            tag.SetSrcId(m_srcId);
            tag.SetSeqNo(m_dataSeq++);
            tag.SetSendTime(Simulator::Now());
            tag.SetViaGw(gw);

            Ptr<Packet> p = Create<Packet>(m_packetSize);
            p->AddHeader(tag);

            m_dataSocket->SendTo(p, 0, InetSocketAddress(gw, GW_RELAY_PORT));
            ++g_stats.dataSent;
        }

        m_sendEvent = Simulator::Schedule(m_cbrInterval, &NodeAgent::SendData, this);
    }

    Ipv4Address m_myAddr;
    Ipv4Address m_broadcast;
    uint32_t m_srcId{0};
    bool m_isSource{false};
    Time m_cbrInterval{MilliSeconds(200)};
    uint32_t m_packetSize{512};
    Time m_entryLifetime{Seconds(15)};
    uint8_t m_solTtl{30};
    uint32_t m_dataSeq{0};
    uint32_t m_solSeq{0};
    std::map<uint32_t, GwEntry> m_gateways;
    std::set<std::pair<uint32_t, uint32_t>> m_seen;
    Ptr<Socket> m_ctrlSocket;
    Ptr<Socket> m_dataSocket;
    Ptr<UniformRandomVariable> m_rand;
    EventId m_sendEvent;
};

// ---------------------------------------------------------------------------
// InternetSink -- runs on the wired Internet host
// ---------------------------------------------------------------------------

class InternetSink : public Application
{
  public:
    static TypeId GetTypeId()
    {
        static TypeId tid =
            TypeId("InternetSink").SetParent<Application>().AddConstructor<InternetSink>();
        return tid;
    }


  private:
    void StartApplication() override
    {
        m_socket = Socket::CreateSocket(GetNode(), UdpSocketFactory::GetTypeId());
        m_socket->Bind(InetSocketAddress(Ipv4Address::GetAny(), SINK_PORT));
        m_socket->SetRecvCallback(MakeCallback(&InternetSink::HandleRead, this));
    }

    void StopApplication() override
    {
        if (m_socket)
        {
            m_socket->Close();
        }
    }

    void HandleRead(Ptr<Socket> socket)
    {
        Ptr<Packet> packet;
        Address from;
        while ((packet = socket->RecvFrom(from)))
        {
            DataTagHeader tag;
            packet->RemoveHeader(tag);
            ++g_stats.dataReceived;
            g_stats.delaySum += Simulator::Now() - tag.GetSendTime();
            ++g_stats.deliveredViaGw[tag.GetViaGw().Get()];
        }
    }

    Ptr<Socket> m_socket;
};

// ---------------------------------------------------------------------------
// Scenario
// ---------------------------------------------------------------------------

int
main(int argc, char* argv[])
{
    uint32_t numManetNodes = 15;
    uint32_t numGateways = 2;
    uint32_t numSources = 5;
    double simTime = 200.0;
    double areaSize = 750.0;   // field width (m)
    // Field height. Left at zero the field is square, which is the common case.
    // A separate height is needed because the established scenario for fifteen
    // nodes in this line of work -- and in Hamidian's original study -- is
    // 800 x 500 m, not a square. Forcing it square would make the field 60%
    // larger and the network correspondingly sparser, which is not the same
    // experiment.
    double areaHeight = 0.0;
    double range = 250.0;
    double nodeSpeedMin = 1.0;
    double nodeSpeedMax = 6.0;
    double pauseTime = 2.0;
    double advIntervalSec = 5.0;
    uint32_t advZone = 3;     // hybrid advertisement zone radius, Hamidian's value
    uint32_t netDiameter = 30; // full-flood TTL, Hamidian's NETWORK_DIAMETER
    uint32_t packetSize = 512;
    double cbrRatePps = 5.0;
    double entryLifetimeSec = 15.0;
    std::string mode = "proactive";
    bool maliciousGw = false;
    double dropFraction = 1.0; // a malicious gateway drops everything by default
    bool enableAnim = false;   // NetAnim tracing is slow and verbose; opt in with --anim=1

    CommandLine cmd(__FILE__);
    cmd.AddValue("mode", "Discovery mechanism: proactive | reactive | hybrid", mode);
    cmd.AddValue("numManetNodes", "Number of MANET nodes", numManetNodes);
    cmd.AddValue("numGateways", "Number of gateways", numGateways);
    cmd.AddValue("numSources", "How many MANET nodes generate CBR traffic", numSources);
    cmd.AddValue("simTime", "Simulation time (s)", simTime);
    cmd.AddValue("areaSize", "Width of the simulation area (m)", areaSize);
    cmd.AddValue("areaHeight", "Height of the simulation area (m; 0 = square)", areaHeight);
    cmd.AddValue("range", "WiFi transmission range (m)", range);
    cmd.AddValue("advInterval", "Advertisement interval (s)", advIntervalSec);
    cmd.AddValue("advZone", "Advertisement zone radius in hops (hybrid mode)", advZone);
    cmd.AddValue("maliciousGw", "Make gateway 1 accept traffic then discard it", maliciousGw);
    cmd.AddValue("dropFraction", "Fraction of relayed traffic a malicious gateway drops",
                 dropFraction);
    cmd.AddValue("anim", "Write a NetAnim trace file (slow; use short simTime)", enableAnim);
    // Exposed so that the interaction between advertisement interval and entry
    // lifetime can be measured rather than assumed: a node can only transmit
    // while it holds an unexpired gateway entry, so when advInterval exceeds
    // entryLifetime the achievable send rate falls to entryLifetime/advInterval.
    cmd.AddValue("entryLifetime", "How long a gateway table entry stays valid (s)",
                 entryLifetimeSec);
    // Node speed and pause time are the conventional independent variables in
    // this line of work and must therefore be settable from the command line.
    cmd.AddValue("nodeSpeedMin", "Minimum mobile node speed (m/s)", nodeSpeedMin);
    cmd.AddValue("nodeSpeedMax", "Maximum mobile node speed (m/s)", nodeSpeedMax);
    cmd.AddValue("pauseTime", "Random waypoint pause time (s)", pauseTime);
    cmd.AddValue("packetSize", "CBR payload size (bytes)", packetSize);
    cmd.AddValue("cbrRate", "CBR packets per second per source", cbrRatePps);
    cmd.Parse(argc, argv);

    // A height of zero means "square", so that every existing invocation that
    // passes only --areaSize keeps behaving exactly as it did before.
    if (areaHeight <= 0.0)
    {
        areaHeight = areaSize;
    }

    if (mode == "reactive")
    {
        g_mode = MODE_REACTIVE;
    }
    else if (mode == "hybrid")
    {
        g_mode = MODE_HYBRID;
    }
    else
    {
        g_mode = MODE_PROACTIVE;
        mode = "proactive";
    }

    NS_LOG_UNCOND("Gateway Discovery: mode=" << mode << ", area " << areaSize << "x" << areaHeight
                                             << " m, range " << range << " m, " << numManetNodes
                                             << " nodes, " << numGateways << " gateways, "
                                             << numSources << " sources, advInterval "
                                             << advIntervalSec << " s, entryLifetime "
                                             << entryLifetimeSec << " s, speed " << nodeSpeedMin
                                             << "-" << nodeSpeedMax << " m/s, pause " << pauseTime
                                             << " s, simTime " << simTime << " s, RngRun "
                                             << RngSeedManager::GetRun()
                                             << (maliciousGw ? ", MALICIOUS gw1" : ""));

    NodeContainer manetNodes;
    manetNodes.Create(numManetNodes);
    NodeContainer gatewayNodes;
    gatewayNodes.Create(numGateways);
    NodeContainer internetNode;
    internetNode.Create(1);

    NodeContainer wifiNodes;
    wifiNodes.Add(manetNodes);
    wifiNodes.Add(gatewayNodes);

    // ---- WiFi ----
    WifiHelper wifi;
    wifi.SetStandard(WIFI_STANDARD_80211b);
    wifi.SetRemoteStationManager("ns3::ConstantRateWifiManager",
                                 "DataMode",
                                 StringValue("DsssRate11Mbps"),
                                 "ControlMode",
                                 StringValue("DsssRate1Mbps"));

    // Hard-edged range model. The default log-distance channel yields only
    // ~58 m at 11 Mbps, which silently disconnects the network; see the
    // baseline scenario's notes.
    YansWifiChannelHelper wifiChannel;
    wifiChannel.SetPropagationDelay("ns3::ConstantSpeedPropagationDelayModel");
    wifiChannel.AddPropagationLoss("ns3::RangePropagationLossModel",
                                   "MaxRange",
                                   DoubleValue(range));
    YansWifiPhyHelper wifiPhy;
    wifiPhy.SetChannel(wifiChannel.Create());

    WifiMacHelper wifiMac;
    wifiMac.SetType("ns3::AdhocWifiMac");
    NetDeviceContainer wifiDevices = wifi.Install(wifiPhy, wifiMac, wifiNodes);

    // ---- Mobility ----
    Ptr<UniformRandomVariable> posX = CreateObject<UniformRandomVariable>();
    posX->SetAttribute("Min", DoubleValue(0.0));
    posX->SetAttribute("Max", DoubleValue(areaSize));
    Ptr<UniformRandomVariable> posY = CreateObject<UniformRandomVariable>();
    posY->SetAttribute("Min", DoubleValue(0.0));
    posY->SetAttribute("Max", DoubleValue(areaHeight));
    Ptr<RandomRectanglePositionAllocator> initialAlloc =
        CreateObject<RandomRectanglePositionAllocator>();
    initialAlloc->SetAttribute("X", PointerValue(posX));
    initialAlloc->SetAttribute("Y", PointerValue(posY));

    Ptr<UniformRandomVariable> wpX = CreateObject<UniformRandomVariable>();
    wpX->SetAttribute("Min", DoubleValue(0.0));
    wpX->SetAttribute("Max", DoubleValue(areaSize));
    Ptr<UniformRandomVariable> wpY = CreateObject<UniformRandomVariable>();
    wpY->SetAttribute("Min", DoubleValue(0.0));
    wpY->SetAttribute("Max", DoubleValue(areaHeight));
    Ptr<RandomRectanglePositionAllocator> wpAlloc =
        CreateObject<RandomRectanglePositionAllocator>();
    wpAlloc->SetAttribute("X", PointerValue(wpX));
    wpAlloc->SetAttribute("Y", PointerValue(wpY));

    MobilityHelper mobility;
    mobility.SetPositionAllocator(initialAlloc);
    mobility.SetMobilityModel("ns3::RandomWaypointMobilityModel",
                              "Speed",
                              StringValue("ns3::UniformRandomVariable[Min=" +
                                          std::to_string(nodeSpeedMin) + "|Max=" +
                                          std::to_string(nodeSpeedMax) + "]"),
                              "Pause",
                              StringValue("ns3::ConstantRandomVariable[Constant=" +
                                          std::to_string(pauseTime) + "]"),
                              "PositionAllocator",
                              PointerValue(wpAlloc));
    mobility.Install(manetNodes);

    // Gateways at opposite edges, so hop distance to them genuinely differs
    // across the node population and gateway choice has something to decide.
    MobilityHelper gwMobility;
    Ptr<ListPositionAllocator> gwPos = CreateObject<ListPositionAllocator>();
    for (uint32_t i = 0; i < numGateways; ++i)
    {
        double x = (numGateways == 1) ? areaSize / 2.0
                                      : (areaSize * i) / (numGateways - 1);
        gwPos->Add(Vector(x, areaHeight / 2.0, 0.0));
    }
    gwMobility.SetPositionAllocator(gwPos);
    gwMobility.SetMobilityModel("ns3::ConstantPositionMobilityModel");
    gwMobility.Install(gatewayNodes);

    MobilityHelper netMobility;
    Ptr<ListPositionAllocator> netPos = CreateObject<ListPositionAllocator>();
    netPos->Add(Vector(areaSize / 2.0, areaHeight + 100.0, 0.0));
    netMobility.SetPositionAllocator(netPos);
    netMobility.SetMobilityModel("ns3::ConstantPositionMobilityModel");
    netMobility.Install(internetNode);

    // ---- Internet stacks ----
    // AODV on the MANET side only. The wired Internet host deliberately does
    // NOT run AODV -- it is an ordinary host reachable only because a gateway
    // relays to it, which is the situation gateway discovery exists to solve.
    AodvHelper aodv;
    Ipv4StaticRoutingHelper staticRouting;

    // MANET nodes: AODV is consulted first and owns routing outright. Static
    // sits underneath as an unused fallback slot.
    Ipv4ListRoutingHelper manetRouting;
    manetRouting.Add(staticRouting, 0);
    manetRouting.Add(aodv, 10);

    InternetStackHelper manetStack;
    manetStack.SetRoutingHelper(manetRouting);
    manetStack.Install(manetNodes);

    // Gateways need the OPPOSITE precedence, because they straddle two worlds.
    // ns-3's AODV claims every destination handed to RouteOutput: if it has no
    // route it returns a loopback route and starts a route request rather than
    // declining, so Ipv4ListRouting never falls through to anything below it.
    // With AODV on top, a gateway could not reach the wired host sitting on its
    // own point-to-point link -- it would issue a route request that the
    // non-AODV Internet host can never answer, and the packet would be dropped.
    // That is exactly what happened: 4062 packets relayed, 0 delivered.
    //
    // Static routing is therefore consulted FIRST on gateways. Unlike AODV it
    // declines cleanly when it has no matching route, so MANET destinations
    // still fall through to AODV -- provided static holds no route that could
    // shadow them, which is what the route removal below ensures.
    Ipv4ListRoutingHelper gatewayRouting;
    gatewayRouting.Add(aodv, 0);
    gatewayRouting.Add(staticRouting, 10);

    InternetStackHelper gatewayStack;
    gatewayStack.SetRoutingHelper(gatewayRouting);
    gatewayStack.Install(gatewayNodes);

    InternetStackHelper wiredStack; // plain static routing
    wiredStack.Install(internetNode);

    Ipv4AddressHelper ipv4;
    ipv4.SetBase("10.1.1.0", "255.255.255.0");
    Ipv4InterfaceContainer wifiInterfaces = ipv4.Assign(wifiDevices);

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
        Ipv4AddressHelper ip2;
        ip2.SetBase(subnet.str().c_str(), "255.255.255.0");
        p2pInterfaces.push_back(ip2.Assign(devs));
    }

    // The Internet host is one hop from each gateway over a dedicated link, so
    // its own interface routes suffice; nothing else needs a route because all
    // MANET-bound traffic terminates here.
    Ipv4Address wifiBroadcast("10.1.1.255");

    // Hand the WiFi subnet back to AODV on every gateway.
    //
    // Assigning an address installs a connected route for its subnet into the
    // node's static routing table. On a gateway, where static is consulted
    // before AODV, that connected 10.1.1.0/24 route would match every MANET
    // destination and claim it as directly reachable -- true only for one-hop
    // neighbours, so anything further away would fail ARP and never route. That
    // would break the unicast advertisement replies reactive and hybrid mode
    // depend on. Removing it leaves static holding only the point-to-point
    // routes it needs for the wired side, so MANET traffic falls through to
    // AODV exactly as it should.
    for (uint32_t i = 0; i < numGateways; ++i)
    {
        Ptr<Ipv4> gwIpv4 = gatewayNodes.Get(i)->GetObject<Ipv4>();
        Ptr<Ipv4StaticRouting> gwStatic = staticRouting.GetStaticRouting(gwIpv4);
        for (uint32_t r = 0; r < gwStatic->GetNRoutes();)
        {
            Ipv4RoutingTableEntry entry = gwStatic->GetRoute(r);
            if (entry.GetDestNetwork() == Ipv4Address("10.1.1.0"))
            {
                gwStatic->RemoveRoute(r);
            }
            else
            {
                ++r;
            }
        }
    }

    // ---- Applications ----
    Time advInterval = Seconds(advIntervalSec);
    uint8_t advTtl = (g_mode == MODE_HYBRID) ? static_cast<uint8_t>(advZone)
                                             : static_cast<uint8_t>(netDiameter);

    for (uint32_t i = 0; i < numGateways; ++i)
    {
        Ptr<GatewayAgent> agent = CreateObject<GatewayAgent>();
        bool isMalicious = maliciousGw && (i == 1);
        // Each gateway must relay to the Internet host's address on ITS OWN
        // point-to-point link. Gateway 1 sits on 10.2.2.0/24 and has no route
        // to 10.2.1.2 -- that address lives on gateway 0's link, and since the
        // Internet host deliberately does not run AODV, nothing would resolve
        // it. The sink binds to 0.0.0.0 so it accepts traffic on either link.
        agent->Setup(wifiInterfaces.GetAddress(numManetNodes + i),
                     wifiBroadcast,
                     p2pInterfaces[i].GetAddress(1),
                     advInterval,
                     advTtl,
                     isMalicious,
                     dropFraction);
        gatewayNodes.Get(i)->AddApplication(agent);
        agent->SetStartTime(Seconds(1.0));
        agent->SetStopTime(Seconds(simTime));
    }

    Time cbrInterval = Seconds(1.0 / cbrRatePps);
    uint32_t actualSources = std::min(numSources, numManetNodes);
    for (uint32_t i = 0; i < numManetNodes; ++i)
    {
        Ptr<NodeAgent> agent = CreateObject<NodeAgent>();
        agent->Setup(wifiInterfaces.GetAddress(i),
                     wifiBroadcast,
                     i,
                     i < actualSources,
                     cbrInterval,
                     packetSize,
                     Seconds(entryLifetimeSec),
                     static_cast<uint8_t>(netDiameter));
        manetNodes.Get(i)->AddApplication(agent);
        // Nodes listen from the start but only begin sending once discovery has
        // had a chance to populate their gateway tables.
        agent->SetStartTime(Seconds(1.0));
        agent->SetStopTime(Seconds(simTime - 5.0));
    }

    Ptr<InternetSink> sink = CreateObject<InternetSink>();
    internetNode.Get(0)->AddApplication(sink);
    sink->SetStartTime(Seconds(0.0));
    sink->SetStopTime(Seconds(simTime));

    // ---- NetAnim visualisation ----
    //
    // Off by default. AnimationInterface logs every packet transmission, which
    // both slows the run down substantially and produces very large XML files,
    // so it is opt-in and intended for short runs made purely to produce a
    // figure or an animation -- not for the measurement runs that feed the
    // results tables.
    //
    // Nodes are labelled and coloured to match the conventions used in the
    // paper's architecture figure: MANET nodes MN1..MNn, Internet gateways
    // IGW1..IGWm, and the wired correspondent node. CBR sources are given a
    // distinct colour so that the traffic-generating nodes can be picked out,
    // and a gateway running in malicious mode is drawn in red.
    //
    //   ./ns3 run "scratch/gateway-discovery --mode=hybrid --simTime=30 --anim=1"
    //
    std::unique_ptr<AnimationInterface> anim;
    if (enableAnim)
    {
        std::ostringstream animFile;
        animFile << "gateway-discovery-" << mode << ".xml";
        anim = std::make_unique<AnimationInterface>(animFile.str());
        anim->SetMaxPktsPerTraceFile(500000);

        // MANET nodes: sources in green, non-sources in blue.
        for (uint32_t i = 0; i < numManetNodes; ++i)
        {
            uint32_t id = manetNodes.Get(i)->GetId();
            std::ostringstream name;
            name << "MN" << (i + 1);
            anim->UpdateNodeDescription(id, name.str());
            anim->UpdateNodeSize(id, std::min(areaSize, areaHeight) / 40.0,
                                 std::min(areaSize, areaHeight) / 40.0);
            if (i < actualSources)
            {
                anim->UpdateNodeColor(id, 0, 170, 0); // active source
            }
            else
            {
                anim->UpdateNodeColor(id, 90, 140, 235); // ordinary mobile node
            }
        }

        // Gateways: orange, drawn larger. A malicious gateway is shown in red.
        for (uint32_t i = 0; i < numGateways; ++i)
        {
            uint32_t id = gatewayNodes.Get(i)->GetId();
            std::ostringstream name;
            name << "IGW" << (i + 1);
            anim->UpdateNodeDescription(id, name.str());
            anim->UpdateNodeSize(id, std::min(areaSize, areaHeight) / 25.0,
                                 std::min(areaSize, areaHeight) / 25.0);
            if (maliciousGw && i == 1)
            {
                anim->UpdateNodeColor(id, 220, 0, 0); // malicious gateway
            }
            else
            {
                anim->UpdateNodeColor(id, 255, 140, 0);
            }
        }

        // The wired correspondent node on the far side of the gateways.
        uint32_t netId = internetNode.Get(0)->GetId();
        anim->UpdateNodeDescription(netId, "Internet");
        anim->UpdateNodeSize(netId, std::min(areaSize, areaHeight) / 25.0,
                                    std::min(areaSize, areaHeight) / 25.0);
        anim->UpdateNodeColor(netId, 130, 60, 200);

        NS_LOG_UNCOND("NetAnim trace will be written to " << animFile.str());
    }

    Simulator::Stop(Seconds(simTime));
    Simulator::Run();

    // ---- Results ----
    //
    // Two delivery ratios are reported, and the distinction matters.
    //
    // A node that has no unexpired gateway entry when its CBR timer fires
    // cannot transmit at all: in proactive mode it has no way to ask for a
    // gateway, so the packet is simply never sent. Those attempts are counted
    // in noGatewayAtSendTime.
    //
    // Dividing received by *sent* therefore silently removes every such
    // failure from the denominator, and reports near-perfect delivery for a
    // configuration that is in fact delivering a fraction of the offered load.
    // The Packet Delivery Ratio below is consequently computed against the
    // offered load -- every packet the application intended to transmit --
    // which is the quantity the metric is conventionally understood to mean.
    //
    // The transmitted-only figure is retained as a secondary diagnostic,
    // because the gap between the two is itself informative: it isolates
    // discovery failure from network loss.
    uint64_t attempted = g_stats.dataSent + g_stats.noGatewayAtSendTime;

    double pdr = (attempted > 0) ? (100.0 * g_stats.dataReceived / attempted) : 0.0;
    double txPdr =
        (g_stats.dataSent > 0) ? (100.0 * g_stats.dataReceived / g_stats.dataSent) : 0.0;
    double sendRate = (attempted > 0) ? (100.0 * g_stats.dataSent / attempted) : 0.0;
    double avgDelay = (g_stats.dataReceived > 0)
                          ? (g_stats.delaySum.GetSeconds() / g_stats.dataReceived)
                          : 0.0;

    NS_LOG_UNCOND("\n---- Gateway Discovery Results (" << mode << ") ----");
    NS_LOG_UNCOND("Data packets offered:   " << attempted);
    NS_LOG_UNCOND("Data packets sent:      " << g_stats.dataSent);
    NS_LOG_UNCOND("Data packets relayed:   " << g_stats.dataRelayed);
    NS_LOG_UNCOND("Data packets received:  " << g_stats.dataReceived);
    NS_LOG_UNCOND("Packet Delivery Ratio:  " << pdr << " %");
    NS_LOG_UNCOND("Transmitted-only PDR:   " << txPdr << " %");
    NS_LOG_UNCOND("Gateway availability:   " << sendRate << " %");
    NS_LOG_UNCOND("Average End-to-End Delay: " << avgDelay << " s");
    NS_LOG_UNCOND("Sends with no gateway known: " << g_stats.noGatewayAtSendTime);
    if (maliciousGw)
    {
        NS_LOG_UNCOND("Dropped by malicious gateway: " << g_stats.dataDroppedByMalicious);
    }

    NS_LOG_UNCOND("\n---- Control overhead ----");
    NS_LOG_UNCOND("Advertisements originated: " << g_stats.advSent);
    NS_LOG_UNCOND("Advertisements forwarded:  " << g_stats.advForwarded);
    NS_LOG_UNCOND("Solicitations originated:  " << g_stats.solSent);
    NS_LOG_UNCOND("Solicitations forwarded:   " << g_stats.solForwarded);
    NS_LOG_UNCOND("Unicast advertisement replies: " << g_stats.advReplies);
    NS_LOG_UNCOND("TOTAL control messages:    " << g_stats.ControlOverhead());

    NS_LOG_UNCOND("\n---- Delivery per gateway ----");
    for (uint32_t i = 0; i < numGateways; ++i)
    {
        Ipv4Address gw = wifiInterfaces.GetAddress(numManetNodes + i);
        uint64_t n = g_stats.deliveredViaGw.count(gw.Get()) ? g_stats.deliveredViaGw[gw.Get()] : 0;
        NS_LOG_UNCOND("  gateway " << i << " (" << gw << ")"
                                   << (maliciousGw && i == 1 ? " [MALICIOUS]" : "")
                                   << ": " << n << " packets delivered");
    }

    // ---- Machine-readable summary ----
    //
    // A single tagged line carrying every parameter and every result, so that
    // sweep scripts can extract one line per run instead of grepping a dozen
    // separate labels. Every run is therefore self-describing: the CSV records
    // the conditions that produced it, which removes any possibility of a
    // results file being interpreted against the wrong parameter set.
    {
        uint64_t gwDelivered0 = 0;
        uint64_t gwDelivered1 = 0;
        if (numGateways > 0)
        {
            Ipv4Address a = wifiInterfaces.GetAddress(numManetNodes + 0);
            gwDelivered0 = g_stats.deliveredViaGw.count(a.Get()) ? g_stats.deliveredViaGw[a.Get()] : 0;
        }
        if (numGateways > 1)
        {
            Ipv4Address b = wifiInterfaces.GetAddress(numManetNodes + 1);
            gwDelivered1 = g_stats.deliveredViaGw.count(b.Get()) ? g_stats.deliveredViaGw[b.Get()] : 0;
        }

        std::ostringstream row;
        row << "RESULT,"
            << mode << ','
            << numManetNodes << ','
            << numGateways << ','
            << numSources << ','
            << areaSize << ','
            << range << ','
            << nodeSpeedMin << ','
            << nodeSpeedMax << ','
            << pauseTime << ','
            << simTime << ','
            << advIntervalSec << ','
            << advZone << ','
            << entryLifetimeSec << ','
            << packetSize << ','
            << cbrRatePps << ','
            << RngSeedManager::GetRun() << ','
            << attempted << ','
            << g_stats.dataSent << ','
            << g_stats.dataRelayed << ','
            << g_stats.dataReceived << ','
            << pdr << ','
            << txPdr << ','
            << sendRate << ','
            << (avgDelay * 1000.0) << ','
            << g_stats.noGatewayAtSendTime << ','
            << g_stats.advSent << ','
            << g_stats.advForwarded << ','
            << g_stats.solSent << ','
            << g_stats.solForwarded << ','
            << g_stats.advReplies << ','
            << g_stats.ControlOverhead() << ','
            << gwDelivered0 << ','
            << gwDelivered1 << ','
            << (maliciousGw ? 1 : 0) << ','
            << g_stats.dataDroppedByMalicious << ','
            << areaHeight;
        NS_LOG_UNCOND("");
        NS_LOG_UNCOND(row.str());
    }

    Simulator::Destroy();
    return 0;
}
