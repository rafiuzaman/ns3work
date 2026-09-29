#!/usr/bin/env python3
# linkbreaks.py -- geometric ("true") link breaks from node positions
#
# Usage:
#   python3 linkbreaks.py pos/*.pos.gz > results/linkbreaks.csv
#
# For every run it reads pos/<tag>.pos.gz (the waypoints mobility.tcl
# scheduled) and, if present, pos/<tag>.tr.cbk (the MAC link failures that
# metrics.awk counted as link_fail). It reports:
#
#   geo_breaks      number of times ANY node pair moved out of range
#                   (distance crossing R upwards) between T0 and T1
#   geo_rate        geo_breaks / (T1 - T0), per second
#   mean_degree     average number of neighbours within R (sampled every 10 s)
#   cbk_n           MAC-reported link failures (same de-duplication as
#                   metrics.awk: one per link per second)
#   cbk_true        of those, next hop really beyond R at that instant
#   cbk_false       next hop still within R -> failure caused by collisions /
#                   retries (congestion), not by movement
#   false_share     cbk_false / cbk_n
#
# cbk_* are empty for runs made before metrics.awk wrote the .cbk files.
# Movement model: ns-2 setdest moves in a straight line at constant speed and
# the node then waits at the destination until its next waypoint, which is
# exactly how mobility.tcl schedules moves. Pure Python 3, no extra packages.

import bisect
import gzip
import math
import os
import re
import sys

R = 250.0            # transmission range (default Phy/WirelessPhy + TwoRayGround)
T0, T1 = 20.0, 1000.0
TAG = re.compile(r"(\w+?)_(\w+?)_(\d+)n_s(\d+)_(\d+)kb_v([\d.]+)-([\d.]+)_p(\d+(?:\.\d+)?)")


class Track(object):
    """Piecewise-linear trajectory of one node."""

    def __init__(self, x, y):
        self.t = [0.0]           # piece start times
        self.p = [(x, y, 0.0, 0.0)]   # (x0, y0, vx, vy) at piece start

    def at(self, t):
        i = bisect.bisect_right(self.t, t) - 1
        x0, y0, vx, vy = self.p[i]
        dt = t - self.t[i]
        return x0 + vx * dt, y0 + vy * dt

    def add_move(self, t, nx, ny, spd):
        x, y = self.at(t)
        d = math.hypot(nx - x, ny - y)
        if d < 1e-9 or spd <= 0:
            return
        dur = d / spd
        vx, vy = (nx - x) / dur, (ny - y) / dur
        # drop pieces that start after t (cannot happen with mobility.tcl)
        while self.t and self.t[-1] > t:
            self.t.pop(); self.p.pop()
        self.t.append(t); self.p.append((x, y, vx, vy))
        self.t.append(t + dur); self.p.append((nx, ny, 0.0, 0.0))


def read_pos(path):
    tracks = {}
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt") as f:
        for line in f:
            if not line.strip() or line[0] == "#":
                continue
            t, n, x, y, s = line.split()[:5]
            t, n, x, y, s = float(t), int(n), float(x), float(y), float(s)
            if n not in tracks:
                tracks[n] = Track(x, y)
            elif s > 0:
                tracks[n].add_move(t, x, y, s)
    return tracks


def pair_breaks(a, b):
    """Times in (T0, T1] at which the distance between a and b rises above R."""
    times = sorted(set([T0, T1] + [t for t in a.t + b.t if T0 < t < T1]))
    out = []
    R2 = R * R
    for k in range(len(times) - 1):
        s, e = times[k], times[k + 1]
        ax, ay = a.at(s); bx, by = b.at(s)
        ia = bisect.bisect_right(a.t, s) - 1
        ib = bisect.bisect_right(b.t, s) - 1
        rvx = b.p[ib][2] - a.p[ia][2]
        rvy = b.p[ib][3] - a.p[ia][3]
        rx, ry = bx - ax, by - ay
        d0 = math.hypot(rx, ry)
        reach = math.hypot(rvx, rvy) * (e - s)
        if d0 - reach > R or d0 + reach <= R:
            continue                      # cannot cross R in this piece
        # |r + v*tau|^2 = R^2  ->  A tau^2 + B tau + C = 0
        A = rvx * rvx + rvy * rvy
        B = 2 * (rx * rvx + ry * rvy)
        C = rx * rx + ry * ry - R2
        if A < 1e-12:
            continue
        disc = B * B - 4 * A * C
        if disc <= 0:
            continue
        tau = (-B + math.sqrt(disc)) / (2 * A)   # later root = leaving range
        if 0 < tau < (e - s):
            out.append(s + tau)
    return out


def analyse(pos_path):
    tracks = read_pos(pos_path)
    nodes = sorted(tracks)
    geo = 0
    for i in range(len(nodes)):
        for j in range(i + 1, len(nodes)):
            geo += len(pair_breaks(tracks[nodes[i]], tracks[nodes[j]]))
    deg, ns = 0.0, 0
    t = T0
    while t <= T1:
        pts = [tracks[n].at(t) for n in nodes]
        for i in range(len(pts)):
            for j in range(i + 1, len(pts)):
                if math.hypot(pts[i][0] - pts[j][0], pts[i][1] - pts[j][1]) <= R:
                    deg += 2
        ns += 1
        t += 10.0
    mean_degree = deg / ns / len(nodes) if nodes else 0

    cbk_path = pos_path[:-len(".pos.gz")] + ".tr.cbk" if pos_path.endswith(".pos.gz") else ""
    cbk = [None, None, None]
    if cbk_path and os.path.exists(cbk_path):
        n_all = n_true = 0
        with open(cbk_path) as f:
            for line in f:
                parts = line.split()
                if len(parts) < 3:
                    continue
                tt, u, v = float(parts[0]), int(parts[1]), int(parts[2], 16)  # MAC is hex
                if u not in tracks or v not in tracks:
                    continue
                ux, uy = tracks[u].at(tt); vx, vy = tracks[v].at(tt)
                n_all += 1
                if math.hypot(ux - vx, uy - vy) > R:
                    n_true += 1
        cbk = [n_all, n_true, n_all - n_true]
    return geo, mean_degree, cbk


def main(paths):
    print("proto,model,nodes,seed,rate_kb,vmin,vmax,pause,geo_breaks,geo_rate,"
          "mean_degree,cbk_n,cbk_true,cbk_false,false_share")
    for p in paths:
        m = TAG.search(os.path.basename(p))
        if not m:
            sys.stderr.write("skip (name not recognised): %s\n" % p)
            continue
        geo, deg, (cn, ct, cf) = analyse(p)
        share = "" if not cn else "%.4f" % (float(cf) / cn)
        print("%s,%d,%.6f,%.2f,%s,%s,%s,%s" % (
            ",".join(m.groups()), geo, geo / (T1 - T0), deg,
            "" if cn is None else cn, "" if ct is None else ct,
            "" if cf is None else cf, share))
        sys.stdout.flush()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: python3 linkbreaks.py pos/*.pos.gz > results/linkbreaks.csv")
    main(sys.argv[1:])
