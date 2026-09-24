# summarize.awk -- mean, SD and 95% confidence interval across seeds
#
# Usage:  awk -F, -f summarize.awk results/runs.csv > results/summary.csv
#
# Groups rows by every configuration column except the seed, and reports
# n, mean, sample SD and the 95% CI half-width (Student t) for the metrics
# the papers use. Plot means with the ci95 values as error bars.

BEGIN {
    OFS = ","
    split("12.706 4.303 3.182 2.776 2.571 2.447 2.365 2.306 2.262 2.228 2.201 2.179 2.160 2.145 2.131 2.120 2.110 2.101 2.093 2.086 2.080 2.074 2.069 2.064 2.060 2.056 2.052 2.048 2.045 2.042", tq, " ")
    nm = split("pdr delay thr_kbps nrl ctrl_per_node_s lbr pst pst_incl_censored", want, " ")
}
NR == 1 {
    for (i = 1; i <= NF; i++) col[$i] = i
    hdr = "proto,model,nodes,rate_kb,vmin,vmax,pause,n"
    for (k = 1; k <= nm; k++) hdr = hdr "," want[k] "_mean," want[k] "_sd," want[k] "_ci95"
    print hdr
    next
}
{
    g = $col["proto"] "," $col["model"] "," $col["nodes"] "," $col["rate_kb"] "," $col["vmin"] "," $col["vmax"] "," $col["pause"]
    if (!(g in n)) order[++ng] = g
    n[g]++
    for (k = 1; k <= nm; k++) {
        v = $col[want[k]]
        s[g, k] += v
        ss[g, k] += v * v
    }
}
END {
    for (j = 1; j <= ng; j++) {
        g = order[j]
        line = g "," n[g]
        for (k = 1; k <= nm; k++) {
            m = s[g, k] / n[g]
            if (n[g] > 1) {
                var = (ss[g, k] - n[g] * m * m) / (n[g] - 1)
                if (var < 0) var = 0
                sd = sqrt(var)
                df = n[g] - 1
                t = (df <= 30) ? tq[df] : 1.96
                ci = t * sd / sqrt(n[g])
            } else { sd = 0; ci = 0 }
            line = line "," sprintf("%.6g,%.6g,%.6g", m, sd, ci)
        }
        print line
    }
}
