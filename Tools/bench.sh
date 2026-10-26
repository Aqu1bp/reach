#!/usr/bin/env bash
# Before/after video latency benchmark for Reach (macOS only).
#
#   Tools/bench.sh [OUT_DIR] [--no-build] [reach-probe bench options...]
#
# Builds reach-probe (release) and runs `reach-probe bench` for each scenario — "lan" (no cap),
# "wifi" (REACH_MAX_BITRATE_KBPS=$BENCH_WIFI_KBPS, default 2000: below what scrolling text needs, so
# the cap binds during a burst), "heavy" (no cap, --content video: a jump cut every frame, so every
# frame is intra-heavy) and "stress" (no cap, --fps 60 whatever --fps the caller passes: on a machine
# whose encoder can't keep up it shows how the sender behaves under overload) — twice: "baseline" with
# BENCH_BASELINE_ENV, "candidate" with BENCH_CANDIDATE_ENV (see below; both empty by default). Prints
# a Markdown comparison per scenario (also appended to $GITHUB_STEP_SUMMARY when set). Everything
# lands in OUT_DIR (default bench-out): <scenario>-<config>.json (report), .out (stdout), .log
# (stderr/ReachLog), and compare.md. Extra options (e.g. --cycles 6 --size 1512x982 --fps 60) go to
# every run (a scenario's own options, e.g. heavy's --content, come first and win). BENCH_SCENARIOS
# (default "lan wifi heavy stress") picks scenarios; BENCH_TIMEOUT (seconds, default
# 300) caps each run. See Tools/README-bench.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OUT="bench-out"
if [[ $# -gt 0 && "$1" != --* ]]; then
  OUT="$1"
  shift
fi
BUILD=1
EXTRA=()
for a in "$@"; do
  if [[ "$a" == "--no-build" ]]; then BUILD=0; else EXTRA+=("$a"); fi
done
TIMEOUT="${BENCH_TIMEOUT:-300}"
SCENARIOS="${BENCH_SCENARIOS:-lan wifi heavy stress}"
WIFI_KBPS="${BENCH_WIFI_KBPS:-2000}"
SCENARIO_ARGS=()

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

cd "$ROOT/Packages/ReachKit"
if [[ $BUILD -eq 1 ]]; then
  echo "==> swift build -c release --product reach-probe"
  swift build -c release --product reach-probe
fi
BIN="$ROOT/Packages/ReachKit/.build/release/reach-probe"
if [[ ! -x "$BIN" ]]; then
  echo "reach-probe not found at $BIN (build it, or drop --no-build)" >&2
  exit 1
fi

# Run "$@" with a wall-clock limit (macOS has no `timeout` by default).
run_with_timeout() {
  local secs="$1"
  shift
  "$@" &
  local pid=$!
  (
    sleep "$secs"
    echo "bench.sh: run exceeded ${secs}s, terminating" >&2
    kill -TERM "$pid" 2>/dev/null || true
    sleep 5
    kill -KILL "$pid" 2>/dev/null || true
  ) &
  local watchdog=$!
  local status=0
  wait "$pid" || status=$?
  pkill -P "$watchdog" 2>/dev/null || true
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  return "$status"
}

# The two arms. Each is a "|"-separated list of NAME=value settings (BENCH_BASELINE_ENV,
# BENCH_CANDIDATE_ENV), e.g. BENCH_CANDIDATE_ENV='REACH_FIELD_TRIALS=WebRTC-FrameDropper/Disabled'.
# Both empty (the default) is an A/A run: it shows how much two identical runs differ. Field trials
# are read once per process, so each run is its own process.
split_env() { local IFS='|'; read -r -a "$1" <<<"$2"; }
BASELINE_ENV=(); CANDIDATE_ENV=()
[[ -n "${BENCH_BASELINE_ENV:-}" ]] && split_env BASELINE_ENV "$BENCH_BASELINE_ENV"
[[ -n "${BENCH_CANDIDATE_ENV:-}" ]] && split_env CANDIDATE_ENV "$BENCH_CANDIDATE_ENV"
# Every run starts from no REACH_* settings, so a switch exported in the caller's shell can't leak
# into one arm and not the other.
UNSET_ENV=()
while read -r name; do UNSET_ENV+=(-u "$name"); done < <(env | sed -n 's/^\(REACH_[A-Za-z0-9_]*\)=.*/\1/p')

FAILED=0
run_bench() {
  local name="$1"
  shift
  echo "==> bench: $name"
  local status=0
  run_with_timeout "$TIMEOUT" env ${UNSET_ENV[@]+"${UNSET_ENV[@]}"} "$@" "$BIN" bench --label "$name" --report "$OUT/$name.json" \
    --verbose ${SCENARIO_ARGS[@]+"${SCENARIO_ARGS[@]}"} ${EXTRA[@]+"${EXTRA[@]}"} >"$OUT/$name.out" 2>"$OUT/$name.log" || status=$?
  cat "$OUT/$name.out"
  if [[ $status -ne 0 ]]; then
    echo "bench: $name exited with status $status (last log lines follow)" >&2
    tail -n 40 "$OUT/$name.log" >&2 || true
    FAILED=1
  fi
}

: >"$OUT/compare.md"
for scenario in $SCENARIOS; do
  case "$scenario" in
    lan) LINK_ENV=() ; SCENARIO_ARGS=() ; LINK_DESC="no bitrate cap" ;;
    wifi) LINK_ENV=("REACH_MAX_BITRATE_KBPS=$WIFI_KBPS") ; SCENARIO_ARGS=() ; LINK_DESC="stream capped at $WIFI_KBPS kbit/s" ;;
    heavy) LINK_ENV=() ; SCENARIO_ARGS=(--content video) ; LINK_DESC="no bitrate cap, jump-cut content" ;;
    stress) LINK_ENV=() ; SCENARIO_ARGS=(--fps 60) ; LINK_DESC="no bitrate cap, 60 fps" ;;
    *) echo "unknown scenario '$scenario' (lan|wifi|heavy|stress)" >&2; exit 2 ;;
  esac
  run_bench "$scenario-baseline" ${LINK_ENV[@]+"${LINK_ENV[@]}"} ${BASELINE_ENV[@]+"${BASELINE_ENV[@]}"}
  run_bench "$scenario-candidate" ${LINK_ENV[@]+"${LINK_ENV[@]}"} ${CANDIDATE_ENV[@]+"${CANDIDATE_ENV[@]}"}

  echo "==> compare ($scenario)"
  python3 "$ROOT/Tools/bench-compare.py" "$OUT/$scenario-baseline.json" "$OUT/$scenario-candidate.json" \
    --logs "$OUT/$scenario-baseline.log" "$OUT/$scenario-candidate.log" \
    --title "Reach video latency bench: $scenario ($LINK_DESC), baseline vs candidate" | tee -a "$OUT/compare.md"
  echo >>"$OUT/compare.md"
done
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "$OUT/compare.md" >>"$GITHUB_STEP_SUMMARY"
fi

exit "$FAILED"
