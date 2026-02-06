#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import os
import subprocess
import sys
from dataclasses import dataclass
from typing import Iterable, NamedTuple


@dataclass(frozen=True)
class ZoneStat:
    name: str
    src_file: str
    src_line: int
    total_ns: int
    total_perc: float
    count: int
    mean_ns: int
    min_ns: int
    max_ns: int
    std_ns: float

    def loc(self) -> str:
        return f"{self.src_file}:{self.src_line}"


class ZoneEvent(NamedTuple):
    name: str
    src_file: str
    src_line: int
    ns_since_start: int
    exec_time_ns: int
    thread_id: int


def _ns_to_ms(ns: int) -> float:
    return ns / 1_000_000.0


def _ns_to_us(ns: int) -> float:
    return ns / 1_000.0


def _find_tracy_tool(repo_root: str, tool_name: str) -> str | None:
    tools_dir = os.path.join(repo_root, ".tools", "tracy")
    if os.path.isdir(tools_dir):
        for dirpath, _dirnames, filenames in os.walk(tools_dir):
            if tool_name in filenames:
                path = os.path.join(dirpath, tool_name)
                if os.access(path, os.X_OK):
                    return path
    return None


def _repo_root() -> str:
    # scripts/profile/analyze_tracy.py -> repo root
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def _run_csvexport_aggregate(
    csvexport: str, trace_file: str, *, self_time: bool, filt: str, sep: str
) -> list[ZoneStat]:
    cmd = [csvexport]
    if self_time:
        cmd.append("-e")
    if filt:
        cmd.extend(["-f", filt])
    cmd.extend(["-s", sep, trace_file])

    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode != 0:
        raise SystemExit(
            f"tracy-csvexport failed ({p.returncode}).\n"
            f"cmd: {' '.join(cmd)}\n"
            f"stderr:\n{p.stderr}"
        )

    # csvexport always prints a header row.
    reader = csv.DictReader(p.stdout.splitlines(), delimiter=sep)
    out: list[ZoneStat] = []
    for row in reader:
        try:
            out.append(
                ZoneStat(
                    name=row["name"],
                    src_file=row["src_file"],
                    src_line=int(row["src_line"] or 0),
                    total_ns=int(float(row["total_ns"] or 0)),
                    total_perc=float(row["total_perc"] or 0.0),
                    count=int(row["counts"] or 0),
                    mean_ns=int(float(row["mean_ns"] or 0)),
                    min_ns=int(float(row["min_ns"] or 0)),
                    max_ns=int(float(row["max_ns"] or 0)),
                    std_ns=float(row["std_ns"] or 0.0),
                )
            )
        except KeyError as e:
            raise SystemExit(f"Unexpected csvexport header; missing column: {e}")
    return out


def _run_csvexport_unwrap(
    csvexport: str, trace_file: str, *, self_time: bool, filt: str, sep: str
) -> list[ZoneEvent]:
    cmd = [csvexport, "-u"]
    if self_time:
        cmd.append("-e")
    if filt:
        cmd.extend(["-f", filt])
    cmd.extend(["-s", sep, trace_file])

    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode != 0:
        raise SystemExit(
            f"tracy-csvexport failed ({p.returncode}).\n"
            f"cmd: {' '.join(cmd)}\n"
            f"stderr:\n{p.stderr}"
        )

    reader = csv.DictReader(p.stdout.splitlines(), delimiter=sep)
    out: list[ZoneEvent] = []
    for row in reader:
        out.append(
            ZoneEvent(
                name=row.get("name", ""),
                src_file=row.get("src_file", ""),
                src_line=int(row.get("src_line") or 0),
                ns_since_start=int(row.get("ns_since_start") or 0),
                exec_time_ns=int(row.get("exec_time_ns") or 0),
                thread_id=int(row.get("thread") or 0),
            )
        )
    return out


def _print_table(title: str, zones: Iterable[ZoneStat], top: int) -> None:
    rows = list(zones)[:top]
    if not rows:
        print(f"\n{title}: (no zones)\n")
        return

    print(f"\n{title} (top {len(rows)}):")
    print("  %instr  total_ms   mean_us   max_ms  count  location                         name")
    for z in rows:
        print(
            f"  {z.total_perc:6.2f} { _ns_to_ms(z.total_ns):8.2f} { _ns_to_us(z.mean_ns):8.2f} { _ns_to_ms(z.max_ns):7.2f}"
            f" {z.count:6d}  {z.loc():<32} {z.name}"
        )


def _pct(x: float) -> float:
    return x * 100.0


def _percentile(sorted_values: list[int], p: float) -> int:
    # p in [0,1]
    if not sorted_values:
        return 0
    if p <= 0:
        return sorted_values[0]
    if p >= 1:
        return sorted_values[-1]
    idx = int(round((len(sorted_values) - 1) * p))
    return sorted_values[idx]


def _guess_main_thread_id(events: list[ZoneEvent]) -> int | None:
    # Heuristic: the thread with most "frame" zones is the UI/main thread.
    counts: dict[int, int] = {}
    for e in events:
        if e.name == "frame":
            counts[e.thread_id] = counts.get(e.thread_id, 0) + 1
    if counts:
        return max(counts.items(), key=lambda kv: kv[1])[0]

    # Fallback: most events overall.
    counts = {}
    for e in events:
        counts[e.thread_id] = counts.get(e.thread_id, 0) + 1
    if counts:
        return max(counts.items(), key=lambda kv: kv[1])[0]
    return None


def _aggregate_events(events: Iterable[ZoneEvent], *, total_ref_ns: int) -> list[ZoneStat]:
    # Aggregate by (name, src_file, src_line).
    acc: dict[tuple[str, str, int], dict[str, float]] = {}
    for e in events:
        if e.exec_time_ns <= 0:
            continue
        k = (e.name, e.src_file, e.src_line)
        a = acc.get(k)
        if a is None:
            a = {"total": 0.0, "count": 0.0, "min": float(e.exec_time_ns), "max": float(e.exec_time_ns), "sumsq": 0.0}
            acc[k] = a
        a["total"] += float(e.exec_time_ns)
        a["count"] += 1.0
        if e.exec_time_ns < a["min"]:
            a["min"] = float(e.exec_time_ns)
        if e.exec_time_ns > a["max"]:
            a["max"] = float(e.exec_time_ns)
        a["sumsq"] += float(e.exec_time_ns) * float(e.exec_time_ns)

    out: list[ZoneStat] = []
    for (name, src_file, src_line), a in acc.items():
        total = int(a["total"])
        count = int(a["count"])
        mean = int(a["total"] / a["count"]) if count else 0
        # stddev over event durations
        std = 0.0
        if count > 1:
            avg = a["total"] / a["count"]
            var = (a["sumsq"] - 2.0 * a["total"] * avg + avg * avg * a["count"]) / (a["count"] - 1.0)
            std = var ** 0.5
        perc = (100.0 * total / total_ref_ns) if total_ref_ns > 0 else 0.0
        out.append(
            ZoneStat(
                name=name,
                src_file=src_file,
                src_line=src_line,
                total_ns=total,
                total_perc=perc,
                count=count,
                mean_ns=mean,
                min_ns=int(a["min"]),
                max_ns=int(a["max"]),
                std_ns=std,
            )
        )
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Summarize a .tracy capture using tracy-csvexport.")
    ap.add_argument("trace", help="Path to .tracy file")
    ap.add_argument("--top", type=int, default=25, help="Rows per section (default: 25)")
    ap.add_argument("--filter", default="", help="Substring filter for zone names (default: none)")
    ap.add_argument("--all-threads", action="store_true", help="Analyze all threads (default: main thread only)")
    ap.add_argument("--thread", type=int, default=None, help="Analyze a specific tracy thread id (overrides default)")
    args = ap.parse_args()

    trace = os.path.abspath(args.trace)
    if not os.path.isfile(trace):
        print(f"Trace not found: {trace}", file=sys.stderr)
        return 2

    repo_root = _repo_root()
    csvexport = _find_tracy_tool(repo_root, "tracy-csvexport") or "tracy-csvexport"

    # Use tab separator to avoid issues with commas in paths/names.
    sep = "\t"
    # We run unwrap mode to allow filtering to the main/UI thread (otherwise a blocking
    # zone in a background thread dominates the totals and becomes misleading).
    events_inclusive = _run_csvexport_unwrap(csvexport, trace, self_time=False, filt="", sep=sep)

    main_tid = _guess_main_thread_id(events_inclusive)
    tid = args.thread
    if tid is None and not args.all_threads:
        tid = main_tid

    if tid is None and not args.all_threads:
        print("Could not determine main thread id; re-run with --all-threads.", file=sys.stderr)
        return 2

    def thread_pred(e: ZoneEvent) -> bool:
        return True if args.all_threads or tid is None else (e.thread_id == tid)

    # Frame stats (inclusive "frame" zone on selected thread)
    frame_durations = sorted([e.exec_time_ns for e in events_inclusive if thread_pred(e) and e.name == "frame" and e.exec_time_ns > 0])

    print(f"Trace:  {trace}")
    if args.all_threads:
        print("Thread: all")
    else:
        print(f"Thread: {tid} (guessed main={main_tid})")
    if args.filter:
        print(f"Filter: {args.filter!r}")

    if frame_durations:
        mean_frame = sum(frame_durations) / len(frame_durations)
        p50 = _percentile(frame_durations, 0.50)
        p90 = _percentile(frame_durations, 0.90)
        p95 = _percentile(frame_durations, 0.95)
        p99 = _percentile(frame_durations, 0.99)
        mx = frame_durations[-1]
        over_16 = sum(1 for x in frame_durations if x >= 16_000_000)
        over_33 = sum(1 for x in frame_durations if x >= 33_000_000)
        over_100 = sum(1 for x in frame_durations if x >= 100_000_000)
        print("\nFrame (zone='frame', inclusive):")
        print(f"  count={len(frame_durations)} mean={_ns_to_ms(int(mean_frame)):.2f}ms p50={_ns_to_ms(p50):.2f}ms p95={_ns_to_ms(p95):.2f}ms p99={_ns_to_ms(p99):.2f}ms max={_ns_to_ms(mx):.2f}ms")
        print(f"  over16ms={over_16} ({_pct(over_16/len(frame_durations)):.1f}%) over33ms={over_33} ({_pct(over_33/len(frame_durations)):.1f}%) over100ms={over_100} ({_pct(over_100/len(frame_durations)):.1f}%)")

    # Hot zones: inclusive and self-time, filtered to selected thread and filter substring.
    def name_pred(e: ZoneEvent) -> bool:
        return True if not args.filter else (args.filter in e.name)

    incl_events_sel = [e for e in events_inclusive if thread_pred(e) and name_pred(e)]
    total_incl = sum(e.exec_time_ns for e in incl_events_sel if e.exec_time_ns > 0)
    zones_incl = _aggregate_events(incl_events_sel, total_ref_ns=total_incl)
    zones_incl_sorted = sorted([z for z in zones_incl if z.total_ns > 0], key=lambda z: z.total_ns, reverse=True)

    events_self = _run_csvexport_unwrap(csvexport, trace, self_time=True, filt="", sep=sep)
    self_events_sel = [e for e in events_self if thread_pred(e) and name_pred(e)]
    total_self = sum(e.exec_time_ns for e in self_events_sel if e.exec_time_ns > 0)
    zones_self = _aggregate_events(self_events_sel, total_ref_ns=total_self)
    zones_self_sorted = sorted([z for z in zones_self if z.total_ns > 0], key=lambda z: z.total_ns, reverse=True)

    print(f"\nZones (inclusive): {len(zones_incl_sorted)} (instrumented total { _ns_to_ms(total_incl):.2f}ms)")
    _print_table("Top zones by inclusive time", zones_incl_sorted, args.top)

    print(f"\nZones (self): {len(zones_self_sorted)} (instrumented total { _ns_to_ms(total_self):.2f}ms)")
    _print_table("Top zones by self time", zones_self_sorted, args.top)

    # Simple flags: look for a single zone that dominates self time.
    if zones_self_sorted:
        topz = zones_self_sorted[0]
        if topz.total_perc >= 25.0:
            print("\nFlags:")
            print(f"  - self-time hotspot >=25% instrumented: {topz.name} ({topz.total_perc:.2f}%) at {topz.loc()}")
        if topz.max_ns >= 16_000_000:
            print(f"  - zone max >=16ms: {topz.name} (max={_ns_to_ms(topz.max_ns):.2f}ms) at {topz.loc()}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
