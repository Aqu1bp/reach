# Reach — design

Reach lets you use your Mac from your iPhone, from anywhere. Two apps:

* **Reach Host** (macOS menu-bar app) captures the screen, encodes it, and injects input.
* **Reach** (iOS app) shows the Mac's screen and turns touch into Mac input.

## System architecture

```
 iPhone (Reach)                                          Mac (Reach Host)
 ┌──────────────────────────┐                            ┌──────────────────────────────┐
 │ SwiftUI shell            │                            │ Menu bar UI / onboarding      │
 │ RemoteScreenView (Metal) │◀── HEVC/H.264 (SRTP) ──────│ ScreenCaptureKit → WebRTC     │
 │ Gesture engine           │─── control (SCTP, rel.) ──▶│ InputInjector (CGEvent)       │
 │ Keyboard / shortcuts     │─── pointer (SCTP, unrel.)─▶│ CursorMonitor, Clipboard,     │
 │ Local cursor rendering   │◀── cursor  (SCTP, unrel.)──│ Apps/Windows                  │
 │ ClientEngine (ReachCore) │                            │ HostEngine (ReachCore)        │
 └────────────┬─────────────┘                            └──────────────┬───────────────┘
              │    encrypted signaling (offer/answer/ICE), a few msgs   │
              └────────────▶  ntfy.sh  +  HiveMQ MQTT  ◀────────────────┘
                     (public relays, used redundantly; see "Networking")
```

`Packages/ReachKit` is shared by both apps:

* `ReachProtocol` — wire types (`ClientMessage`, `HostMessage`, `PointerPacket`, `CursorPacket`, `MacKey`).
* `ReachCore` — identity, pairing, envelope crypto, relays, WebRTC sessions, `HostEngine`, `ClientEngine`/`ClientSession`.
* `reach-probe` — CLI used for end-to-end testing (synthetic host, headless client, latency measurement).

### Networking ("works anywhere")

* **Media and input are peer-to-peer** over WebRTC (ICE + DTLS-SRTP + SCTP). ICE tries every path at
  once — LAN, IPv6, NAT hole-punching via public STUN — and keeps the best. Wi-Fi ⇄ cellular switches
  trigger an automatic ICE restart; the session survives.
* **Signaling** (pairing, offer/answer, candidates — a handful of small messages per connection) goes
  through two independent public relays at the same time (ntfy.sh over WebSocket/HTTP and the HiveMQ
  public MQTT broker over WebSocket). Either one is enough; the receiver de-duplicates.
* **Security**: relays only see opaque envelopes. Each device has an X25519 identity; envelopes are
  ChaCha20-Poly1305 encrypted with a key derived from both static keys, timestamped, and replay-filtered.
  The SDP (and therefore the DTLS certificate fingerprints) is authenticated end-to-end, so the media
  path cannot be man-in-the-middled even by a malicious relay.
* **Pairing**: the Mac shows a QR code (`reach://pair?...`) containing its id, public key and a
  single-use 128-bit secret that expires after 10 minutes. The iPhone proves it saw the code with
  HMAC(secret, its id ‖ its public key). Scanning with the stock Camera app opens Reach directly.
* **TURN**: optional, configured on the Mac and shared to paired iPhones (needed only when both sides
  are behind symmetric NATs; IPv6 and typical home/cellular NATs connect directly). The URL(s) and
  username are kept in the Mac's preferences, the password in its keychain. The Mac sends its full
  ICE server list when pairing and in every probe answer, and the iPhone probes on Home and with each
  connection attempt, so adding or removing the server takes effect on the next connection or retry.
  If the Mac answers but ICE never connects, the iPhone says the networks may be blocking a direct
  connection and, when no TURN server is set, points to Reach Host's settings.

### Video pipeline

* ScreenCaptureKit captures the selected display, NV12 video-range, BT.709, cursor **excluded**, up to
  120 fps (the iPhone's cap, at most the display's refresh rate; 30 in Data Saver), only when content changes. It scales in hardware, so the encoder only ever sees the pixels
  that are worth sending.
* **Stream size follows what the iPhone shows.** The iPhone reports how many of its pixels the Mac's
  display covers (it changes with zoom and rotation, debounced). The host picks ½, ¾ or full native
  resolution to match (Sharp keeps a 10% margin so text stays crisp while a zoom is still in progress), capped by what the
  measured bandwidth can carry (≈3.6 bits per native pixel per second, with hysteresis so it doesn't
  flap). In portrait the phone shows a 3024-px-wide display on 1290 px, so it gets 1512×982: a quarter
  of the pixels, so encoding is about 3× faster and it needs far fewer bits than native.
* **Codec: HEVC when both ends handle it in hardware, else H.264.** HEVC needs roughly a third fewer
  bits for the same picture, and keeps far more detail during fast motion on a slow link (measured on
  scrolling text at 2.5 Mbit/s: 45–48 dB vs 36–43 dB). It's offered first in SDP; iPhones running an
  older Reach (H.264 only) negotiate H.264.
* **Own VideoToolbox encoder with low-latency rate control** (`ScreenVideoEncoder`), for both codecs.
  WebRTC's bundled encoder uses the default rate control, which leaves text blocky after a scroll
  until the next key frame (still frames cost nothing, so nothing refines them). Low-latency rate
  control sharpens a still picture a little with every frame and keeps frame sizes near the target,
  so a big frame doesn't hold up the ones behind it. Same scroll test: ~51 dB once it settles, against
  ~43 dB. The iPhone decodes HEVC with its own VideoToolbox decoder (`HEVCVideoDecoder`), and H.264
  with WebRTC's.
* **Sharpening after motion.** Capture stops when the screen stops changing, so after any change that
  encoded larger than 3 KB the host re-sends the last frame at 60 fps for 1.5 s for the encoder to
  refine. Smaller changes (a blinking caret, a clock) don't trigger it, so an idle screen stays nearly
  free. The encoder tells a re-send from a new picture by a serial the host stamps on each captured
  buffer, not by the buffer's address: ScreenCaptureKit reuses buffers, so a new picture can arrive in
  a buffer that last held an old one.
* WebRTC's congestion control (GCC) sets the bitrate. In Sharp and Balanced, WebRTC's own frame-rate
  and resolution adaptation is off (`maintainFramerateAndResolution`): the host already decides the
  size, and WebRTC's adaptation would cut the frame rate to ~30 fps for seconds while its bandwidth
  estimate ramps up. Smooth keeps the frame rate; Data Saver caps at ½ resolution, 30 fps, 1.5 Mbit/s.
* The full screen is always streamed, so **pan and zoom on the iPhone are purely local GPU transforms**:
  instant at 60/120 Hz, with no network round trip. Only the stream size follows a few hundred
  milliseconds later.

### Latency strategy

* Cursor is **rendered locally on the iPhone** from the Mac's cursor image; in trackpad mode its position
  is predicted locally, so pointer motion has zero network latency.
* Pointer positions use an unreliable/unordered channel (latest wins, never stuck behind a retransmit),
  with sequence numbers so stale moves are discarded; clicks/keys use the reliable channel.
* Pointer moves and scroll deltas go out the moment the touch arrives (at most 240 per second) instead
  of waiting for the next display refresh.
* Scroll momentum is generated on the Mac (immune to network jitter).
* WebRTC runs with zero playout delay (no smoothing jitter buffer). Decoded frames are drawn on a
  dedicated render thread driven by `CAMetalDisplayLink`, off UIKit's main thread.
* **Late latching.** Each display link callback hands out the drawable for one refresh slot, which
  reaches the glass two refreshes later (33 ms at 60 Hz, measured). Drawing at the callback makes a
  frame that lands just after it wait for the next callback and so the next slot. The renderer holds
  each drawable until shortly before its deadline instead, and draws a video frame into it the moment
  it's decoded. A frame that misses its slot because of jitter is shown a refresh late rather than
  dropped. If that keeps happening for half a second, the stream's phase has settled just after the
  callbacks, and one frame is dropped so every later frame makes its own slot again. Measured on an
  iPhone 15 Plus with a full-size 3024×1964 stream: decoded→glass fell from ~40 ms to ~29 ms, or
  ~32 ms with 5–6 ms of arrival jitter. No frames were drawn too late for their slot, and no extra
  frames were dropped. (`-demo -demoConnect -renderBench <jitterMs>` reproduces this without a Mac.)
* Measured per stage (WebRTC stats deltas, logged every 2 s as `perf` lines on both ends): capture,
  encode, pacer, network round trip, assembly, jitter buffer, decode, decoded→glass. The host line also
  carries the encoder's own numbers, which WebRTC's stats can't see: frames VideoToolbox's rate
  control skipped (`vtdrop`), the frame rate it budgets for (`encfps`) against the one WebRTC measured
  (`rtcfps`), and its bitrate target (`enctarget`).
* `reach-probe bench` measures the sender pipeline end to end in one process (real `HostEngine` and
  `ClientSession` over a loopback relay, latency read from a barcode in every decoded frame), and
  `Tools/bench.sh` compares two configurations. See `Tools/README-bench.md`.

## iOS app UX

Principle: **don't mirror a 16" screen onto a 6" one — give the phone its own way to drive the Mac.**

### Screens

1. **Home** — paired Macs as cards: model glyph, name, live status ("Online", "Offline", "In use by …",
   "Checking…"), last used. Tap to connect. Context menu: details (key fingerprint), forget. Empty state
   explains the 3 steps and offers *Scan Code* / *Paste Code*. Settings gear.
2. **Pairing** — full-screen camera scanner with a soft rounded viewfinder; *Paste code* fallback (the Mac
   can copy the code; Universal Clipboard brings it over). Progress → success → straight into the session.
3. **Session** — full-bleed remote screen, immersive (no status bar, deferred system edge gestures).

### Session canvas

* Metal renderer (NV12 → RGB, BT.709) with high-quality minification when zoomed out (text stays legible).
* Zoom range: *fit* … 4× ; double-tap with **two fingers** toggles fit ⇄ 1:1 around the touch point.
* **Zoom to window**: from the window list, or two-finger long-press on a window → the viewport animates
  to frame that window (window frames come from the Mac).
* A minimap appears briefly while panning/zooming when zoomed in, showing where you are.
* When the keyboard is up, the viewport shrinks to the area above it and keeps the cursor visible.

### Input modes (toggle in the dock; remembered)

| Gesture                     | **Trackpad** mode (default)              | **Touch** mode                          |
|-----------------------------|------------------------------------------|-----------------------------------------|
| 1-finger drag               | move cursor (accelerated, relative)      | scroll content (iOS-like, momentum)     |
| tap                         | click at cursor                          | click where tapped                      |
| double-tap                  | double-click                             | double-click                            |
| 2-finger tap                | right-click                              | right-click                             |
| long-press (then drag)      | press-and-drag (select, move windows)    | release = right-click; drag = mouse drag |
| tap, then touch-and-drag    | drag (trackpad "tap-and-a-half")         | —                                       |
| 2-finger drag               | scroll (momentum on Mac)                 | pan the zoomed view                     |
| pinch                       | zoom view (around cursor)                | zoom view (around fingers)              |
| 3-finger swipe ↑ / ↓        | Mission Control / App Exposé             | same                                    |
| 3-finger swipe ← / →        | next / previous Space                    | same                                    |

Trackpad mode: the viewport **follows the cursor** when zoomed, so you never pan manually.

### Controls

* **Dock** — a floating glass capsule: Keyboard · Mode · Shortcuts · Apps · More. Collapses to a small
  handle for an unobstructed screen.
* **Keyboard** — system keyboard (autocorrect/caps/smart punctuation off, every keystroke goes straight
  to the Mac) + glass accessory bar: esc, tab, sticky ⌃ ⌥ ⌘ ⇧ (tap = once, double-tap = lock), arrow
  cluster, fn-row toggle, forward delete. A *compose* field lets you write long text with autocorrect and
  dictation and send it in one go. Hardware keyboards pass through (HID usage → Mac key code).
* **Shortcuts** — grid of common commands (copy/paste/undo, ⌘Tab, Spotlight, Mission Control, screenshot,
  force quit, lock) and media keys (volume, play/pause, brightness).
* **Apps** — running apps with icons; tap to bring to front. Windows tab: tap to focus and zoom to it.
* **More** — display picker, quality, send clipboard to Mac, stats overlay, disconnect.
* **Status pill** — route (Local / Direct / Relayed), round-trip time, appears on connect and when quality
  drops; tap for full stats.
* Clipboard: Mac → iPhone automatically; iPhone → Mac via *Paste to Mac*.
* Haptics: click, right-click, drag start, mode switch, connect.

## Mac host UX

* Menu bar icon (filled while a session is active). Popover: status (reachable from anywhere / connecting
  / offline), active session card with route + latency + Disconnect, missing-permission prompts, *Pair
  iPhone*, paired devices (remove), settings (launch at login, keep Mac awake, relay server (TURN) —
  edited inline, applied without a restart).
* First-run onboarding window: Welcome → Screen Recording → Accessibility (live status) → Pair (QR).
* Keeps the Mac awake (idle system sleep prevented, display may sleep) and wakes the display when a
  session starts; prevents display sleep during a session.
