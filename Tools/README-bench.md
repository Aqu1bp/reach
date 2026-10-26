# Video latency bench

`reach-probe bench` runs a real `HostEngine` (fed by the synthetic desktop) and a real
`ClientEngine`/`ClientSession` in one process. Signaling goes through an in-process loopback relay
(`local://…`), so no ntfy/MQTT and no internet are needed; media goes over real WebRTC on the
machine's own host candidates, through the same encoder, pacer, jitter buffer and decoder as the
apps. Every frame carries its creation time in a barcode, and the client reads it back from each
decoded frame, so latency is measured per frame on one clock.

## Run it on a Mac

```sh
Tools/bench.sh                          # build, run baseline + candidate (see below), print the comparison
Tools/bench.sh out --cycles 6           # results in ./out, 6 cycles per run
Tools/bench.sh out --no-build --fps 120 --size 1512x982
```

`bench.sh` builds `reach-probe` in release mode, then for each link scenario (`BENCH_SCENARIOS`,
default `lan wifi heavy stress`) runs the bench twice, each in its own process (field trials are read once at
startup):

| scenario | link |
|---|---|
| `lan` | no cap (a loopback has ~50 Mbit/s to spare) |
| `wifi` | `REACH_MAX_BITRATE_KBPS=2000` (`BENCH_WIFI_KBPS`) caps the stream below what scrolling text needs (about 3 Mbit/s at 30 fps), so rate control and the pacer actually engage |
| `heavy` | no cap, `--content video`: a jump cut every frame, so every frame is intra-heavy |
| `stress` | no cap, `--fps 60` regardless of the `--fps` passed to the script: where the encoder can't keep up (the CI VM takes 15-20 ms per frame) it shows how the sender behaves under overload |

and, within each scenario, two runs whose settings come from the environment, as `|`-separated
`NAME=value` lists:

| run | environment |
|---|---|
| `baseline` | `BENCH_BASELINE_ENV` |
| `candidate` | `BENCH_CANDIDATE_ENV` |

Both are empty by default, which makes an A/A run: the difference between two identical
configurations, i.e. the noise floor. For example, to measure WebRTC's frame dropper:

```sh
BENCH_CANDIDATE_ENV='REACH_FIELD_TRIALS=WebRTC-FrameDropper=Disabled' Tools/bench.sh out --fps 60
```

Every run starts with all `REACH_*` variables cleared, so nothing exported in your shell leaks into
one arm only.

Two things the bench can't show. `wifi` caps the encoder's bitrate, not the link: nothing is ever
lost or queued in the network, so a change that sends more aggressively looks free here and needs a
real constrained link (cellular, a shaped Wi-Fi) to judge. And a CI VM's encoder takes 15-20 ms per
1512x982 frame against a few ms on Apple silicon, so overload results from CI don't carry over to a
Mac; run the comparison on real hardware before trusting a latency claim.

The output directory holds `<scenario>-<run>.json` (report), `.out` (summary), `.log` (stderr,
including ReachLog's `[perf]` lines) and `compare.md` (one table per scenario, also appended to
`$GITHUB_STEP_SUMMARY` in CI). `BENCH_TIMEOUT` (seconds, default 300) caps each run.

To run one configuration by hand:

```sh
cd Packages/ReachKit
swift build -c release --product reach-probe
.build/release/reach-probe bench --report run.json --verbose 2>run.log
python3 ../../Tools/bench-compare.py a.json b.json --logs a.log b.log
```

Options: `--size WxH` (default 1512x982), `--fps N` (60), `--scenario bursts|continuous` (bursts),
`--content text|video|desktop` (text),
`--idle S` (3), `--motion S` (2), `--cycles N` (4), `--settle S` (2), `--step PT` (4 points per tick),
`--quality sharp|balanced|smooth|dataSaver` (balanced, the iPhone default), `--policy all|relay|nohost`,
`--label NAME`, `--report path.json`, `--verbose`. It exits non-zero if the session never connects or
no frame decodes.

Content: `text` (default) renders, once, a page four frames tall of dense multi-column monospaced
text (black on white, like a code editor), and each frame is a window of it copied row by row
(about a millisecond), scrolled `--step` points (×2 px) per tick and bouncing at the ends. Every
pixel changes every frame, the worst case for the encoder. `video` uses the same page but shows a random window of it every frame: scrolling text is a
nearly free translation for HEVC's inter prediction (~9 KB frames uncapped), while jump cuts make
every frame expensive and put real pressure on rate control even without a cap. `desktop` is the
interactive synthetic desktop, redrawn with CoreGraphics every frame (~18 ms at 1512×982 on a CI VM, so it can't hold
60 fps). Each cycle's `render_ms` and `push_fps` (and the table's "Generator" rows) show whether
the generator kept up. The default size is 1512×982, what a phone in portrait gets from a
3024×1964 display.

CI runs at `--fps 30`: the macos-15 VM encodes 1512×982 HEVC at about 21 ms per frame, so 60 fps
saturates the encoder and the resulting drops hide everything else. On a real Mac use 60 (or 120).

### The generator has to keep up

Each push is timed in parts, per cycle in the JSON and on a `generator:` line in the summary:
`tick_ms` (interval between pushes), `wake_late_ms` (how late the scenario thread woke for its
tick; it sleeps with `mach_wait_until` and spins the last 25 ms, which keeps the cadence exact on a VM but costs about one core during a burst), `render_ms` (producing the
frame), `barcode_ms` (reading the pushed frame's timestamp), `push_ms` (the
`HostEngine.pushVideoFrame` call itself) and `record_ms`. If `push_ms` is large, the host's frame
intake is blocking its caller, which in the app would stall ScreenCaptureKit's delivery queue.

A generator that can't hold the push rate changes what is measured: `HostEngine` re-sends the last
frame 34 ms after a push when no new one arrives (the post-motion sharpening refresh), so at
under ~30 pushes/s those re-sends roughly double the encoder's input during "motion". Each cycle's
`frames_encoded` (host stats, whole burst) above `motion_pushed` shows it; compare
pushed / encoded / sent / decoded on each cycle line.

### Never-decoded frames

Frames pushed but never decoded are either dropped before or by the encoder (pushed > encoded)
or decoded with a barcode that couldn't be read. The text and video content draw the timestamp
in two barcode rows; `totals` reports `unmatched_decodes` (neither row matched a push),
`barcode_rows_disagree` and `recovered_by_row1`. Barcode blocks are 1/48 of the frame width, read
by averaging a 5×5 grid over the middle of each block.

## Scenario

`bursts` (default) repeats `--cycles` times: `--idle` seconds pushing nothing at all (so the host's
refresh and 1 Hz keepalive and the encoder's idle behaviour run exactly as in the app), then
`--motion` seconds pushing one frame per tick while the list scrolls a few points per tick, so
every frame really changes. This is the case the sender tuning targets: the first frames of a
movement after a pause. `continuous` pushes every tick for the whole run.

## Reading the table

All latencies are *push → decoded* in milliseconds: from `HostEngine.pushVideoFrame` to the
decoded frame reaching `ClientSession.onVideoFrame` (encode, pacer, network, assembly, jitter
buffer, decode). Display time on a phone comes on top.

- **Burst onset** (own table): latency of the first decoded frame of each burst; **onset wait**,
  time from the burst's first push until any of its frames decodes (includes frames dropped before
  it); and, from host stats snapshots taken just before each burst and after its first 15 frames
  (a quarter second at 60 fps), the **KB per frame sent** and **pacer ms/packet** of those first
  frames against the rest of the burst. Oversized first frames after a pause (the encoder budgeting
  for the idle frame rate) show up here, most clearly in the `wifi` scenario. "cycle 1" rows show
  the first burst of the session, where the bandwidth estimate is still at its starting value.
- **Motion latency p50…max**: over every frame pushed during motion, pooled over all cycles.
- **Decoded fps**, **frames never decoded**: how many of the pushed frames arrived.
- **Gap p95/p99/max**, **gaps over 50 ms**: time between consecutive decoded frames during motion,
  a choppiness measure (16.7 ms is perfect at 60 fps).
- **Settle frames**: frames decoded in the `--settle` seconds after motion stops (the refresh frames
  that sharpen the picture).
- **WebRTC stats**: deltas of the cumulative counters between the start and the end of the
  scenario (bitrate, encode ms/frame, pacer ms/packet, huge frames, jitter buffer, assembly and
  decode ms/frame, freezes, drops, NACK/PLI).
- **`[perf]` lines**: medians of the 2-second `perf` samples in which video was flowing
  (fps ≥ 10), parsed from the logs; `vtdrop` is the number of frames VideoToolbox's rate control
  skipped, `encfps` the frame rate the encoder budgets for, `rtcfps` WebRTC's measured input rate,
  `enctarget` the encoder's target in kbit/s.

Δ is candidate − baseline; "better"/"worse" appear only for changes of 5% or more that are not
tiny in absolute terms (0.5 ms, 0.5 KB, 1 fps, 1 frame, 100 kbps). The header
lists codec and encoder/decoder implementation of each run. On GitHub's macOS VMs hardware video
encode may be missing, so the encoder can be a software one: compare runs with the same
implementation, and treat single CI runs as noisy (look for large, consistent differences, or
raise `--cycles`).
