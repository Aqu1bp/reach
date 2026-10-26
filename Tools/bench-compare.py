#!/usr/bin/env python3
"""Compare two `reach-probe bench` JSON reports (baseline vs candidate) as Markdown.

    Tools/bench-compare.py baseline.json candidate.json [--logs baseline.log candidate.log]

Prints tables of the key metrics side by side with absolute and relative deltas. With --logs, also
summarises the `[perf]` lines ReachLog wrote to stderr (`--verbose`): medians over the 2-second
samples in which video was actually flowing (fps >= 10), so idle stretches don't dilute them.
Standard library only.
"""

import argparse
import json
import math
import os
import re
import statistics
import sys


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f), None
    except FileNotFoundError:
        return {}, "missing"
    except (OSError, ValueError) as e:
        return {}, "unreadable (%s)" % e


def get(d, path):
    cur = d
    for part in path.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return None
    return cur


def num(v):
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, float)) and math.isfinite(v):
        return float(v)
    return None


def fmt(v, digits=1):
    if v is None:
        return "n/a"
    if abs(v - round(v)) < 1e-9:
        return "%d" % round(v)
    return ("%." + str(digits) + "f") % v


def min_abs_change(label):
    """Smallest absolute change worth calling better/worse, from the metric's unit."""
    low = label.lower()
    if "kbps" in low:
        return 100.0
    if "mbps" in low:
        return 0.2
    if re.search(r"\bms\b", low) or re.search(r"\bkb\b", low):
        return 0.5
    if "fps" in low:
        return 1.0
    if "%" in low:
        return 0.5
    return 1.0  # counts


def delta_cells(b, c, better, digits=1, min_abs=0.0):
    """(delta text, verdict) — verdict is 'better' / 'worse', or '' when the change is under 5% or
    under `min_abs` in absolute terms (e.g. 0.0 → 0.04 ms is not a 50% regression)."""
    if b is None or c is None:
        return "", ""
    d = c - b
    rel = None
    if abs(b) > 1e-9:
        rel = d / abs(b) * 100
    text = ("+" if d >= 0 else "") + fmt(d, digits)
    if rel is not None:
        text += " (%+.0f%%)" % rel
    verdict = ""
    if better and d != 0:
        significant = (rel is None or abs(rel) >= 5) and abs(d) >= min_abs
        if significant:
            improved = d < 0 if better == "lower" else d > 0
            verdict = "better" if improved else "worse"
    return text, verdict


# (label, json path, better: "lower" | "higher" | None)
SECTIONS = [
    ("Burst onset: the first frames after an idle pause", [
        ("Onset latency, first decoded frame (ms, median of cycles)", "aggregate.onset_ms", "lower"),
        ("Onset wait, first push → first decode (ms)", "aggregate.onset_wait_ms", "lower"),
        ("Onset latency, cycle 1 (ms)", "first_cycle.onset_ms", "lower"),
        ("Onset wait, cycle 1 (ms)", "first_cycle.onset_wait_ms", "lower"),
        ("Onset frames sent: KB per frame (median of cycles)", "aggregate.onset_frame_kb", "lower"),
        ("Onset frames sent: KB per frame, cycle 1", "first_cycle.onset_frame_kb", "lower"),
        ("Onset pacer delay (ms/packet)", "aggregate.onset_pacer_ms", "lower"),
        ("Onset pacer delay, cycle 1 (ms/packet)", "first_cycle.onset_pacer_ms", "lower"),
        ("Rest of burst: KB per frame", "aggregate.rest_frame_kb", None),
        ("Rest of burst: pacer delay (ms/packet)", "aggregate.rest_pacer_ms", "lower"),
    ]),
    ("Latency during motion: push → decoded frame (ms)", [
        ("Motion latency p50 (all cycles)", "pooled.motion_latency_ms.p50", "lower"),
        ("Motion latency p90", "pooled.motion_latency_ms.p90", "lower"),
        ("Motion latency p99", "pooled.motion_latency_ms.p99", "lower"),
        ("Motion latency max", "pooled.motion_latency_ms.max", "lower"),
        ("Motion latency p50, cycle 1", "first_cycle.motion_latency_ms.p50", "lower"),
        ("Motion latency p90 (median of cycles)", "aggregate.motion_latency_ms.p90", "lower"),
    ]),
    ("Smoothness during motion", [
        ("Decoded fps (median of cycles)", "aggregate.motion_fps", "higher"),
        ("Decoded fps, cycle 1", "first_cycle.motion_fps", "higher"),
        ("Generator: frames pushed per second, cycle 1 (fps)", "first_cycle.push_fps", None),
        ("Generator: tick interval, cycle 1 (ms, p50)", "first_cycle.tick_ms.p50", None),
        ("Generator: wake-up lateness, cycle 1 (ms, max)", "first_cycle.wake_late_ms.max", None),
        ("Generator: ms to produce a frame, cycle 1 (p50)", "first_cycle.render_ms.p50", None),
        ("Generator: pushVideoFrame call, cycle 1 (ms, p50)", "first_cycle.push_ms.p50", None),
        ("Generator: pushVideoFrame call, cycle 1 (ms, max)", "first_cycle.push_ms.max", None),
        ("Frames encoded per burst (median; above pushed = host refresh re-sends)", "aggregate.frames_encoded", None),
        ("Pushed frames (all cycles)", "pooled.motion_pushed", None),
        ("Decoded frames (all cycles)", "pooled.motion_decoded", "higher"),
        ("Frames never decoded (%)", "pooled.motion_drop_pct", "lower"),
        ("Gap between decoded frames p95 (ms)", "pooled.motion_gap_ms.p95", "lower"),
        ("Gap p99 (ms)", "pooled.motion_gap_ms.p99", "lower"),
        ("Gap max (ms)", "pooled.motion_gap_ms.max", "lower"),
        ("Gaps over 50 ms (all cycles)", "pooled.stalls_over_50ms", "lower"),
        ("Settle frames after motion (median)", "aggregate.settle_frames", None),
        ("Decodes whose barcode matched no push (all run)", "totals.unmatched_decodes", "lower"),
        ("Decodes whose two barcode rows disagree", "totals.barcode_rows_disagree", "lower"),
    ]),
    ("Session setup (ms)", [
        ("Connect", "connect_ms", "lower"),
        ("First frame (from connect)", "first_frame_ms", "lower"),
    ]),
    ("WebRTC stats over the scenario", [
        ("Host send bitrate (kbps)", "stats.host.bitrate_kbps", None),
        ("Host encode ms/frame", "stats.host.encode_ms_per_frame", "lower"),
        ("Host pacer ms/packet", "stats.host.pacer_ms_per_packet", "lower"),
        ("Host avg frame (KB)", "stats.host.avg_frame_kb", None),
        ("Host frames encoded", "stats.host.frames_encoded", None),
        ("Host huge frames", "stats.host.huge_frames", "lower"),
        ("Host key frames", "stats.host.key_frames", "lower"),
        ("Host NACKs received", "stats.host.nack_received", "lower"),
        ("Host PLIs received", "stats.host.pli_received", "lower"),
        ("Host target bitrate at end (kbps)", "stats.host.target_bitrate_kbps_end", None),
        ("Host available bitrate at end (kbps)", "stats.host.available_bitrate_kbps_end", None),
        ("Client assembly ms/frame", "stats.client.assembly_ms_per_frame", "lower"),
        ("Client jitter buffer ms/frame", "stats.client.jitter_buffer_ms_per_frame", "lower"),
        ("Client decode ms/frame", "stats.client.decode_ms_per_frame", "lower"),
        ("Client frames dropped", "stats.client.frames_dropped", "lower"),
        ("Client packets lost", "stats.client.packets_lost", "lower"),
        ("Client freezes", "stats.client.freezes", "lower"),
        ("Client freeze time (ms)", "stats.client.freeze_ms", "lower"),
    ]),
]

PERF_LINE = re.compile(r"\[perf\] (host|client) (.*)$")
NUMBER = re.compile(r"^(-?\d+(?:\.\d+)?)")

# (role, key, label, better, aggregate)
PERF_FIELDS = [
    ("host", "fps", "Host encoded fps", "higher", "median"),
    ("host", "enc", "Host encode (ms/frame)", "lower", "median"),
    ("host", "pacer", "Host pacer (ms/packet)", "lower", "median"),
    ("host", "pacer", "Host pacer worst sample (ms/packet)", "lower", "max"),
    ("host", "frame", "Host frame size (KB)", None, "median"),
    ("host", "rate", "Host rate (Mbps)", None, "median"),
    ("host", "vtdrop", "Host VideoToolbox-skipped frames (sum)", "lower", "sum"),
    ("host", "vtdrop", "Host VideoToolbox-skipped frames per sample", "lower", "median"),
    ("host", "encfps", "Host encoder budget frame rate (encfps)", None, "median"),
    ("host", "rtcfps", "Host WebRTC input frame rate (rtcfps)", None, "median"),
    ("host", "enctarget", "Host encoder target (enctarget, kbps)", None, "median"),
    ("client", "fps", "Client decoded fps", "higher", "median"),
    ("client", "asm", "Client assembly (ms/frame)", "lower", "median"),
    ("client", "jb", "Client jitter buffer (ms/frame)", "lower", "median"),
    ("client", "dec", "Client decode (ms/frame)", "lower", "median"),
]


def parse_perf(path):
    """{role: [{key: float}]} from `[perf] host|client k=v ...` lines; skips warm-up/ICE lines."""
    out = {"host": [], "client": []}
    if not path or not os.path.exists(path):
        return out
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = PERF_LINE.search(line.rstrip("\n"))
            if not m:
                continue
            role, rest = m.group(1), m.group(2)
            if "warming up" in rest or rest.startswith("ICE pairs") or rest.startswith(" "):
                continue
            sample = {}
            for tok in rest.split():
                if "=" not in tok:
                    continue
                k, v = tok.split("=", 1)
                n = NUMBER.match(v)
                if n:
                    sample[k] = float(n.group(1))
            if "fps" in sample:
                out[role].append(sample)
    return out


def perf_value(samples, key, how):
    active = [s for s in samples if s.get("fps", 0) >= 10]
    vals = [s[key] for s in active if key in s]
    if not vals:
        return None, 0
    if how == "max":
        return max(vals), len(vals)
    if how == "sum":
        return sum(vals), len(vals)
    return statistics.median(vals), len(vals)


def table(rows):
    lines = ["| Metric | Baseline | Candidate | Δ | |", "|---|---:|---:|---:|---|"]
    for label, b, c, better in rows:
        d, verdict = delta_cells(b, c, better, min_abs=min_abs_change(label))
        lines.append("| %s | %s | %s | %s | %s |" % (label, fmt(b), fmt(c), d, verdict))
    return "\n".join(lines)


def describe_run(name, r, err):
    if err:
        return "- **%s**: report %s" % (name, err)
    env = r.get("env") or {}
    env_text = ", ".join("`%s=%s`" % (k, env[k]) for k in sorted(env)) or "defaults"
    ok = "ok" if r.get("ok") else "FAILED"
    errs = r.get("errors") or []
    parts = [
        "- **%s** (%s): codec %s, encoder `%s`, decoder `%s`, %sx%s, route %s; env: %s"
        % (name, ok, r.get("codec") or "?", r.get("encoder") or "?", r.get("decoder") or "?",
           r.get("frame_width") or "?", r.get("frame_height") or "?", r.get("route") or "?", env_text)
    ]
    if errs:
        parts.append("  - errors: " + "; ".join(str(e) for e in errs))
    return "\n".join(parts)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("baseline")
    ap.add_argument("candidate")
    ap.add_argument("--logs", nargs=2, metavar=("BASELINE_LOG", "CANDIDATE_LOG"))
    ap.add_argument("--title", default="Reach video latency bench: baseline vs candidate")
    args = ap.parse_args()

    base, berr = load(args.baseline)
    cand, cerr = load(args.candidate)

    out = ["## " + args.title, ""]
    opts = get(cand, "options") or get(base, "options") or {}
    machine = get(cand, "machine") or get(base, "machine") or {}
    if opts:
        out.append("Scenario `%s`, content `%s`: %s cycles of %ss idle + %ss scrolling (%s pt/tick) at %s fps, %sx%s, "
                   "quality %s. Onset rows cover each burst's first %s frames (host stats snapshots)."
                   % (cand.get("scenario") or base.get("scenario") or "?", opts.get("content", "desktop"), opts.get("cycles"),
                      opts.get("idle_s"), opts.get("motion_s"), opts.get("step_pt", "?"), opts.get("fps"), opts.get("width"),
                      opts.get("height"), opts.get("quality"), opts.get("onset_window_frames", "?")))
    if machine:
        out.append("Machine: %s, %s, %s cores, macOS %s; hardware decode HEVC=%s H.264=%s."
                   % (machine.get("model"), machine.get("cpu"), machine.get("cores"), machine.get("os"),
                      machine.get("hw_hevc_decode"), machine.get("hw_h264_decode")))
    out.append("")
    out.append(describe_run("baseline", base, berr))
    out.append(describe_run("candidate", cand, cerr))
    if base.get("encoder") and cand.get("encoder") and base.get("encoder") != cand.get("encoder"):
        out.append("")
        out.append("**Note:** the two runs used different encoders; compare with care.")
    out.append("")
    out.append("Latency is measured per frame: the client reads the capture timestamp barcode out of each decoded "
               "frame and matches it to the moment that frame was pushed into HostEngine (same process, same clock). "
               "Bursts follow idle periods in which nothing is pushed, as in the real app.")
    out.append("")

    for title, rows in SECTIONS:
        out.append("### " + title)
        out.append("")
        out.append(table([(label, num(get(base, path)), num(get(cand, path)), better) for label, path, better in rows]))
        out.append("")

    if args.logs:
        bp, cp = parse_perf(args.logs[0]), parse_perf(args.logs[1])
        rows = []
        counts = []
        for role, key, label, better, how in PERF_FIELDS:
            b, bn = perf_value(bp[role], key, how)
            c, cn = perf_value(cp[role], key, how)
            rows.append((label, b, c, better))
            if key == "fps":
                counts.append("%s %d/%d" % (role, bn, cn))
        out.append("### `[perf]` lines (2-s samples with fps ≥ 10; medians unless noted)")
        out.append("")
        out.append("Active samples (baseline/candidate): " + ", ".join(counts) + ".")
        out.append("")
        out.append(table(rows))
        out.append("")

    out.append("Δ = candidate − baseline. 'better'/'worse' only when the change is at least 5% and not tiny in "
               "absolute terms (0.5 ms, 0.5 KB, 1 fps, 1 frame, 100 kbps). "
               "Single runs on a shared CI VM are noisy: look for consistent, large differences.")
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
