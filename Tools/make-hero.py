#!/usr/bin/env python3
"""Writes docs/hero.svg: the README's looping illustration.

    python3 Tools/make-hero.py                    # docs/hero.svg
    python3 Tools/make-hero.py --frame 5.5 f.svg  # a still of the loop at 5.5 s (for previews)

The story, in the app's own UI: a finger drags on the iPhone and the Mac's pointer follows; a tap
brings Terminal forward; Keyboard in Reach's dock raises the iOS keyboard (the view zooms to keep the
prompt visible, as the app does); `git push` types out on both screens and its output prints.

The Mac's desktop is drawn twice (on the Mac, and scaled on the iPhone) and the same keyframes drive
both copies, so they stay in step. It's plain SVG + CSS animation, which GitHub renders inside an
<img>: no scripts, no external fonts. With reduced motion the image is a still of the finished push.
"""

import sys
from pathlib import Path

LOOP = 12.0  # seconds

# Palette: a dark studio backdrop; the app's accent; Apple-like hardware and window chrome.
FLOOR_Y = 494                          # where the iPhone stands; the Mac stands further back
ACCENT = "#4D95FF"
INK = "#1E1E1E"      # Terminal background
TEXT = "#E6E6E6"     # Terminal text
DIM = "#9A9AA0"
PAPER = "#FFFFFF"

SANS = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif"
MONO = "ui-monospace, 'SF Mono', Menlo, Consolas, 'DejaVu Sans Mono', monospace"

# The Mac's screen, in its own units (16:10).
DW, DH = 576, 360
NX, NY, NW, NH = 34, 40, 286, 206      # Notes window
TX, TY, TW, TH = 262, 116, 300, 178    # Terminal window
REST = (156, 262)                      # pointer at rest
TAP = (442, 128)                       # Terminal's title bar
PROMPT = "alex@MacBook-Pro reach % "
TYPED = "git push"
KEY_TIMES = [5.00, 5.17, 5.31, 5.52, 5.70, 5.83, 6.02, 6.17]  # human typing (s)
RETURN_AT = 6.55
OUTPUT = [(6.85, "Enumerating objects: 5, done."), (7.10, "Writing objects: 100% (3/3), done."),
          (7.40, "To github.com:Aqu1bp/reach.git"), (7.62, "   4f2a1c9..8be03d1  main -> main")]
NEXT_PROMPT_AT = 7.85

# The iPhone's screen (landscape, Dynamic Island on the left), in its own units.
SW, SH = 380, 172
FIT = ((SW - DW * SH / DH) / 2, 0, SH / DH)  # remote screen fit to height and centred, as in the app
# Keyboard up: zoomed in on the prompt (clamped to the screen's right edge, as the app's viewport is),
# then panned as the output prints, keeping the cursor visible.
ZOOM_TYPING = (SW - DW * .75, -85.5, .75)
ZOOM_OUTPUT = (SW - DW * .75, -116.0, .75)
DOCK_X = 331.5                         # Reach's dock, a narrow pill just right of the remote screen
KB_TOP = 68                            # accessory bar's top edge when the keyboard is up

EASE = (.25, .1, .25, 1)
IOS = (.2, .8, .2, 1)                  # keyboard and viewport
LINEAR = (0, 0, 1, 1)
STEPS = ("steps",)

# MARK: - Keyframes
# name -> (timing, [(seconds, {prop: value})]). Props: "t" (x, y) translate, "s" scale,
# "o" opacity, "c" fill colour. One timing per track; motion with a shape is baked into keyframes.
TRACKS: dict = {}


def track(name, frames, timing=EASE):
    TRACKS[name] = (timing, frames)


def ease_in_out(x):
    return 4 * x ** 3 if x < .5 else 1 - (-2 * x + 2) ** 3 / 2


def travel(t0, t1, a, b, bow, n=14):
    """Pointer travel from a to b along a gentle arc, eased, as linear keyframes."""
    (ax, ay), (bx, by) = a, b
    cx, cy = (ax + bx) / 2 - (by - ay) * bow, (ay + by) / 2 + (bx - ax) * bow
    frames = []
    for i in range(n + 1):
        u = ease_in_out(i / n)
        frames.append((t0 + (t1 - t0) * i / n, {"t": ((1 - u) ** 2 * ax + 2 * (1 - u) * u * cx + u ** 2 * bx,
                                                      (1 - u) ** 2 * ay + 2 * (1 - u) * u * cy + u ** 2 * by)}))
    return frames


def blink(t0, t1, on, off, period=.53):
    frames, t, lit = [(0, {"c": off})], t0, True
    while t < t1:
        frames.append((t, {"c": on if lit else off}))
        t += period
        lit = not lit
    return frames + [(t1, {"c": off}), (LOOP, {"c": off})]


def flash(t, hold=.12):
    """A key press: lit for `hold` seconds."""
    return [(0, {"o": 0}), (t - .02, {"o": 0}), (t, {"o": 1}), (t + hold, {"o": 1}), (t + hold + .08, {"o": 0}),
            (LOOP, {"o": 0})]


def show(t_in, t_out=None, fade=.04):
    """Hidden, shown at t_in, hidden again at t_out (or at the loop's end)."""
    frames = [(0, {"o": 0}), (t_in, {"o": 0}), (t_in + fade, {"o": 1})]
    if t_out:
        frames += [(t_out, {"o": 1}), (t_out + fade, {"o": 0})]
    return frames + [(LOOP, {"o": 0 if t_out else 1})]


def hide(t_out, t_in, fade=.06):
    return [(0, {"o": 1}), (t_out, {"o": 1}), (t_out + fade, {"o": 0}), (t_in, {"o": 0}), (t_in + fade, {"o": 1}), (LOOP, {"o": 1})]


fx, fy, fs = FIT
zx, zy, zs = ZOOM_TYPING
ox, oy, os_ = ZOOM_OUTPUT
track("pointer", [(0, {"t": REST}), *travel(.8, 3.0, REST, TAP, -.22), (11.25, {"t": TAP}),
                  *travel(11.25, 11.95, TAP, REST, .1, n=6)[1:], (LOOP, {"t": REST})], LINEAR)
track("finger", show(.45, 3.3, fade=.3))
track("ripple", [(0, {"o": 0, "s": .5}), (3.18, {"o": 0, "s": .5}), (3.22, {"o": 1, "s": .6}),
                 (3.6, {"o": 0, "s": 2.2}), (LOOP, {"o": 0, "s": 2.2})], (0, 0, .58, 1))
track("finger2", show(3.75, 4.3, fade=.2))
track("ripple2", [(0, {"o": 0, "s": .5}), (4.12, {"o": 0, "s": .5}), (4.16, {"o": 1, "s": .6}),
                  (4.5, {"o": 0, "s": 2.2}), (LOOP, {"o": 0, "s": 2.2})], (0, 0, .58, 1))
track("front", show(3.22, 11.3, fade=.1))
track("termMenu", show(3.24, 11.45))
track("notesMenu", hide(3.24, 11.45))
track("notesActive", hide(3.22, 11.5))
track("kbActive", show(4.16, 11.0, fade=.08))
track("dock", hide(4.3, 11.25, fade=.25))  # out of the keyboard's way
track("keyboard", [(0, {"t": (0, 120)}), (4.25, {"t": (0, 120)}), (4.72, {"t": (0, 0)}), (11.0, {"t": (0, 0)}),
                   (11.4, {"t": (0, 120)}), (LOOP, {"t": (0, 120)})], IOS)
track("viewport", [(0, {"t": (fx, fy), "s": fs}), (4.25, {"t": (fx, fy), "s": fs}), (4.8, {"t": (zx, zy), "s": zs}),
                   (6.8, {"t": (zx, zy), "s": zs}), (7.9, {"t": (ox, oy), "s": os_}), (11.0, {"t": (ox, oy), "s": os_}),
                   (11.5, {"t": (fx, fy), "s": fs}), (LOOP, {"t": (fx, fy), "s": fs})], IOS)
for i, at in enumerate(KEY_TIMES):
    track(f"ch{i}", [(0, {"c": INK}), (at, {"c": INK}), (at + .03, {"c": TEXT}), (LOOP, {"c": TEXT})])
    track(f"key{i}", flash(at))
track("keyReturn", flash(RETURN_AT, hold=.14))
for i, (at, _) in enumerate(OUTPUT):
    track(f"out{i}", show(at))
track("nextPrompt", show(NEXT_PROMPT_AT))
track("caret", blink(NEXT_PROMPT_AT, 11.3, TEXT, INK), STEPS)

# Reduced motion: the finished push, keyboard down, nothing mid-gesture.
STILL_AT = 10.0
STILL_OVERRIDES = {"keyboard": {"t": (0, 120)}, "viewport": {"t": (fx, fy), "s": fs}, "kbActive": {"o": 0},
                   "caret": {"c": TEXT}}

FRAME_AT: float | None = None  # --frame: emit a still at this time instead of animating


# MARK: - Animation plumbing


def bezier(p, x):
    x1, y1, x2, y2 = p
    lo, hi = 0.0, 1.0
    for _ in range(40):
        t = (lo + hi) / 2
        bx = 3 * (1 - t) ** 2 * t * x1 + 3 * (1 - t) * t ** 2 * x2 + t ** 3
        lo, hi = (t, hi) if bx < x else (lo, t)
    t = (lo + hi) / 2
    return 3 * (1 - t) ** 2 * t * y1 + 3 * (1 - t) * t ** 2 * y2 + t ** 3


def mix(a, b, k):
    if isinstance(a, tuple):
        return tuple(i + (j - i) * k for i, j in zip(a, b))
    if isinstance(a, str):
        ca, cb = ([int(c[i:i + 2], 16) for i in (1, 3, 5)] for c in (a, b))
        return "#" + "".join(f"{round(i + (j - i) * k):02X}" for i, j in zip(ca, cb))
    return a + (b - a) * k


def value_at(name, seconds):
    timing, frames = TRACKS[name]
    s = seconds % LOOP
    for (t0, v0), (t1, v1) in zip(frames, frames[1:]):
        if t0 <= s <= t1:
            x = 0 if t1 == t0 else (s - t0) / (t1 - t0)
            k = (1.0 if x >= 1 else 0.0) if timing is STEPS else bezier(timing, x)
            return {key: mix(v0[key], v1[key], k) for key in v0}
    return frames[-1][1]


def transform(v, css):
    parts = []
    if "t" in v:
        x, y = v["t"]
        parts.append(f"translate({x:.2f}px, {y:.2f}px)" if css else f"translate({x:.2f} {y:.2f})")
    if "s" in v:
        parts.append(f"scale({v['s']:.4f})")
    return " ".join(parts)


def decls(v):
    out = [f"transform: {t}"] if (t := transform(v, css=True)) else []
    if "o" in v:
        out.append(f"opacity: {v['o']:.3f}")
    if "c" in v:
        out.append(f"fill: {v['c']}")
    return "; ".join(out)


def anim(name):
    """An animated element's attributes: its class, or (for a still) its values at FRAME_AT."""
    if FRAME_AT is None:
        return f'class="{name}"'
    v = value_at(name, FRAME_AT)
    attrs = [f'transform="{t}"'] if (t := transform(v, css=False)) else []
    if "o" in v:
        attrs.append(f'opacity="{v["o"]:.3f}"')
    if "c" in v:
        attrs.append(f'fill="{v["c"]}"')
    return " ".join(attrs)


def css():
    if FRAME_AT is not None:
        return ""
    still, animated, keyframes = [], [], []
    for name, (timing, frames) in TRACKS.items():
        still.append(f"    .{name} {{ {decls(STILL_OVERRIDES.get(name) or value_at(name, STILL_AT))}; }}")
        fn = "steps(1, end)" if timing is STEPS else "cubic-bezier({:g}, {:g}, {:g}, {:g})".format(*timing)
        animated.append(f"      .{name} {{ animation: {name} {LOOP:g}s {fn} infinite; }}")
        steps = "\n".join(f"      {t / LOOP * 100:.3f}% {{ {decls(v)}; }}" for t, v in frames)
        keyframes.append(f"    @keyframes {name} {{\n{steps}\n    }}")
    return ("  <style>\n    /* Reduced motion: a still of the finished push. */\n" + "\n".join(still)
            + "\n    @media (prefers-reduced-motion: no-preference) {\n" + "\n".join(animated) + "\n    }\n"
            + "\n".join(keyframes) + "\n  </style>")


# MARK: - Drawing helpers


def text(x, y, s, *, size, fill, weight=400, mono=False, anchor="start"):
    return (f'<text x="{x:g}" y="{y:g}" font-family="{MONO if mono else SANS}" font-size="{size:g}" '
            f'font-weight="{weight}" fill="{fill}" text-anchor="{anchor}" xml:space="preserve">{s}</text>')


def lights(x, y, active=True):
    """Traffic lights. `active`: True, False (grey, an inactive window), or a track name to animate."""
    def row(colors):
        return "".join(f'<circle cx="{x + i * 11}" cy="{y}" r="3.6" fill="{c}"/>' for i, c in enumerate(colors))
    color, grey = row(["#FF5F57", "#FEBC2E", "#28C840"]), row(["#5F5F63"] * 3)
    if active is True:
        return color
    if active is False:
        return grey
    return grey + f'<g {anim(active)}>{color}</g>'


def window_frame(x, y, w, h, body, bar, bar_h=22):
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="#000" filter="url(#win)"/>'
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{body}"/>'
            f'<path d="M{x} {y + bar_h}v-{bar_h - 10}a10 10 0 0 1 10-10h{w - 20}a10 10 0 0 1 10 10v{bar_h - 10}z" fill="{bar}"/>'
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="none" stroke="#000" stroke-opacity=".18"/>')


def icon(x, y, kind):
    """A generic Dock icon (not Apple's artwork), 24 x 24."""
    g = (f'<rect x="{x}" y="{y + 1.2}" width="24" height="24" rx="6" fill="#000" fill-opacity=".22"/>'
         f'<rect x="{x}" y="{y}" width="24" height="24" rx="6" fill="url(#i-{kind})"/>')
    cx, cy = x + 12, y + 12
    if kind == "files":
        g += f'<path d="M{x + 5} {y + 8}h5l2 2h7v8H{x + 5}z" fill="#fff" fill-opacity=".92"/>'
    elif kind == "web":
        g += (f'<circle cx="{cx}" cy="{cy}" r="7" fill="none" stroke="#fff" stroke-width="1.4"/>'
              f'<ellipse cx="{cx}" cy="{cy}" rx="3" ry="7" fill="none" stroke="#fff" stroke-width="1.1"/>'
              f'<path d="M{cx - 7} {cy}h14" stroke="#fff" stroke-width="1.1"/>')
    elif kind == "notes":
        g += (f'<path d="M{x} {y + 7}v-1a6 6 0 0 1 6-6h12a6 6 0 0 1 6 6v1z" fill="#FFD52E"/>'
              + "".join(f'<path d="M{x + 5} {y + 11 + i * 4}h14" stroke="#C9C9CE" stroke-width="1"/>' for i in range(3)))
    elif kind == "term":
        g += (f'<path d="M{x + 6} {y + 8}l4 3.5-4 3.5" fill="none" stroke="#fff" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>'
              f'<path d="M{x + 12} {y + 16}h6" stroke="#fff" stroke-width="1.6" stroke-linecap="round"/>')
    elif kind == "chat":
        g += (f'<ellipse cx="{cx}" cy="{cy - .5}" rx="7" ry="5.6" fill="#fff"/>'
              f'<path d="M{x + 7} {y + 15}l-1.5 3.6 4.4-2.2z" fill="#fff"/>')
    elif kind == "music":
        g += (f'<path d="M{x + 10} {y + 16.5}V{y + 7.5}l7-1.6v9" fill="none" stroke="#fff" stroke-width="1.5" stroke-linejoin="round"/>'
              f'<ellipse cx="{x + 8.4}" cy="{y + 16.6}" rx="2.2" ry="1.8" fill="#fff"/><ellipse cx="{x + 15.4}" cy="{y + 15}" rx="2.2" ry="1.8" fill="#fff"/>')
    elif kind == "gear":
        g += (f'<circle cx="{cx}" cy="{cy}" r="6.5" fill="none" stroke="#fff" stroke-width="3" stroke-dasharray="2.2 1.9"/>'
              f'<circle cx="{cx}" cy="{cy}" r="4.6" fill="none" stroke="#fff" stroke-width="1.4"/>')
    return (g + f'<rect x="{x}" y="{y}" width="24" height="24" rx="6" fill="url(#gloss)"/>'
            f'<rect x="{x + .3}" y="{y + .3}" width="23.4" height="23.4" rx="5.8" fill="none" stroke="#fff" stroke-opacity=".28" stroke-width=".6"/>')


ICONS = {"files": ("#6CC2FF", "#1F6FE5"), "web": ("#58D6FF", "#2463EB"), "notes": ("#FFFFFF", "#ECECEF"),
         "term": ("#3A3A3E", "#121214"), "chat": ("#6BF08A", "#18B649"), "music": ("#FF7A86", "#F22F4E"),
         "gear": ("#A9A9AF", "#66666C")}


# MARK: - The Mac's desktop (drawn on the Mac, and again on the iPhone)


def desktop(on_phone: bool) -> str:
    out = [f'<rect width="{DW}" height="{DH}" fill="url(#wall)"/>',
           '<g filter="url(#wallBlur)">'
           f'<path d="M-40 120C110 50 260 190 400 112S560 30 {DW + 40} 64V-40H-40z" fill="url(#wave3)"/>'
           f'<path d="M-40 236C110 166 230 312 372 240S546 128 {DW + 40} 160V{DH + 40}H-40z" fill="url(#wave1)"/>'
           f'<path d="M-40 300C140 240 270 352 432 292S560 236 {DW + 40} 258V{DH + 40}H-40z" fill="url(#wave2)"/>'
           '</g>']

    # Menu bar: the frontmost app's menus switch when Terminal comes forward.
    out.append(f'<rect width="{DW}" height="14" fill="#fff" fill-opacity=".2"/>')
    for name, app, menus in [("notesMenu", "Notes", "File   Edit   Format   View   Window"),
                             ("termMenu", "Terminal", "Shell   Edit   View   Window")]:
        out.append(f'<g {anim(name)}>' + text(12, 10, f'<tspan font-weight="700">{app}</tspan>   {menus}', size=7.5, fill="#fff")
                   + "</g>")
    rx = DW - 12
    out.append(text(rx, 10, "Mon Oct 26  9:41", size=7.5, fill="#fff", anchor="end"))
    bx = rx - 134  # battery (the clock, which SF Pro sets about 66 wide, then Control Center and Spotlight)
    out.append(f'<rect x="{bx}" y="4" width="14" height="7" rx="2" fill="none" stroke="#fff" stroke-opacity=".9"/>'
               f'<rect x="{bx + 1.5}" y="5.5" width="9.5" height="4" rx="1" fill="#fff"/>'
               f'<rect x="{bx + 14.6}" y="6.2" width="1.3" height="2.6" rx=".6" fill="#fff" fill-opacity=".9"/>')
    wx = bx - 13   # Wi-Fi
    out.append(f'<path d="M{wx - 5} 7a7 7 0 0 1 10 0M{wx - 3.3} 8.6a4.6 4.6 0 0 1 6.6 0" fill="none" stroke="#fff" stroke-width="1.2" stroke-linecap="round"/>'
               f'<circle cx="{wx}" cy="10.4" r="1.1" fill="#fff"/>')
    sx = rx - 106  # Spotlight
    out.append(f'<circle cx="{sx}" cy="6.8" r="3" fill="none" stroke="#fff" stroke-width="1.2"/>'
               f'<path d="M{sx + 2.2} 9l2.4 2.4" stroke="#fff" stroke-width="1.3" stroke-linecap="round"/>')
    ccx = rx - 92   # Control Center
    out.append(f'<rect x="{ccx}" y="3.4" width="9" height="3.4" rx="1.7" fill="none" stroke="#fff" stroke-width=".9"/>'
               f'<circle cx="{ccx + 6.8}" cy="5.1" r="1.1" fill="#fff"/>'
               f'<rect x="{ccx}" y="8" width="9" height="3.4" rx="1.7" fill="none" stroke="#fff" stroke-width=".9"/>'
               f'<circle cx="{ccx + 2.2}" cy="9.7" r="1.1" fill="#fff"/>')
    px = wx - 20   # Reach Host's menu bar icon, filled while a session is active
    out.append(f'<rect x="{px}" y="2.5" width="6" height="10" rx="1.6" fill="#fff"/>'
               f'<rect x="{px + 2}" y="3.6" width="2" height=".8" rx=".4" fill="#3B6FD8"/>')

    login = text(TX + 12, TY + 38, "Last login: Mon Oct 26 09:12 on ttys000", size=9.5, fill=DIM, mono=True)
    title = "reach — -zsh — 80×24"

    # Terminal, behind and inactive
    out.append(f'<g>{window_frame(TX, TY, TW, TH, INK, "#323234")}{lights(TX + 13, TY + 11, False)}'
               + text(TX + TW / 2, TY + 14.5, title, size=7.5, fill="#86868B", anchor="middle", weight=600)
               + login + text(TX + 12, TY + 52, PROMPT.rstrip(), size=9.5, fill=TEXT, mono=True) + "</g>")

    # Notes, in front at first
    n = [f'<g>{window_frame(NX, NY, NW, NH, PAPER, "#F2F2F4", 24)}',
         f'<path d="M{NX} {NY + 24}h86v{NH - 24}h-76a10 10 0 0 1-10-10z" fill="#EDEDF0"/>',
         lights(NX + 13, NY + 12, "notesActive")]
    for i, (head, sub) in enumerate([("Lisbon trip", "Thursday evening…"), ("Groceries", "Oat milk, lemons"),
                                     ("Reach ideas", "Pinch to zoom")]):
        iy = NY + 32 + i * 30
        if i == 0:
            n.append(f'<rect x="{NX + 6}" y="{iy}" width="74" height="26" rx="5" fill="#FFD52E" fill-opacity=".55"/>')
        n.append(text(NX + 12, iy + 11, head, size=7, fill="#1D1D1F", weight=600))
        n.append(text(NX + 12, iy + 21, sub, size=6, fill="#6E6E73"))
    cx0 = NX + 100
    n.append(text(cx0, NY + 46, "Lisbon trip", size=12, fill="#1D1D1F", weight=700))
    body = ["Thursday evening train, back Sunday.", "", "• Book the 18:40 from Santa Apolónia",
            "• Pastéis de nata in Belém", "• Sunset at Miradouro da Graça", "• Tram 28 early, before the crowds",
            "", "Ask Sam about the tile museum."]
    n += [text(cx0, NY + 66 + i * 13, line, size=7.2, fill="#3A3A3C") for i, line in enumerate(body) if line]
    out.append("".join(n) + "</g>")

    # Terminal, in front and active once tapped: the typing and the push.
    keys = "".join(f'<tspan {anim(f"ch{i}")}>{c}</tspan>' for i, c in enumerate(TYPED))
    f = [f'<g {anim("front")}>{window_frame(TX, TY, TW, TH, INK, "#323234")}{lights(TX + 13, TY + 11)}',
         text(TX + TW / 2, TY + 14.5, title, size=7.5, fill="#C7C7CC", anchor="middle", weight=600),
         login, text(TX + 12, TY + 52, PROMPT + keys, size=9.5, fill=TEXT, mono=True)]
    f += [f'<g {anim(f"out{i}")}>' + text(TX + 12, TY + 66 + i * 14, line, size=9.5, fill=DIM, mono=True) + "</g>"
          for i, (_, line) in enumerate(OUTPUT)]
    f.append(f'<g {anim("nextPrompt")}>'
             + text(TX + 12, TY + 66 + len(OUTPUT) * 14, PROMPT + f'<tspan {anim("caret")}>█</tspan>', size=9.5, fill=TEXT, mono=True)
             + "</g></g>")
    out.append("".join(f))

    # Dock
    kinds = list(ICONS)
    dw = len(kinds) * 30 + 8
    dx, dy = DW / 2 - dw / 2, DH - 40
    out.append(f'<rect x="{dx}" y="{dy}" width="{dw}" height="34" rx="11" fill="#fff" fill-opacity=".22" stroke="#fff" stroke-opacity=".38" stroke-width=".6"/>'
               f'<path d="M{dx + 11} {dy + .6}h{dw - 22}" stroke="#fff" stroke-opacity=".55" stroke-width=".6"/>')
    for i, k in enumerate(kinds):
        ix = dx + 7 + i * 30
        out.append(icon(ix, dy + 4, k))
        if k in ("files", "notes", "term"):
            out.append(f'<circle cx="{ix + 12}" cy="{dy + 31.5}" r="1.1" fill="#fff" fill-opacity=".85"/>')

    # Pointer (and, on the iPhone, the finger driving it)
    finger = (f'<g {anim("finger")}><circle r="20" fill="#000" fill-opacity=".25" filter="url(#touch)"/>'
              f'<circle r="20" fill="#fff" fill-opacity=".55"/>'
              f'<circle r="20" fill="none" stroke="#fff" stroke-width="2.5"/></g>'
              f'<circle r="20" fill="none" stroke="#fff" stroke-width="3" {anim("ripple")}/>') if on_phone else ""
    out.append(f'<g {anim("pointer")}>{finger}<g transform="scale(.82)" filter="url(#cursor)">'
               '<path d="M0 0V17l4.3-4.1 3.1 7.2 3.2-1.4-3.1-7H13.6Z" fill="#000" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></g></g>')
    return "\n".join(out)


# MARK: - The iPhone's screen: the remote desktop, Reach's dock, and the keyboard


def phone_screen() -> str:
    out = [f'<rect width="{SW}" height="{SH}" fill="#000"/>', f'<g {anim("viewport")}><g clip-path="url(#desk)">{desktop(on_phone=True)}</g></g>']

    # Reach's dock, measured from the app: a narrow glass pill holding Keyboard, Mode, Shortcuts,
    # Apps and More, then a divider and the chevron that tucks it away.
    cx, top, w, h = DOCK_X + 11.25, 23.5, 22.5, 117
    ys = [35, 54, 73, 92.5, 112]
    stroke = 'stroke="#fff" stroke-width=".85" stroke-linecap="round" stroke-linejoin="round"'
    line = f'fill="none" {stroke}'
    out.append(f'<g {anim("dock")}>')
    out.append(f'<rect x="{DOCK_X}" y="{top}" width="{w}" height="{h}" rx="{w / 2}" fill="#fff" fill-opacity=".1" stroke="#fff" stroke-opacity=".16" stroke-width=".5"/>')
    out.append(f'<g {anim("kbActive")}><circle cx="{cx}" cy="{ys[0]}" r="8" fill="{ACCENT}" fill-opacity=".25"/></g>')

    def keyboard_glyph(color):
        y = ys[0]
        keys = "".join(f'<rect x="{cx - 3.9 + i * 1.75}" y="{y - 2 + r * 1.5}" width=".9" height=".8" fill="{color}"/>'
                       for r in (0, 1) for i in range(5))
        return (f'<rect x="{cx - 5}" y="{y - 3.2}" width="10" height="6.4" rx="1.2" fill="none" stroke="{color}" stroke-width=".85"/>'
                + keys + f'<rect x="{cx - 2.6}" y="{y + 1.3}" width="5.2" height=".8" fill="{color}"/>')
    out.append(keyboard_glyph("#fff") + f'<g {anim("kbActive")}>{keyboard_glyph(ACCENT)}</g>')
    # Mode: a hand pointing at a screen
    y = ys[1]
    out.append(f'<path d="M{cx - 1} {y + 2.6}H{cx - 4.4}a1.1 1.1 0 0 1-1.1-1.1V{y - 3.1}a1.1 1.1 0 0 1 1.1-1.1h6.6'
               f'a1.1 1.1 0 0 1 1.1 1.1V{y - 1.4}" {line}/>'
               f'<path d="M{cx - .3} {y + 4.6}l-1.4-2.4a.8.8 0 0 1 1.3-.9l.7.9V{y - 1.6}a.8.8 0 0 1 1.6 0V{y + .6}'
               f'l2.9.5a1.2 1.2 0 0 1 1 1.4l-.5 2.6" fill="#1A1A1A" {stroke}/>')
    out.append(text(cx, ys[2] + 3.6, "⌘", size=10.5, fill="#fff", anchor="middle"))  # Shortcuts
    out.append("".join(f'<rect x="{cx - 3.7 + i * 4}" y="{ys[3] - 3.7 + j * 4}" width="3.4" height="3.4" rx=".9" {line}/>'
                       for i in (0, 1) for j in (0, 1)))  # Apps
    out.append("".join(f'<circle cx="{cx - 3.4 + i * 3.4}" cy="{ys[4]}" r=".95" fill="#fff"/>' for i in range(3)))  # More
    out.append(f'<path d="M{cx - 4.5} 122.5h9" stroke="#fff" stroke-opacity=".3" stroke-width=".5"/>'
               f'<path d="M{cx - 1} 128.6l2.2 2.5-2.2 2.5" {line}/>')  # Hide
    out.append("</g>")

    # The finger tapping Keyboard
    out.append(f'<g transform="translate({cx} {ys[0]})"><g {anim("finger2")}><circle r="8" fill="#fff" fill-opacity=".55"/>'
               f'<circle r="8" fill="none" stroke="#fff" stroke-width="1.1"/></g>'
               f'<circle r="7.5" fill="none" stroke="#fff" stroke-width="1.2" {anim("ripple2")}/></g>')

    # Keyboard: Reach's accessory bar on top of the (dark) iOS keyboard.
    kb = [f'<g {anim("keyboard")}>', f'<rect y="{KB_TOP}" width="{SW}" height="{SH - KB_TOP}" fill="#2B2B2E"/>',
          f'<rect y="{KB_TOP}" width="{SW}" height="17" fill="#38383B"/>']
    ax = 34
    # As in the app: esc, tab, sticky ⌃ ⌥ ⌘ ⇧, arrows (fn, forward delete and compose scroll off-screen).
    for i, label in enumerate(["esc", "⇥", "⌃", "⌥", "⌘", "⇧", "◀", "▲", "▼", "▶"]):
        w = 22 if i < 6 else 16
        kb.append(f'<rect x="{ax}" y="{KB_TOP + 3}" width="{w}" height="11" rx="3" fill="#5A5A5E"/>'
                  + text(ax + w / 2, KB_TOP + 11.2, label, size=6.4, fill="#fff", anchor="middle"))
        ax += w + (8 if i == 5 else 3)
    kb.append(f'<path d="M{SW - 60} {KB_TOP + 6}h10v6h-10z" fill="none" stroke="#fff" stroke-width=".9"/>'
              f'<path d="M{SW - 57} {KB_TOP + 13.5}l2 1.6 2-1.6" fill="none" stroke="#fff" stroke-width=".9"/>')
    key_w, gap, key_h, left, width = 29, 3, 17, 30, 317
    top0 = KB_TOP + 21

    def keycap(x, y, w, label, fill="#68686C", size=8.5, lit=None):
        s = f'<rect x="{x}" y="{y}" width="{w}" height="{key_h}" rx="4" fill="{fill}"/>'
        if lit:
            s += f'<g {anim(lit)}><rect x="{x}" y="{y}" width="{w}" height="{key_h}" rx="4" fill="#B4B4BA"/></g>'
        return s + text(x + w / 2, y + key_h / 2 + size * .35, label, size=size, fill="#fff", anchor="middle")

    typed = {c: f"key{i}" for i, c in enumerate(TYPED)}
    for r, row in enumerate(["qwertyuiop", "asdfghjkl", "zxcvbnm"]):
        y = top0 + r * (key_h + 4)
        x0 = left + (width - (len(row) * key_w + (len(row) - 1) * gap)) / 2
        if r == 2:
            kb.append(keycap(left, y, 40, "⇧", fill="#46464A", size=9))
            kb.append(keycap(left + width - 40, y, 40, "⌫", fill="#46464A", size=9))
        kb += [keycap(x0 + i * (key_w + gap), y, key_w, ch, lit=typed.get(ch)) for i, ch in enumerate(row)]
    y = top0 + 3 * (key_h + 4)
    kb.append(keycap(left, y, 40, "123", fill="#46464A", size=7.5))
    kb.append(keycap(left + 43, y, 29, "☺", fill="#46464A", size=8))
    kb.append(keycap(left + 75, y, 167, "space", size=7.5, lit=typed[" "]))
    kb.append(keycap(left + 245, y, 72, "return", fill="#46464A", size=7.5, lit="keyReturn"))
    out += kb + ["</g>"]
    return "\n".join(out)


# MARK: - Scene


def svg() -> str:
    mac_x, mac_y = 100, 52             # the Mac's screen on the canvas
    phone_x, phone_y, phone_w, phone_h = 536, 300, 400, 192
    screen_x, screen_y = phone_x + 10, phone_y + 10
    button = "#46474B"
    icons = "".join(f'<linearGradient id="i-{k}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{a}"/>'
                    f'<stop offset="1" stop-color="{b}"/></linearGradient>' for k, (a, b) in ICONS.items())
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 960 540" width="960" height="540" role="img"
  aria-label="An iPhone in front of a Mac. A finger drags on the iPhone and the Mac's pointer follows; a tap brings Terminal forward; the iPhone's keyboard comes up and git push types out on both screens.">
{css()}
  <defs>
    <radialGradient id="studio" cx=".5" cy=".28" r=".85"><stop offset="0" stop-color="#2B3550"/><stop offset=".55" stop-color="#121725"/><stop offset="1" stop-color="#06080D"/></radialGradient>
    <linearGradient id="floor" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0E121C"/><stop offset="1" stop-color="#05070B"/></linearGradient>
    <linearGradient id="fade" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
    <mask id="reflect" maskContentUnits="userSpaceOnUse"><rect x="0" y="{mac_y + DH + 26}" width="960" height="70" fill="url(#fade)"/></mask>
    <mask id="reflectPhone" maskContentUnits="userSpaceOnUse"><rect x="0" y="{FLOOR_Y}" width="960" height="46" fill="url(#fade)"/></mask>
    <linearGradient id="wall" x1="0" y1="0" x2=".4" y2="1"><stop offset="0" stop-color="#0E1A5E"/><stop offset="1" stop-color="#1D3FA8"/></linearGradient>
    <linearGradient id="wave1" x1="0" y1="0" x2="1" y2=".3"><stop offset="0" stop-color="#3C78FF"/><stop offset=".6" stop-color="#5B5CF6"/><stop offset="1" stop-color="#8F5BFF"/></linearGradient>
    <linearGradient id="wave2" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#2CC6FF"/><stop offset=".5" stop-color="#3A8BFF"/><stop offset="1" stop-color="#6E6BFF"/></linearGradient>
    <linearGradient id="wave3" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#5B4BD8" stop-opacity=".9"/><stop offset="1" stop-color="#2B5BE0" stop-opacity=".7"/></linearGradient>
    <filter id="wallBlur" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="9"/></filter>
    <linearGradient id="gloss" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".32"/><stop offset=".45" stop-color="#fff" stop-opacity="0"/></linearGradient>
    <linearGradient id="edge" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#D5DCE6"/><stop offset=".5" stop-color="#8E98AA"/><stop offset="1" stop-color="#5E687C"/></linearGradient>
    <linearGradient id="hinge" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2D3038"/><stop offset="1" stop-color="#0D0E11"/></linearGradient>
    <linearGradient id="base" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F3F5F8"/><stop offset=".3" stop-color="#CFD5DF"/><stop offset=".75" stop-color="#9AA3B2"/><stop offset="1" stop-color="#6B7486"/></linearGradient>
    <linearGradient id="titanium" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#8A8B90"/><stop offset=".18" stop-color="#4A4B50"/><stop offset=".8" stop-color="#2B2C30"/><stop offset="1" stop-color="#55565B"/></linearGradient>
    <linearGradient id="glare" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".09"/><stop offset=".38" stop-color="#fff" stop-opacity=".025"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient>
    <radialGradient id="spill" cx=".5" cy=".5" r=".5"><stop offset="0" stop-color="#3D6BFF" stop-opacity=".35"/><stop offset="1" stop-color="#3D6BFF" stop-opacity="0"/></radialGradient>
    {icons}
    <clipPath id="desk"><rect width="{DW}" height="{DH}"/></clipPath>
    <clipPath id="macScreen"><rect x="{mac_x}" y="{mac_y}" width="{DW}" height="{DH}" rx="9"/></clipPath>
    <clipPath id="phoneScreen"><rect x="{screen_x}" y="{screen_y}" width="{SW}" height="{SH}" rx="34"/></clipPath>
    <filter id="win" x="-20%" y="-20%" width="140%" height="150%"><feGaussianBlur stdDeviation="7"/><feOffset dy="6"/><feComponentTransfer><feFuncA type="linear" slope=".35"/></feComponentTransfer></filter>
    <filter id="cursor" x="-50%" y="-50%" width="200%" height="200%"><feDropShadow dx="0" dy="1" stdDeviation="1" flood-color="#000" flood-opacity=".4"/></filter>
    <filter id="lift" x="-20%" y="-30%" width="140%" height="180%"><feDropShadow dx="0" dy="18" stdDeviation="18" flood-color="#000" flood-opacity=".6"/></filter>
    <filter id="touch" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="3"/></filter>
    <filter id="soft" x="-20%" y="-200%" width="140%" height="500%"><feGaussianBlur stdDeviation="9"/></filter>
  </defs>

  <!-- Studio: seamless backdrop, floor, the screen's light on the floor -->
  <rect width="960" height="540" rx="24" fill="url(#studio)"/>
  <path d="M0 {mac_y + DH + 26}H960V516a24 24 0 0 1-24 24H24a24 24 0 0 1-24-24z" fill="url(#floor)" fill-opacity=".85"/>
  <ellipse cx="{mac_x + DW / 2}" cy="{mac_y + DH + 40}" rx="360" ry="34" fill="url(#spill)"/>

  <!-- MacBook Pro -->
  <g mask="url(#reflect)" transform="translate(0 {2 * (mac_y + DH + 26)}) scale(1 -1)">
    <path d="M{mac_x - 50} {mac_y + DH + 17}h{DW + 100}v4.5c0 4-3.5 7-8 7H{mac_x - 42}c-4.5 0-8-3-8-7z" fill="url(#base)"/>
    <rect x="{mac_x - 13}" y="{mac_y + DH - 60}" width="{DW + 26}" height="77" fill="#0B0C0F"/>
    <rect x="{mac_x}" y="{mac_y + DH - 60}" width="{DW}" height="60" fill="#2F55C8"/>
  </g>
  <ellipse cx="{mac_x + DW / 2}" cy="{mac_y + DH + 27}" rx="340" ry="5" fill="#000" fill-opacity=".7" filter="url(#soft)"/>
  <rect x="{mac_x - 13}" y="{mac_y - 13}" width="{DW + 26}" height="{DH + 30}" rx="20" fill="#0B0C0F" stroke="url(#edge)" stroke-width="1.8"/>
  <rect x="{mac_x - 11.5}" y="{mac_y - 11.5}" width="{DW + 23}" height="{DH + 27}" rx="18.5" fill="none" stroke="#3A3E47" stroke-width=".7"/>
  <g clip-path="url(#macScreen)"><g transform="translate({mac_x} {mac_y})">{desktop(on_phone=False)}</g>
    <rect x="{mac_x}" y="{mac_y}" width="{DW}" height="{DH}" fill="url(#glare)"/></g>
  <path d="M{mac_x + DW / 2 - 34} {mac_y}h68v6a6 6 0 0 1-6 6h-56a6 6 0 0 1-6-6z" fill="#0B0C0F"/>
  <circle cx="{mac_x + DW / 2}" cy="{mac_y + 5.5}" r="1.9" fill="#161A24"/><circle cx="{mac_x + DW / 2 - .5}" cy="{mac_y + 5}" r=".6" fill="#3A4560"/>
  <rect x="{mac_x - 12}" y="{mac_y + DH + 10}" width="{DW + 24}" height="7" rx="1.5" fill="url(#hinge)"/>
  <path d="M{mac_x - 50} {mac_y + DH + 17}h{DW + 100}v4.5c0 4-3.5 7-8 7H{mac_x - 42}c-4.5 0-8-3-8-7z" fill="url(#base)"/>
  <path d="M{mac_x - 49} {mac_y + DH + 17.6}h{DW + 98}" stroke="#fff" stroke-opacity=".8" stroke-width=".7"/>
  <path d="M{mac_x + DW / 2 - 52} {mac_y + DH + 17}h104v1.8a3 3 0 0 1-3 3h-98a3 3 0 0 1-3-3z" fill="#7E8798"/>

  <!-- iPhone 16 Pro, landscape, standing in front -->
  <g mask="url(#reflectPhone)" transform="translate(0 {2 * FLOOR_Y}) scale(1 -1)">
    <rect x="{phone_x}" y="{phone_y}" width="{phone_w}" height="{phone_h}" rx="46" fill="url(#titanium)"/>
    <rect x="{phone_x + 3}" y="{phone_y + 3}" width="{phone_w - 6}" height="{phone_h - 6}" rx="43" fill="#08090B"/>
  </g>
  <ellipse cx="{phone_x + phone_w / 2}" cy="{FLOOR_Y + 1}" rx="{phone_w / 2 - 20}" ry="4" fill="#000" fill-opacity=".8" filter="url(#soft)"/>
  <g filter="url(#lift)"><rect x="{phone_x}" y="{phone_y}" width="{phone_w}" height="{phone_h}" rx="46" fill="url(#titanium)"/></g>
  <rect x="{phone_x + .6}" y="{phone_y + .6}" width="{phone_w - 1.2}" height="{phone_h - 1.2}" rx="45.4" fill="none" stroke="#B9BAC0" stroke-opacity=".55" stroke-width=".8"/>
  <rect x="{phone_x + 120}" y="{phone_y - 1.6}" width="44" height="3" rx="1.5" fill="{button}"/>
  <rect x="{phone_x + 300}" y="{phone_y - 1.4}" width="26" height="2.6" rx="1.3" fill="{button}"/>
  <rect x="{phone_x + 70}" y="{phone_y + phone_h - 1.4}" width="16" height="3" rx="1.5" fill="{button}"/>
  <rect x="{phone_x + 100}" y="{phone_y + phone_h - 1.4}" width="30" height="3" rx="1.5" fill="{button}"/>
  <rect x="{phone_x + 140}" y="{phone_y + phone_h - 1.4}" width="30" height="3" rx="1.5" fill="{button}"/>
  <rect x="{phone_x + 2.5}" y="{phone_y + 2.5}" width="{phone_w - 5}" height="{phone_h - 5}" rx="43.5" fill="#050506"/>
  <rect x="{phone_x + 3.2}" y="{phone_y + 3.2}" width="{phone_w - 6.4}" height="{phone_h - 6.4}" rx="42.8" fill="none" stroke="#1E2026" stroke-width=".8"/>
  <g clip-path="url(#phoneScreen)"><g transform="translate({screen_x} {screen_y})">{phone_screen()}</g>
    <rect x="{screen_x}" y="{screen_y}" width="{SW}" height="{SH}" fill="url(#glare)"/></g>
  <rect x="{screen_x + 7}" y="{screen_y + SH / 2 - 21}" width="12" height="42" rx="6" fill="#000"/>
</svg>
"""


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--frame":
        FRAME_AT = float(sys.argv[2])
        out = Path(sys.argv[3])
    else:
        out = Path(__file__).resolve().parent.parent / "docs" / "hero.svg"
    out.write_text(svg())
    print(f"wrote {out}")
