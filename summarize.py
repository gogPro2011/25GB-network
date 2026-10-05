#!/usr/bin/env python3
"""Сводка результатов run-bench.sh в CSV и Markdown-таблицы.

    ./summarize.py results/selectel-bm/baseline-* results/yandex-vm/baseline-*

Пишет summary.csv и tables.md в текущий каталог.
LINE_GBPS (по умолчанию 25) — номинал линка для колонки «% линии».
В ячейках: медиана (min–max), n — число валидных прогонов.
"""
import csv
import json
import os
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

LINE = float(os.environ.get("LINE_GBPS", "25"))
SCEN_ORDER = ["host", "pod-cross", "pod-local", "svc"]
SCEN_NAME = {
    "host": "нода-нода (hostNetwork)",
    "pod-cross": "pod-pod, разные ноды",
    "pod-local": "pod-pod, одна нода",
    "svc": "pod → ClusterIP",
}
DROP_RE = re.compile(r"(drop|discard|miss|err|fifo)", re.I)
RUN_RE = re.compile(r"^(.+?)__(.+?)__r(\d+)\.(json|txt)$")


def load_env(d):
    env = {}
    f = d / "env" / "summary.env"
    if f.exists():
        for line in f.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


def parse_iperf(p):
    try:
        d = json.loads(p.read_text())
    except Exception:
        return None
    if d.get("error") or "end" not in d:
        return None
    e = d["end"]
    ts = d.get("start", {}).get("test_start", {})
    r = {}
    if ts.get("protocol") == "UDP":
        s = e.get("sum", {})
        sec = s.get("seconds") or 1
        pk, lost = s.get("packets", 0), s.get("lost_packets", 0)
        if "sum_received" in e:
            r["gbps"] = e["sum_received"]["bits_per_second"] / 1e9
        else:
            r["gbps"] = (pk - lost) * ts.get("blksize", 0) * 8 / sec / 1e9
        r["mpps"] = (pk - lost) / sec / 1e6
        r["loss_pct"] = s.get("lost_percent", 0.0)
    else:
        r["gbps"] = e["sum_received"]["bits_per_second"] / 1e9
        r["retr"] = e.get("sum_sent", {}).get("retransmits", 0)
        if "sum_received_bidir_reverse" in e:
            r["gbps"] += e["sum_received_bidir_reverse"]["bits_per_second"] / 1e9
            r["retr"] += e.get("sum_sent_bidir_reverse", {}).get("retransmits", 0)
    return r


def parse_netperf(p):
    kv = {}
    for line in p.read_text(errors="replace").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            kv[k.strip()] = v.strip()
    try:
        r = {"tps": float(kv["THROUGHPUT"])}
    except (KeyError, ValueError):
        return None
    for k in ("MEAN_LATENCY", "P50_LATENCY", "P90_LATENCY", "P99_LATENCY"):
        try:
            r[k.lower()] = float(kv[k])
        except (KeyError, ValueError):
            pass
    return r


def parse_mpstat(p, skip):
    try:
        h = json.loads(p.read_text())["sysstat"]["hosts"][0]
    except Exception:
        return None
    n = h.get("number-of-cpus") or 1
    rows = []
    for s in h.get("statistics", [])[skip:]:
        a = next((c for c in s.get("cpu-load", []) if c.get("cpu") == "all"), None)
        if a:
            rows.append(a)
    if not rows:
        return None

    def m(f):
        return statistics.mean(f(a) for a in rows)

    return {
        "cores": m(lambda a: (100 - a["idle"]) / 100 * n),
        "soft": m(lambda a: a["soft"] / 100 * n),
        "steal": m(lambda a: a.get("steal", 0.0)),
    }


def read_counters(p):
    c = {}
    if p.exists():
        for line in p.read_text().splitlines():
            parts = line.split()
            if len(parts) == 3:
                try:
                    c[(parts[0], parts[1])] = int(parts[2])
                except ValueError:
                    pass
    return c


def counter_delta(d, name, pod):
    b = read_counters(d / "counters" / f"{name}__before-{pod}.txt")
    a = read_counters(d / "counters" / f"{name}__after-{pod}.txt")
    if not a or not b:
        return None
    return sum(
        max(0, v - b.get(k, 0))
        for k, v in a.items()
        if k[0] != "nstat" and DROP_RE.search(k[1])
    )


def collect(d):
    env = load_env(d)
    skip = int(env.get("OMIT", 5))
    idle = {
        "a": parse_mpstat(d / "env" / "idle__a.json", 0),
        "b": parse_mpstat(d / "env" / "idle__b.json", 0),
    }
    runs = defaultdict(list)
    for p in sorted((d / "raw").glob("*")):
        m = RUN_RE.match(p.name)
        if not m:
            continue
        sc, t, _, ext = m.groups()
        name = p.name.rsplit(".", 1)[0]
        r = parse_netperf(p) if ext == "txt" else parse_iperf(p)
        if r is None:
            print(f"  пропущен невалидный прогон: {d.name}/{p.name}", file=sys.stderr)
            continue
        for side, pod in (("a", "srv-host"), ("b", "cli-host")):
            cpu = parse_mpstat(d / "cpu" / f"{name}__{side}.json", skip)
            if cpu:
                base = idle[side]["cores"] if idle[side] else 0.0
                r[f"cores_{side}"] = max(0.0, cpu["cores"] - base)
                r[f"soft_{side}"] = cpu["soft"]
                r[f"steal_{side}"] = cpu["steal"]
            drops = counter_delta(d, name, pod)
            if drops is not None:
                r[f"drops_{side}"] = drops
        if "gbps" in r and "cores_a" in r and "cores_b" in r:
            tot = r["cores_a"] + r["cores_b"]
            r["gbps_per_core"] = r["gbps"] / tot if tot > 0.05 else None
        runs[(sc, t)].append(r)
    return env, runs


def agg(runs, key):
    vals = [r[key] for r in runs if r.get(key) is not None]
    if not vals:
        return None
    return statistics.median(vals), min(vals), max(vals), len(vals)


def cell(a, nd=1, spread=True):
    if a is None:
        return "—"
    med, lo, hi, _ = a
    s = f"{med:.{nd}f}"
    return f"{s} ({lo:.{nd}f}–{hi:.{nd}f})" if spread and hi - lo > 0 else s


def scenarios(runs):
    present = {sc for sc, _ in runs}
    return [s for s in SCEN_ORDER if s in present] + sorted(present - set(SCEN_ORDER))


def tables(d, env, runs):
    out = []
    title = f"{env.get('CLUSTER', d.parent.name)} / {env.get('LABEL', d.name)}"
    out.append(f"## {title}\n")
    out.append(
        f"Ноды: `{env.get('NODE_A', '?')}` → `{env.get('NODE_B', '?')}`, "
        f"зона {env.get('ZONE_A', '?')}/{env.get('ZONE_B', '?')}, MTU пода {env.get('POD_MTU', '?')}, "
        f"uplink {env.get('UPLINK_A', '?')}, {env.get('DUR', '?')} c × {env.get('REPEATS', '?')} прогонов, "
        f"N = {env.get('PARALLEL', '?')} потоков. Ячейки: медиана (min–max).\n"
    )
    scs = scenarios(runs)
    host_n = agg(runs.get(("host", "tcp-n"), []), "gbps")

    out.append("### Пропускная способность TCP, Гбит/с\n")
    out.append("| Сценарий | 1 поток | N потоков | N, reverse | N, bidir (сумма) | % от host | % линии | Retr (N) |")
    out.append("|---|---|---|---|---|---|---|---|")
    for sc in scs:
        n = agg(runs.get((sc, "tcp-n"), []), "gbps")
        pct_host = f"{n[0] / host_n[0] * 100:.0f}%" if n and host_n else "—"
        pct_line = f"{n[0] / LINE * 100:.0f}%" if n else "—"
        out.append(
            f"| {SCEN_NAME.get(sc, sc)} | {cell(agg(runs.get((sc, 'tcp-1'), []), 'gbps'), 2)} "
            f"| {cell(n, 2)} | {cell(agg(runs.get((sc, 'tcp-n-rev'), []), 'gbps'), 2)} "
            f"| {cell(agg(runs.get((sc, 'tcp-n-bidir'), []), 'gbps'), 2)} | {pct_host} | {pct_line} "
            f"| {cell(agg(runs.get((sc, 'tcp-n'), []), 'retr'), 0, False)} |"
        )

    out.append("\n### Стоимость в CPU (TCP, N потоков)\n")
    out.append("| Сценарий | Гбит/с | Ядер A | Ядер B | softirq A, ядер | softirq B, ядер | steal A, % | steal B, % | Гбит/с на ядро | NIC drops A / B |")
    out.append("|---|---|---|---|---|---|---|---|---|---|")
    for sc in scs:
        rs = runs.get((sc, "tcp-n"), [])
        if not rs:
            continue
        da, db = agg(rs, "drops_a"), agg(rs, "drops_b")
        out.append(
            f"| {SCEN_NAME.get(sc, sc)} | {cell(agg(rs, 'gbps'), 2, False)} "
            f"| {cell(agg(rs, 'cores_a'), 2, False)} | {cell(agg(rs, 'cores_b'), 2, False)} "
            f"| {cell(agg(rs, 'soft_a'), 2, False)} | {cell(agg(rs, 'soft_b'), 2, False)} "
            f"| {cell(agg(rs, 'steal_a'), 1, False)} | {cell(agg(rs, 'steal_b'), 1, False)} "
            f"| {cell(agg(rs, 'gbps_per_core'), 2, False)} "
            f"| {cell(da, 0, False)} / {cell(db, 0, False)} |"
        )

    out.append("\n### Задержка и соединения (netperf, 1 байт запрос/ответ)\n")
    out.append("| Сценарий | RR p50, мкс | RR p90, мкс | RR p99, мкс | RR, транз./с | CRR, соед./с |")
    out.append("|---|---|---|---|---|---|")
    for sc in scs:
        rr, crr = runs.get((sc, "rr"), []), runs.get((sc, "crr"), [])
        if not rr and not crr:
            continue
        out.append(
            f"| {SCEN_NAME.get(sc, sc)} | {cell(agg(rr, 'p50_latency'), 0)} | {cell(agg(rr, 'p90_latency'), 0)} "
            f"| {cell(agg(rr, 'p99_latency'), 0)} | {cell(agg(rr, 'tps'), 0, False)} | {cell(agg(crr, 'tps'), 0, False)} |"
        )

    out.append("\n### UDP\n")
    out.append(f"| Сценарий | UDP {env.get('UDP_LEN', 'MTU')} Б, Гбит/с | потери, % | UDP 64 Б, Mpps | потери, % |")
    out.append("|---|---|---|---|---|")
    for sc in scs:
        um, u64 = runs.get((sc, "udp-mtu"), []), runs.get((sc, "udp-64"), [])
        if not um and not u64:
            continue
        out.append(
            f"| {SCEN_NAME.get(sc, sc)} | {cell(agg(um, 'gbps'), 2)} | {cell(agg(um, 'loss_pct'), 2, False)} "
            f"| {cell(agg(u64, 'mpps'), 3)} | {cell(agg(u64, 'loss_pct'), 2, False)} |"
        )
    out.append("")
    return out


def main(dirs):
    if not dirs:
        sys.exit(__doc__)
    md = ["# Результаты сетевых тестов\n"]
    metrics = ["gbps", "retr", "mpps", "loss_pct", "tps", "p50_latency", "p90_latency",
               "p99_latency", "cores_a", "cores_b", "soft_a", "soft_b", "steal_a", "steal_b",
               "gbps_per_core", "drops_a", "drops_b"]
    with open("summary.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["cluster", "label", "dir", "scenario", "test", "metric", "median", "min", "max", "n"])
        for dpath in dirs:
            d = Path(dpath)
            if not (d / "raw").is_dir():
                print(f"пропускаю {d}: нет raw/", file=sys.stderr)
                continue
            env, runs = collect(d)
            md += tables(d, env, runs)
            for (sc, t), rs in sorted(runs.items()):
                for k in metrics:
                    a = agg(rs, k)
                    if a:
                        w.writerow([env.get("CLUSTER", ""), env.get("LABEL", ""), d.name, sc, t, k,
                                    round(a[0], 4), round(a[1], 4), round(a[2], 4), a[3]])
    Path("tables.md").write_text("\n".join(md))
    print("Записано: summary.csv, tables.md")


if __name__ == "__main__":
    main(sys.argv[1:])
