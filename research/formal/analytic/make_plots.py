#!/usr/bin/env python
"""All figures -> plots/*.png (+ plots/*.csv table views).  Curves = closed form (model.py); markers = simulation
(results/simmarkers.json, results/simgrid.json) / repro (calibration).  Run after sim_markers.py / compare_sim_model.py /
calibration.py;  missing result files just omit the markers."""
import csv, json, os
from dataclasses import replace
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
import model as M
from calibration import load, SCN, clopper_pearson, LOGS, Fit

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "plots"); os.makedirs(OUT, exist_ok=True)
RES = os.path.join(HERE, "results")

# validated categorical palette (dataviz skill, light mode, slots 1-5; validate_palette.py: PASS, contrast WARN -> direct labels + csv table views)
SURF, INK, INK2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
C = dict(mixed="#2a78d6", uniform="#eb6834", disjoint="#1baf7a")
MECH = [("a_lww", "same register (LWW)", "#2a78d6"), ("b_revert", "same node, other field", "#eb6834"),
        ("c_list", "list append", "#1baf7a"), ("d_delete", "delete vs edit", "#eda100"), ("e_persist", "persistence path", "#e87ba4")]
NAMES = dict(mixed="(ii) 40/30/30 hot set", uniform="(iii) uniform over 500", disjoint="(i) all-disjoint")
LATS = [(0.05, "50 ms"), (0.4, "400 ms"), (2.0, "2 s")]
plt.rcParams.update({"figure.facecolor": SURF, "axes.facecolor": SURF, "savefig.facecolor": SURF, "axes.edgecolor": GRID,
                     "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2, "text.color": INK, "font.size": 10,
                     "axes.spines.top": False, "axes.spines.right": False, "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.8,
                     "axes.axisbelow": True, "legend.frameon": False, "lines.solid_capstyle": "round"})


def jload(name):
    f = os.path.join(RES, name)
    return json.load(open(f)) if os.path.exists(f) else None


def pr(x):
    return f"{x*100:.3g}%"


def save(fig, name, rows=None, header=None):
    fig.savefig(os.path.join(OUT, name + ".png"), dpi=150, bbox_inches="tight")
    plt.close(fig)
    if rows:
        with open(os.path.join(OUT, name + ".csv"), "w", newline="") as f:
            w = csv.writer(f); w.writerow(header); w.writerows(rows)


def cp_arr(k, n):
    return clopper_pearson(int(k), int(n))


# ------------------------------------------------------------------------------------------------ fig 1 & 2
def fig_vs_N(kind):
    markers = jload("simmarkers.json") or []
    Ns = np.arange(2, 101)
    fig, axes = plt.subplots(1, 3, figsize=(13, 4.2), sharey=True)
    rows = []
    for ax, (lat, lab) in zip(axes, LATS):
        for mix in ("uniform", "mixed", "disjoint"):
            ys = []
            for N in Ns:
                p = M.Params(N=int(N), lat=lat).mix(mix)
                v = M.breakdown(p)["total"] if kind == "rate" else M.per_hour(p)["total"]
                ys.append(v)
            ys = np.array(ys)
            ax.plot(Ns, ys, color=C[mix], lw=2, zorder=3)
            for N, y in zip(Ns, ys):
                if N in (10, 25, 50, 100):
                    rows.append((mix, lab, N, y))
            for m in markers:
                if m["mix"] == mix and abs(m["lat"] - lat) < 1e-9:
                    p = M.Params(N=m["N"], lat=lat).mix(mix)
                    lost = sum(m["lost"].values()); n = m["n"]
                    lo, hi = cp_arr(lost, n)
                    pers = M.breakdown(p)["e_persist"] * p.s * 0 + M.breakdown(p)["e_persist"]       # model persistence term added to sim collision term
                    f = p.s                                                                          # sim counts hot events only
                    scale = 1.0 if kind == "rate" else p.N * p.lam * 3600
                    y, ylo, yhi = (lost / n * f + pers) * scale, (lo * f + pers) * scale, (hi * f + pers) * scale
                    ax.errorbar(m["N"], y, yerr=[[max(y - ylo, 0)], [max(yhi - y, 0)]], fmt="none", ecolor=C[mix], elinewidth=1.2, capsize=0, zorder=4)
                    ax.plot(m["N"], y, "o", ms=8, mfc=C[mix], mec=SURF, mew=2, zorder=5)
        ax.set_yscale("log")
        ax.set_xlim(0, 106)
        ax.set_title(f"path latency L = 2 x {lab}", loc="left", fontsize=10.5, color=INK)
        ax.set_xlabel("users N")
    if kind == "rate":
        axes[0].set_ylabel("silently lost edits, fraction of acknowledged edits")
        axes[0].set_ylim(1e-5, 0.2)
        axes[0].yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: f"{v*100:g}%"))
    else:
        axes[0].set_ylabel("lost edits per hour, whole room")
        axes[0].set_ylim(0.1, 1.2e4)
    # direct labels in the last panel
    ax = axes[-1]
    for mix in ("uniform", "mixed", "disjoint"):
        p = M.Params(N=100, lat=2.0).mix(mix)
        y = M.breakdown(p)["total"] if kind == "rate" else M.per_hour(p)["total"]
        ax.annotate(NAMES[mix], (100, y), xytext=(-8, 9 if mix != "uniform" else -17), textcoords="offset points", ha="right", fontsize=9, color=INK2)
    handles = [Line2D([0], [0], color=C[m], lw=2, label=NAMES[m]) for m in ("disjoint", "mixed", "uniform")]
    handles.append(Line2D([0], [0], marker="o", color="none", mfc=INK2, mec=SURF, mew=2, ms=8, label="mechanism simulation (collision term) + model persistence"))
    fig.legend(handles=handles, loc="upper center", ncol=4, bbox_to_anchor=(0.5, 1.07), fontsize=9)
    fig.suptitle("Dify 1.17.1: silent edit loss vs room size (lam = 1 edit / 10 s / user, view lag 50 ms, persistence assumptions in NOTES.md)",
                 y=1.13, fontsize=11, color=INK, x=0.01, ha="left")
    save(fig, "fig1_loss_rate_vs_N" if kind == "rate" else "fig2_loss_per_hour_vs_N", rows, ["mix", "latency", "N", "value"])


# ------------------------------------------------------------------------------------------------ fig 3
def fig_pair():
    cal = jload("calibration.json")
    if cal is None:
        print("calibration.json missing; run calibration.py first"); return
    data = load(LOGS)
    L0, r, delta, sig = cal["L0"], cal["r"], cal["delta"], cal["sigma"]
    F = Fit(data, sig)
    F.z = np.linspace(-3, 3, 121); F.wz = np.exp(-F.z ** 2 / 2); F.wz /= F.wz.sum()
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(13, 4.3))
    rng = np.random.default_rng(0)
    # ---- left: same register (LWW): P(loss) vs |gap|
    g = np.logspace(-2, np.log10(4), 400)
    for lat, col, lab in ((0.0, C["mixed"], "no injected latency"), (0.4, C["uniform"], "400 ms injected latency")):
        L = 2 * lat + L0
        p = [(M.p_pair("lww", x + sig * F.z, L, r) * F.wz).sum() for x in g]
        a1.plot(g, p, color=col, lw=2, zorder=3)
        a1.text(0.015 if not lat else 1.1, 0.42 if not lat else 0.62, f"{lab}\nwindow L + r = {1000*(L+r):.0f} ms", fontsize=9, color=INK2, ha="left")
    rows = []
    for name, col in (("S2O", C["mixed"]), ("S2OM", C["mixed"]), ("S2OS", C["mixed"]), ("S2OL", C["uniform"])):
        d = data[name]; gaps = np.abs([x["s"] for x in d]); lost = np.array([x["lost"] for x in d])
        k, n = lost.sum(), len(d); lo, hi = cp_arr(k, n); gm = float(np.median(gaps))
        a1.errorbar(gm, k / n, yerr=[[k / n - lo], [hi - k / n]], fmt="none", ecolor=col, elinewidth=1.2, zorder=4)
        a1.plot(gm, k / n, "o", ms=9, mfc=col, mec=SURF, mew=2, zorder=5)
        off = {"S2O": (-4, -18), "S2OL": (8, 8), "S2OM": (6, 10), "S2OS": (6, 10)}[name]
        a1.annotate(f"{name} {k}/{n}", (gm, k / n), xytext=off, textcoords="offset points", fontsize=8.5, color=INK2, ha="left" if off[0] > 0 else "right")
        rows.append((name, "lww", gm, k, n, lo, hi))
    a1.set_xscale("log"); a1.set_xlim(0.008, 8); a1.set_xlabel("time between the two edits |tA - tB| (s), recorded end-of-action"); a1.set_ylabel("P(one edit silently lost)")
    a1.set_title("Same register (`outputs` value): window = L + r", loc="left", fontsize=10.5, color=INK)
    a1.set_ylim(-0.04, 1.08)
    # ---- right: different fields: P(loss) vs signed commit gap
    G = np.linspace(-0.45, 0.45, 600)
    for lat, extra, col, lab in ((0.0, 0.0, C["mixed"], "no latency"), (0.0, 0.25, C["disjoint"], "+250 ms rAF delay (r=250 ms)"), (0.4, 0.0, C["uniform"], "400 ms latency (L=0.8 s)")):
        L = 2 * lat + L0
        p = [(M.p_pair("diff", x + sig * F.z, L, r + extra) * F.wz).sum() for x in G]
        a2.plot(G, p, color=col, lw=2, zorder=3)
    a2.legend([Line2D([0], [0], color=c_, lw=2) for c_ in (C["mixed"], C["disjoint"], C["uniform"])],
              ["no latency: window r", "+250 ms rAF delay: window 0.25 s", "400 ms latency: window moves to\n0.8 s .. 0.8 s + r (off scale)"],
              loc="center right", fontsize=8, bbox_to_anchor=(1.0, 0.55))
    a2.set_xlim(-0.45, 0.85)
    for name, col in (("S1N", C["mixed"]), ("S1N-quiet", C["mixed"]), ("S1NR", C["disjoint"]), ("S1NL", C["uniform"])):
        d = data[name]
        s = np.array([x["s"] for x in d]) - delta; lost = np.array([x["lost"] for x in d], float)
        a2.plot(s, lost + rng.uniform(-0.035, 0.035, len(s)), "o", ms=4, mfc=col, mec="none", alpha=0.35, zorder=2)
    # binned fractions (S1N+quiet pooled, S1NR, S1NL)
    for names, col in ((("S1N", "S1N-quiet"), C["mixed"]), (("S1NR",), C["disjoint"]), (("S1NL",), C["uniform"])):
        s = np.concatenate([[x["s"] - delta for x in data[nm]] for nm in names]); lost = np.concatenate([[x["lost"] for x in data[nm]] for nm in names])
        edges = np.quantile(s, [0, .34, .67, 1.0]); edges[-1] += 1e-9
        for lo_e, hi_e in zip(edges[:-1], edges[1:]):
            m = (s >= lo_e) & (s < hi_e)
            if m.sum() == 0: continue
            k, n = int(lost[m].sum()), int(m.sum()); lo, hi = cp_arr(k, n)
            x = float(np.median(s[m]))
            a2.errorbar(x, k / n, yerr=[[k / n - lo], [hi - k / n]], fmt="none", ecolor=col, elinewidth=1.2, zorder=4)
            a2.plot(x, k / n, "o", ms=9, mfc=col, mec=SURF, mew=2, zorder=5)
            rows.append(("+".join(names), "diff", x, k, n, lo, hi))
    a2.set_xlabel(f"commit-time gap G = tA - tB - delta (s), delta = {1000*delta:.0f} ms fitted"); a2.set_ylabel("P(one edit silently lost)")
    a2.set_title("Same node, different fields (title vs desc): window = r", loc="left", fontsize=10.5, color=INK)
    a2.set_ylim(-0.08, 1.12)
    fig.suptitle(f"Pair collision model vs real-browser repro (n=20 per scenario). Fit: L0 = {1000*L0:.0f} ms, r = {1000*r:.0f} ms "
                 f"(95% profile range {1000*cal['r_range'][0]:.0f}-{1000*cal['r_range'][1]:.0f} ms); big dots = binned observed rate with Clopper-Pearson 95% bars",
                 y=1.03, fontsize=10, color=INK, x=0.01, ha="left")
    save(fig, "fig3_pair_collision_vs_window", rows, ["scenario", "kind", "x_median_gap", "k", "n", "cp_lo", "cp_hi"])


# ------------------------------------------------------------------------------------------------ fig 4
def fig_breakdown():
    fig, ax = plt.subplots(figsize=(9, 3.6))
    rows = []
    order = [(0.4, "L = 800 ms  (400 ms one-way)"), (0.05, "L = 100 ms  (50 ms one-way)"), (2.0, "L = 4 s  (2 s one-way)")]
    for i, (lat, lab) in enumerate(order):
        p = M.Params(N=50, lat=lat).mix("mixed")
        bd = M.breakdown(p)
        left = 0.0
        for key, nm, col in MECH:
            v = bd[key] * 100
            if v <= 0: continue
            ax.barh(i, v, left=left, height=0.55, color=col, edgecolor=SURF, linewidth=2, zorder=3)
            if v > 0.6:
                ax.text(left + v / 2, i, f"{v:.2f}%", ha="center", va="center", fontsize=8.5, color="white" if col in ("#2a78d6", "#eb6834") else INK)
            left += v
            rows.append((lab, key, v))
        ax.text(left + 0.08, i, f"total {left:.2f}%  ({M.per_hour(p)['total']:.0f}/h)", va="center", fontsize=9, color=INK2)
    ax.set_yticks(range(len(order))); ax.set_yticklabels([o[1] for o in order]); ax.invert_yaxis()
    ax.set_xlabel("silently lost edits, % of acknowledged edits"); ax.grid(axis="y", visible=False)
    ax.set_xlim(0, 7.2)
    handles = [plt.Rectangle((0, 0), 1, 1, color=c) for _, _, c in MECH]
    ax.legend(handles, [n for _, n, _ in MECH], loc="upper center", bbox_to_anchor=(0.5, -0.2), ncol=5, fontsize=8.5, handlelength=1, columnspacing=1.2)
    ax.set_title("Mechanism breakdown, N = 50 users, mix (ii) 40/30/30, lam = 0.1/s/user, r = 50 ms", loc="left", fontsize=10.5, color=INK)
    save(fig, "fig4_mechanism_breakdown_N50", rows, ["latency", "mechanism", "percent_of_edits"])


# ------------------------------------------------------------------------------------------------ fig 5 (sim vs model parity)
def fig_parity():
    grid = jload("simgrid.json")
    if not grid:
        return
    fig, (a, b) = plt.subplots(1, 2, figsize=(11.5, 4.6))
    tags = {"grid": "#2a78d6", "lam": "#eb6834", "H": "#1baf7a", "del": "#eda100", "mixed": "#e87ba4", "per_import": "#6250d6"}
    rows = []
    for R in grid:
        c, S, Mo, n = R["cfg"], R["sim"], R["model"], R["n"]
        for k in ("a_lww", "b_revert", "c_list", "d_delete"):
            pass
        x, y = Mo["total"], S["total"]
        lost = sum(R["lost"].values()); lo, hi = cp_arr(lost, n)
        a.errorbar(x, y, yerr=[[y - lo], [hi - y]], fmt="none", ecolor=tags[c["tag"]], elinewidth=1, zorder=3)
        a.plot(x, y, "o", ms=7, mfc=tags[c["tag"]], mec=SURF, mew=1.5, zorder=4)
        rows.append((c["tag"], c["N"], c["lat"], c["r"], c["lam"], c["H"], c["p_del"], n, lost, y, x))
    lim = [2e-4, 0.5]
    a.plot(lim, lim, color=INK2, lw=1, zorder=1); a.set_xscale("log"); a.set_yscale("log"); a.set_xlim(lim); a.set_ylim(lim)
    a.set_xlabel("closed form: loss per hot-node event"); a.set_ylabel("mechanism simulation (95% CP bars)")
    a.set_title("Formula vs simulation, all validation cells", loc="left", fontsize=10.5, color=INK)
    names = {"grid": "N x latency x r grid", "lam": "per-user rate sweep", "H": "contention sweep (hot nodes)", "del": "with node deletes", "mixed": "sparse mix (s=.25)", "per_import": "const rAF delay"}
    a.legend([Line2D([0], [0], marker="o", color="none", mfc=v, mec=SURF, ms=7) for v in tags.values()], [names[k] for k in tags], loc="lower right", fontsize=8.5)
    # per mechanism relative error vs exposure x
    for key, col, nm in (("a_lww", "#2a78d6", "same register"), ("b_revert", "#eb6834", "other field"), ("c_list", "#1baf7a", "list")):
        xs, ys = [], []
        for R in grid:
            c = R["cfg"]; k = {"a_lww": "same", "b_revert": "diff", "c_list": "list"}[key]
            cnt = R["lost"][k]
            if cnt < 30 or R["model"][key] <= 0: continue
            xs.append(R["model"][key]); ys.append(R["sim"][key] / R["model"][key] - 1)
        b.plot(xs, ys, "o", ms=6, mfc=col, mec=SURF, mew=1.2, label=nm)
    b.axhline(0, color=INK2, lw=1); b.axhspan(-0.1, 0.1, color=GRID, alpha=0.5, zorder=0)
    b.set_xscale("log"); b.set_xlabel("closed-form rate of that mechanism per hot event"); b.set_ylabel("(sim - formula) / formula")
    b.set_title("Relative error by mechanism (>= 30 lost edits per cell; blue below -10%: p_del >= 5% cells)", loc="left", fontsize=10.5, color=INK)
    b.legend(fontsize=8.5, loc="upper right")
    save(fig, "fig5_sim_vs_formula", rows, ["tag", "N", "lat", "r", "lam", "H", "p_del", "events", "lost", "sim_rate", "model_rate"])


# ------------------------------------------------------------------------------------------------ fig 6 (sensitivities)
def fig_sweeps():
    fig, (a, b, c) = plt.subplots(1, 3, figsize=(13, 4.2))
    rows = []
    lams = np.logspace(np.log10(1 / 60), np.log10(1 / 3), 60)
    for lat, ls, lab in ((0.05, ":", "50 ms"), (0.4, "-", "400 ms"), (2.0, "--", "2 s")):
        a.plot(lams, [M.breakdown(M.Params(N=50, lat=lat, lam=l).mix("mixed"))["total"] for l in lams], color=C["mixed"], ls=ls, lw=2)
        a.annotate(lab, (lams[-1], M.breakdown(M.Params(N=50, lat=lat, lam=lams[-1]).mix("mixed"))["total"]), xytext=(4, -3), textcoords="offset points", fontsize=9, color=INK2)
    a.set_xscale("log"); a.set_yscale("log"); a.set_xlabel("per-user edit rate (edits/s)")
    a.set_xticks([1 / 60, 1 / 30, 1 / 10, 1 / 3]); a.set_xticklabels(["1/60", "1/30", "1/10", "1/3"]); a.minorticks_off(); a.set_title("N=50, mix (ii): vs edit rate", loc="left", fontsize=10.5)
    a.set_ylabel("lost fraction of edits"); a.yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: f"{v*100:g}%"))
    rs = np.linspace(0.016, 0.25, 50)
    for key, col in (("a_lww", MECH[0][2]), ("b_revert", MECH[1][2])):
        b.plot(rs * 1000, [M.breakdown(M.Params(N=50, lat=0.4, r=r).mix("mixed"))[key] for r in rs], color=col, lw=2)
    b.set_xlabel("view lag r (ms)"); b.set_title("N=50, 400 ms, mix (ii): vs view lag r", loc="left", fontsize=10.5)
    b.set_yscale("log"); b.yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: f"{v*100:g}%"))
    b.legend([Line2D([0], [0], color=MECH[0][2], lw=2), Line2D([0], [0], color=MECH[1][2], lw=2)],
             ["same register (LWW): L + r", "other field = list append (identical): r"], fontsize=8.5, loc="center left")
    ss = np.linspace(0.02, 1, 40)
    for N, ls in ((10, ":"), (50, "-"), (100, "--")):
        base = M.Params(N=N, lat=0.4).mix("mixed")
        ys = [M.breakdown(replace(base, s=s_))["collisions"] for s_ in ss]
        c.plot(ss, ys, color=C["mixed"], ls=ls, lw=2)
        c.annotate(f"N={N}", (1, ys[-1]), xytext=(4, -3), textcoords="offset points", fontsize=9, color=INK2)
    c.set_xlabel("share s of edits on the 30-node hot set"); c.set_title("400 ms, mix (ii): collision term vs sharing", loc="left", fontsize=10.5)
    c.set_yscale("log"); c.yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: f"{v*100:g}%"))
    save(fig, "fig6_sensitivity", None, None)


if __name__ == "__main__":
    fig_vs_N("rate"); fig_vs_N("hour"); fig_pair(); fig_breakdown(); fig_parity(); fig_sweeps()
    print("plots written to", OUT, sorted(os.listdir(OUT)))
