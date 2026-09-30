#!/usr/bin/env python3
"""
tools/render_gui.py
Draws the GUI that tests/harness/export_gui.luau dumped, the way Roblox would
lay it out, and reports what is wrong with it.

    lune run tests/harness/export_gui phone match > gui.json
    python3 tools/render_gui.py gui.json out.png [report.json]

WHY THIS EXISTS. Every layout problem this game has had on a phone reached us
as a photo from the owner: buttons in the middle of the screen, buttons too
big, a fire button under Roblox's jump button. Each one was fixed from a
description and checked by the owner again. This renders the tree the real
client modules build, at the viewport a real phone reports, with Roblox's own
chrome (top bar, thumbstick, jump button) drawn on top as guides — so a layout
can be looked at before it ships instead of after.

WHAT IT IMPLEMENTS of Roblox's layout: UDim2 position/size against the parent's
content box, AnchorPoint, UIPadding, UIScale (on objects, where it scales the
object itself, Scale part included, and its descendants' offsets; directly
under a ScreenGui it is drawn the pessimistic way, see Renderer.render),
UIListLayout, UIGridLayout, UISizeConstraint, UIAspectRatioConstraint,
AutomaticSize, ScrollingFrame canvases, ClipsDescendants, Rotation (whole
subtree, about the centre), ZIndexBehavior.Sibling draw order, DisplayOrder
across ScreenGuis, UICorner, UIStroke, UIGradient, TextScaled, TextWrapped,
TextTruncate.AtEnd, LineHeight, TextStroke. Gotham is drawn with Montserrat,
its closest open equivalent; metrics are close, not identical.

WHAT IT REPORTS, per element actually visible on screen:
  * truncated  - text that did not fit and was cut with an ellipsis
  * overflow   - text wider or taller than its box (and not truncated)
  * tiny       - text smaller than 9 px on the device
  * offscreen  - a visible element partly outside the viewport
  * chrome     - a button overlapping Roblox's top-bar buttons, thumbstick or jump button
  * spill      - text drawn outside the box of the button/panel that holds it
  * covered    - text under Roblox's jump button or thumbstick, where a thumb sits
"""

from __future__ import annotations

import json
import math
import os
import re
import sys
import urllib.request

from PIL import Image, ImageDraw, ImageFont

FONT_CACHE = os.path.expanduser("~/.cache/lasertag-fonts")
FONT_SOURCES = {
    "Montserrat.ttf": "https://raw.githubusercontent.com/google/fonts/main/ofl/montserrat/Montserrat%5Bwght%5D.ttf",
    "RobotoMono.ttf": "https://raw.githubusercontent.com/google/fonts/main/ofl/robotomono/RobotoMono%5Bwght%5D.ttf",
}
FALLBACK = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

# Roblox font -> (file, weight)
FONT_MAP = {
    "GothamBlack": ("Montserrat.ttf", 900),
    "GothamBold": ("Montserrat.ttf", 700),
    "GothamSemibold": ("Montserrat.ttf", 600),
    "GothamMedium": ("Montserrat.ttf", 500),
    "Gotham": ("Montserrat.ttf", 500),
    "RobotoMono": ("RobotoMono.ttf", 600),
    "Code": ("RobotoMono.ttf", 500),
    "Arcade": ("Montserrat.ttf", 800),
    "FredokaOne": ("Montserrat.ttf", 800),
    "LuckiestGuy": ("Montserrat.ttf", 900),
    "Bangers": ("Montserrat.ttf", 800),
}

SS = 3  # supersampling for antialiasing
# Constants.DISPLAY_ORDER.Menu: screens at or above it are modal.
MENU_DISPLAY_ORDER = 80


def ensure_fonts():
    os.makedirs(FONT_CACHE, exist_ok=True)
    for name, url in FONT_SOURCES.items():
        path = os.path.join(FONT_CACHE, name)
        if not os.path.exists(path):
            try:
                urllib.request.urlretrieve(url, path)
            except Exception as exc:  # noqa: BLE001 - fall back to DejaVu
                print(f"[render_gui] could not fetch {name}: {exc}", file=sys.stderr)


_font_cache: dict = {}
_cmap_cache: dict = {}
SYMBOL_FALLBACK = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"


def covers(path: str, ch: str) -> bool:
    """Whether the font file has a glyph for `ch`. Roblox falls back to other
    fonts for characters Gotham lacks (arrows, skulls, dingbats), so a missing
    glyph must be drawn from a fallback here too, not as a box."""
    if path not in _cmap_cache:
        try:
            from fontTools.ttLib import TTFont

            _cmap_cache[path] = set(TTFont(path).getBestCmap().keys())
        except Exception:  # noqa: BLE001 - no fontTools: assume covered
            _cmap_cache[path] = None
    cmap = _cmap_cache[path]
    return True if cmap is None else (ord(ch) in cmap or ch in " \t")


def font_path(roblox_font):
    file, _ = FONT_MAP.get(roblox_font or "", ("Montserrat.ttf", 500))
    path = os.path.join(FONT_CACHE, file)
    return path if os.path.exists(path) else FALLBACK


_fallback_fonts: dict = {}


def fallback_font(px):
    size = max(1, int(round(px)))
    if size not in _fallback_fonts:
        _fallback_fonts[size] = ImageFont.truetype(SYMBOL_FALLBACK, size)
    return _fallback_fonts[size]


def runs(line, roblox_font, px):
    """Split a line into (text, font) runs by glyph coverage."""
    primary = get_font(roblox_font, px)
    path = font_path(roblox_font)
    out = []
    for ch in line:
        f = primary if covers(path, ch) else fallback_font(px)
        if out and out[-1][1] is f:
            out[-1][0] += ch
        else:
            out.append([ch, f])
    return out


def line_length(line, roblox_font, px):
    return sum(f.getlength(t) for t, f in runs(line, roblox_font, px))


def get_font(roblox_font: str | None, px: float):
    file, weight = FONT_MAP.get(roblox_font or "", ("Montserrat.ttf", 500))
    size = max(1, int(round(px)))
    key = (file, weight, size)
    if key in _font_cache:
        return _font_cache[key]
    path = os.path.join(FONT_CACHE, file)
    try:
        font = ImageFont.truetype(path, size)
        try:
            font.set_variation_by_axes([weight])
        except Exception:  # noqa: BLE001 - static font
            pass
    except Exception:  # noqa: BLE001
        font = ImageFont.truetype(FALLBACK, size)
    _font_cache[key] = font
    return font


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------


def mod(node, cls):
    for m in node.get("modifiers") or []:
        if m.get("class") == cls:
            return m
    return None


def is_text(node):
    return node["class"] in ("TextLabel", "TextButton", "TextBox")


def strip_rich(text: str) -> str:
    return re.sub(r"<[^>]+>", "", text or "")


def text_lines(text, rfont, px, max_w, wrap):
    paragraphs = strip_rich(text).split("\n")
    if not wrap:
        return paragraphs
    lines = []
    for para in paragraphs:
        words = para.split(" ")
        cur = ""
        for w in words:
            trial = (cur + " " + w) if cur else w
            if line_length(trial, rfont, px) <= max_w or not cur:
                cur = trial
            else:
                lines.append(cur)
                cur = w
        lines.append(cur)
    return lines


def measure_text(node, px, max_w=None):
    font = get_font(node.get("font"), px)
    wrap = bool(node.get("textWrapped")) and max_w is not None
    lines = text_lines(node.get("text") or "", node.get("font"), px, max_w or 1e9, wrap)
    lh = px * (node.get("lineHeight") or 1.0)
    w = max((line_length(l, node.get("font"), px) for l in lines), default=0)
    h = lh * len(lines)
    return w, h, lines, font


def udim_px(u, total, s):
    if not u:
        return 0.0
    return u[0] * total + u[1] * s


def size_limits(sc):
    # math.huge travels through JSON as null; read it back as unbounded.
    mn = [v if v is not None else 0 for v in (sc.get("min") or [0, 0])]
    mx = [v if v is not None else 1e9 for v in (sc.get("max") or [1e9, 1e9])]
    return mn, mx


def measure(node, pw, ph, s):
    """Size this node against a parent content box of pw x ph, and lay its
    children out in its local space. Offsets are in unscaled pixels and are
    multiplied by the accumulated UIScale `s`."""
    size = node.get("size") or [0, 0, 0, 0]
    uiscale = mod(node, "UIScale")
    us = uiscale["scale"] if uiscale and uiscale.get("scale") is not None else 1.0
    w = (size[0] * pw + size[1] * s) * us
    h = (size[2] * ph + size[3] * s) * us
    s_self = s * us

    sc = mod(node, "UISizeConstraint")
    if sc:
        mn, mx = size_limits(sc)
        w = min(max(w, mn[0] * s_self), mx[0] * s_self)
        h = min(max(h, mn[1] * s_self), mx[1] * s_self)

    ar = mod(node, "UIAspectRatioConstraint")
    if ar and ar.get("ratio"):
        r = ar["ratio"]
        if ar.get("aspectType") == "ScaleWithParentSize":
            if ar.get("dominant") == "Height":
                w = h * r
            else:
                h = w / r
        else:  # FitWithinMaxSize
            if h > 0 and w / h > r:
                w = h * r
            else:
                h = w / r

    node["_s"] = s_self
    node["_w"], node["_h"] = w, h
    layout_children(node)

    auto = node.get("autoSize") or "None"
    if auto != "None":
        pad = mod(node, "UIPadding")
        pl = udim_px(pad and pad.get("left"), w, s_self)
        pr = udim_px(pad and pad.get("right"), w, s_self)
        pt = udim_px(pad and pad.get("top"), h, s_self)
        pb = udim_px(pad and pad.get("bottom"), h, s_self)
        ex, ey = natural_extent(node, pl, pt, pr, pb, s_self)
        if is_text(node) and node.get("text"):
            px = (node.get("textSize") or 14) * s_self
            tw, th, _, _ = measure_text(node, px, (w - pl - pr) if auto == "Y" else None)
            ex = max(ex, tw + pl + pr)
            ey = max(ey, th + pt + pb)
        if auto in ("X", "XY"):
            w = max(w, ex)
        if auto in ("Y", "XY"):
            h = max(h, ey)
        # Roblox applies a UISizeConstraint after AutomaticSize: the constraint
        # wins, which is how an auto-sized name is capped at a width.
        if sc:
            mn, mx = size_limits(sc)
            w = min(max(w, mn[0] * s_self), mx[0] * s_self)
            h = min(max(h, mn[1] * s_self), mx[1] * s_self)
        node["_w"], node["_h"] = w, h
        if (auto in ("X", "XY") and w != node["_w"]) or True:
            layout_children(node)  # relayout against the grown box


def natural_extent(node, pl, pt, pr, pb, s):
    """The size the node's content wants, independent of where alignment put
    it: a list is as long as its items plus the gaps between them, whatever
    side it is aligned to. Using the laid-out positions instead made a
    right-aligned list inside an auto-sized frame measure as nothing, because
    its items had been pushed to negative x in a box of width zero."""
    kids = visible_children(node)
    listl = mod(node, "UIListLayout")
    if listl and kids:
        vertical = (listl.get("fill") or "Vertical") == "Vertical"
        gap = udim_px(listl.get("padding"), 0, s)
        main = sum((c["_h"] if vertical else c["_w"]) for c in kids) + gap * max(0, len(kids) - 1)
        cross = max((c["_w"] if vertical else c["_h"]) for c in kids)
        return (cross + pl + pr, main + pt + pb) if vertical else (main + pl + pr, cross + pt + pb)
    ex, ey = 0.0, 0.0
    for c in kids:
        pos = c.get("position") or [0, 0, 0, 0]
        anc = c.get("anchor") or [0, 0]
        ex = max(ex, pl + pos[1] * s - anc[0] * c["_w"] + c["_w"] + pr)
        ey = max(ey, pt + pos[3] * s - anc[1] * c["_h"] + c["_h"] + pb)
    return ex, ey


def visible_children(node):
    return [c for c in node.get("children") or [] if c.get("visible", True) is not False]


def layout_children(node):
    w, h, s = node["_w"], node["_h"], node["_s"]
    pad = mod(node, "UIPadding")
    pl = udim_px(pad and pad.get("left"), w, s)
    pr = udim_px(pad and pad.get("right"), w, s)
    pt = udim_px(pad and pad.get("top"), h, s)
    pb = udim_px(pad and pad.get("bottom"), h, s)
    cw, ch = max(0.0, w - pl - pr), max(0.0, h - pt - pb)
    ox, oy = pl, pt

    if node["class"] == "ScrollingFrame":
        canvas = node.get("canvas") or [0, 0, 0, 0]
        cw = max(cw, canvas[0] * w + canvas[1] * s - pl - pr) if canvas[0] or canvas[1] else cw
        ch = max(ch, canvas[2] * h + canvas[3] * s - pt - pb) if canvas[2] or canvas[3] else ch

    kids = node.get("children") or []
    for c in kids:
        measure(c, cw, ch, s)

    listl = mod(node, "UIListLayout")
    grid = mod(node, "UIGridLayout")
    shown = [c for c in kids if c.get("visible", True) is not False]

    def order_key(c):
        if (listl or grid or {}).get("sort") == "Name":
            return (c.get("name") or "",)
        return (c.get("order") or 0, c.get("name") or "")

    if listl:
        shown_sorted = sorted(shown, key=order_key)
        vertical = (listl.get("fill") or "Vertical") == "Vertical"
        gap = udim_px(listl.get("padding"), ch if vertical else cw, s)
        total = sum((c["_h"] if vertical else c["_w"]) for c in shown_sorted) + gap * max(0, len(shown_sorted) - 1)
        halign = listl.get("h") or "Left"
        valign = listl.get("v") or "Top"
        if vertical:
            y = oy + {"Top": 0, "Center": (ch - total) / 2, "Bottom": ch - total}.get(valign, 0)
            for c in shown_sorted:
                x = ox + {"Left": 0, "Center": (cw - c["_w"]) / 2, "Right": cw - c["_w"]}.get(halign, 0)
                c["_x"], c["_y"] = x, y
                y += c["_h"] + gap
        else:
            x = ox + {"Left": 0, "Center": (cw - total) / 2, "Right": cw - total}.get(halign, 0)
            for c in shown_sorted:
                y = oy + {"Top": 0, "Center": (ch - c["_h"]) / 2, "Bottom": ch - c["_h"]}.get(valign, 0)
                c["_x"], c["_y"] = x, y
                x += c["_w"] + gap
    elif grid:
        shown_sorted = sorted(shown, key=order_key)
        cell = grid.get("cellSize") or [0, 100, 0, 100]
        cpad = grid.get("cellPadding") or [0, 5, 0, 5]
        cwid = cell[0] * cw + cell[1] * s
        chei = cell[2] * ch + cell[3] * s
        gx = cpad[0] * cw + cpad[1] * s
        gy = cpad[2] * ch + cpad[3] * s
        horizontal = (grid.get("fill") or "Horizontal") == "Horizontal"
        per = max(1, int((cw + gx) // (cwid + gx))) if horizontal else max(1, int((ch + gy) // (chei + gy)))
        n = len(shown_sorted)
        cols = min(n, per) if horizontal else max(1, math.ceil(n / per))
        rows = max(1, math.ceil(n / per)) if horizontal else min(n, per)
        bw = cols * cwid + max(0, cols - 1) * gx
        bh = rows * chei + max(0, rows - 1) * gy
        x0 = ox + {"Left": 0, "Center": (cw - bw) / 2, "Right": cw - bw}.get(grid.get("h") or "Left", 0)
        y0 = oy + {"Top": 0, "Center": (ch - bh) / 2, "Bottom": ch - bh}.get(grid.get("v") or "Top", 0)
        for i, c in enumerate(shown_sorted):
            r, k = (i // per, i % per) if horizontal else (i % per, i // per)
            c["_w"], c["_h"] = cwid, chei
            layout_children(c)
            c["_x"], c["_y"] = x0 + k * (cwid + gx), y0 + r * (chei + gy)
    for c in kids:
        if c in shown and (listl or grid):
            continue
        pos = c.get("position") or [0, 0, 0, 0]
        anc = c.get("anchor") or [0, 0]
        c["_x"] = ox + pos[0] * cw + pos[1] * s - anc[0] * c["_w"]
        c["_y"] = oy + pos[2] * ch + pos[3] * s - anc[1] * c["_h"]


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------


def rot_matrix(deg, cx, cy):
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    # translate(-c) rotate translate(c)
    return (c, -s, cx - c * cx + s * cy, s, c, cy - s * cx - c * cy)


def compose(m1, m2):
    """m1 after m2."""
    a, b, c, d, e, f = m1
    g, h, i, j, k, l = m2
    return (a * g + b * j, a * h + b * k, a * i + b * l + c, d * g + e * j, d * h + e * k, d * i + e * l + f)


IDENT = (1, 0, 0, 0, 1, 0)


def apply(m, x, y):
    return (m[0] * x + m[1] * y + m[2], m[3] * x + m[4] * y + m[5])


def rounded_rect_points(x, y, w, h, r, steps=6):
    r = max(0.0, min(r, w / 2, h / 2))
    if r <= 0.01:
        return [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]
    pts = []
    for cx, cy, a0 in ((x + w - r, y + r, -90), (x + w - r, y + h - r, 0), (x + r, y + h - r, 90), (x + r, y + r, 180)):
        for i in range(steps + 1):
            a = math.radians(a0 + 90 * i / steps)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def lerp_color(stops, t):
    if not stops:
        return (255, 255, 255)
    if t <= stops[0][0]:
        return tuple(stops[0][1])
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        if t0 <= t <= t1:
            k = 0 if t1 == t0 else (t - t0) / (t1 - t0)
            return tuple(c0[i] + (c1[i] - c0[i]) * k for i in range(3))
    return tuple(stops[-1][1])


def lerp_num(stops, t):
    if not stops:
        return 0.0
    if t <= stops[0][0]:
        return stops[0][1]
    for (t0, v0), (t1, v1) in zip(stops, stops[1:]):
        if t0 <= t <= t1:
            k = 0 if t1 == t0 else (t - t0) / (t1 - t0)
            return v0 + (v1 - v0) * k
    return stops[-1][1]


class Renderer:
    def __init__(self, data):
        self.data = data
        self.vw, self.vh = data["viewport"]
        self.canvas = Image.new("RGBA", (int(self.vw * SS), int(self.vh * SS)), (0, 0, 0, 0))
        self.issues = []

    # A polygon filled with a colour (or gradient), alpha-composited through
    # the current clip rectangle.
    def fill_poly(self, pts, color, alpha, clip, gradient=None, bbox_local=None, m=IDENT):
        if alpha <= 0.003:
            return
        sp = [(x * SS, y * SS) for x, y in pts]
        xs = [p[0] for p in sp]
        ys = [p[1] for p in sp]
        x0, y0 = int(math.floor(min(xs))), int(math.floor(min(ys)))
        x1, y1 = int(math.ceil(max(xs))) + 1, int(math.ceil(max(ys))) + 1
        if clip:
            cx0, cy0, cx1, cy1 = (int(v * SS) for v in clip)
            x0, y0, x1, y1 = max(x0, cx0), max(y0, cy0), min(x1, cx1), min(y1, cy1)
        x0, y0 = max(x0, 0), max(y0, 0)
        x1, y1 = min(x1, self.canvas.width), min(y1, self.canvas.height)
        if x1 <= x0 or y1 <= y0:
            return
        mask = Image.new("L", (x1 - x0, y1 - y0), 0)
        ImageDraw.Draw(mask).polygon([(x - x0, y - y0) for x, y in sp], fill=255)
        if gradient and bbox_local:
            layer = self.gradient_layer(gradient, color, alpha, bbox_local, m, x0, y0, x1, y1)
            a = layer.getchannel("A")
            from PIL import ImageChops

            layer.putalpha(ImageChops.multiply(a, mask))
        else:
            layer = Image.new("RGBA", (x1 - x0, y1 - y0), tuple(int(c) for c in color) + (0,))
            layer.putalpha(mask.point(lambda v: int(v * alpha)))
        self.canvas.alpha_composite(layer, dest=(x0, y0))

    def gradient_layer(self, grad, base, alpha, bbox, m, x0, y0, x1, y1):
        # Sample the gradient along its rotation in the element's local box,
        # multiplied by the base colour as Roblox does.
        bx, by, bw, bh = bbox
        rot = math.radians(grad.get("rotation") or 0)
        dx, dy = math.cos(rot), math.sin(rot)
        # inverse of m for mapping canvas pixels back to local space
        a, b, c, d, e, f = m
        det = a * e - b * d or 1
        ia, ib, id_, ie = e / det, -b / det, -d / det, a / det
        w, h = x1 - x0, y1 - y0
        step = 4
        small = Image.new("RGBA", (max(1, w // step + 1), max(1, h // step + 1)))
        px = small.load()
        stops = grad.get("stops") or []
        tstops = grad.get("transparency") or []
        for j in range(small.height):
            for i in range(small.width):
                cx, cy = (x0 + i * step) / SS - c, (y0 + j * step) / SS - f
                lx, ly = ia * cx + ib * cy, id_ * cx + ie * cy
                u = ((lx - bx) / (bw or 1) - 0.5) * dx + ((ly - by) / (bh or 1) - 0.5) * dy + 0.5
                u = min(1, max(0, u))
                gc = lerp_color(stops, u)
                gt = lerp_num(tstops, u)
                col = tuple(int(base[k] * gc[k] / 255) for k in range(3))
                px[i, j] = col + (int(255 * alpha * (1 - gt)),)
        return small.resize((w, h), Image.BILINEAR)

    def draw_text(self, node, x, y, w, h, s, clip, m, alpha_mul):
        text = node.get("text") or ""
        if not text or (node.get("textT") or 0) >= 0.999:
            return
        pad = mod(node, "UIPadding")
        pl = udim_px(pad and pad.get("left"), w, s)
        pr = udim_px(pad and pad.get("right"), w, s)
        pt = udim_px(pad and pad.get("top"), h, s)
        pb = udim_px(pad and pad.get("bottom"), h, s)
        bx, by, bw, bh = x + pl, y + pt, max(1.0, w - pl - pr), max(1.0, h - pt - pb)
        wrap = bool(node.get("textWrapped"))
        tsc = mod(node, "UITextSizeConstraint")
        if node.get("textScaled"):
            hi = min(100 * s, (tsc.get("max") if tsc and tsc.get("max") else 100) * s)
            lo = (tsc.get("min") if tsc and tsc.get("min") else 1) * s
            px = lo
            for cand in range(int(hi), int(lo) - 1, -1):
                tw, th, lines, _ = measure_text(node, cand, bw)
                if tw <= bw + 0.5 and th <= bh + 0.5 and (wrap or len(lines) == len(strip_rich(text).split("\n"))):
                    px = cand
                    break
        else:
            px = (node.get("textSize") or 14) * s
        tw, th, lines, font = measure_text(node, px, bw if wrap else None)

        truncated = False
        if not wrap and node.get("truncate") == "AtEnd" and tw > bw + 0.5:
            truncated = True
            line = lines[0]
            while line and line_length(line + "…", node.get("font"), px) > bw:
                line = line[:-1]
            lines = [line.rstrip() + "…"]
            tw = line_length(lines[0], node.get("font"), px)
        visible_label = node.get("_onscreen")
        if visible_label:
            name = node.get("_path")
            if truncated:
                self.issues.append({"kind": "truncated", "path": name, "text": strip_rich(text), "box_w": round(bw, 1), "needs_w": round(measure_text(node, px)[0], 1)})
            elif (tw > bw + 1.5 and not wrap) or th > bh + 1.5:
                self.issues.append({"kind": "overflow", "path": name, "text": strip_rich(text), "box": [round(bw, 1), round(bh, 1)], "text_size": [round(tw, 1), round(th, 1)]})
            if px < 9:
                self.issues.append({"kind": "tiny", "path": name, "text": strip_rich(text)[:40], "px": round(px, 1)})

        lh = px * (node.get("lineHeight") or 1.0)
        xa = node.get("xAlign") or "Center"
        ya = node.get("yAlign") or "Center"
        ty = by + {"Top": 0, "Center": (bh - th) / 2, "Bottom": bh - th}.get(ya, (bh - th) / 2)

        color = tuple(node.get("textColor") or [0, 0, 0])
        talpha = (1 - (node.get("textT") or 0)) * alpha_mul
        stroke = None
        uistroke = mod(node, "UIStroke")
        if uistroke and uistroke.get("enabled", True) is not False and (uistroke.get("mode") or "Contextual") == "Contextual":
            stroke = (tuple(uistroke.get("color") or [0, 0, 0]), max(1, (uistroke.get("thickness") or 1) * s), 1 - (uistroke.get("transparency") or 0))
        elif (node.get("strokeT") if node.get("strokeT") is not None else 1) < 0.999:
            stroke = (tuple(node.get("strokeColor") or [0, 0, 0]), max(1.0, s), 1 - node["strokeT"])

        big = get_font(node.get("font"), px * SS)
        pw_, ph_ = int((bw + 40 * s) * SS), int((th + 20 * s) * SS)
        if pw_ <= 0 or ph_ <= 0:
            return
        patch = Image.new("RGBA", (int(max(bw, tw) * SS + 40 * s * SS), ph_), (0, 0, 0, 0))
        pdraw = ImageDraw.Draw(patch)
        off_x = 20 * s * SS
        for i, line in enumerate(lines):
            line_runs = runs(line, node.get("font"), px * SS)
            lw = sum(f.getlength(t) for t, f in line_runs)
            if xa == "Left":
                lx = off_x
            elif xa == "Right":
                lx = off_x + bw * SS - lw
            else:
                lx = off_x + (bw * SS - lw) / 2
            ly = 10 * s * SS + i * lh * SS + (lh - px) * SS / 2
            # Roblox centres the glyph box; PIL anchors at the ascender, so use
            # the middle of the line as the anchor.
            kwargs = {"anchor": "lm"}
            yy = ly + px * SS / 2
            cx_ = lx
            for run_text, run_font in line_runs:
                if stroke:
                    sc, sw, sa = stroke
                    pdraw.text((cx_, yy), run_text, font=run_font, fill=sc + (int(255 * sa * alpha_mul),), stroke_width=int(round(sw * SS)), stroke_fill=sc + (int(255 * sa * alpha_mul),), **kwargs)
                pdraw.text((cx_, yy), run_text, font=run_font, fill=color + (int(255 * talpha),), **kwargs)
                cx_ += run_font.getlength(run_text)
            ink_l, ink_r = lx / SS, (lx + lw) / SS
            node.setdefault("_ink", []).append((ink_l, ink_r))
        dest_x = (bx - 20 * s) * SS
        dest_y = (ty - 10 * s) * SS
        if node.get("_ink"):
            base = dest_x / SS + apply(m, 0, 0)[0]
            lefts = [base + a for a, _ in node["_ink"]]
            rights = [base + b for _, b in node["_ink"]]
            node["_inkbox"] = (min(lefts), ty + apply(m, 0, 0)[1], max(rights), ty + th + apply(m, 0, 0)[1])
        if abs(m[1]) > 1e-6 or abs(m[3]) > 1e-6:
            # rotated: rotate the patch about the element centre
            ang = math.degrees(math.atan2(m[3], m[0]))
            ccx, ccy = apply(m, x + w / 2, y + h / 2)
            rel_cx = (x + w / 2) * SS - dest_x
            rel_cy = (y + h / 2) * SS - dest_y
            big_patch = Image.new("RGBA", (patch.width * 2, patch.height * 2), (0, 0, 0, 0))
            big_patch.alpha_composite(patch, dest=(int(patch.width - rel_cx), int(patch.height - rel_cy)))
            rotated = big_patch.rotate(-ang, resample=Image.BICUBIC, center=(patch.width, patch.height))
            dest_x = ccx * SS - patch.width
            dest_y = ccy * SS - patch.height
            patch = rotated
        else:
            dx_, dy_ = apply(m, 0, 0)
            dest_x += dx_ * SS
            dest_y += dy_ * SS
        self.paste_clipped(patch, dest_x, dest_y, clip)

    def paste_clipped(self, patch, dx, dy, clip):
        dx, dy = int(round(dx)), int(round(dy))
        x0, y0, x1, y1 = dx, dy, dx + patch.width, dy + patch.height
        cx0, cy0, cx1, cy1 = 0, 0, self.canvas.width, self.canvas.height
        if clip:
            cx0, cy0, cx1, cy1 = (max(cx0, int(clip[0] * SS)), max(cy0, int(clip[1] * SS)), min(cx1, int(clip[2] * SS)), min(cy1, int(clip[3] * SS)))
        ix0, iy0, ix1, iy1 = max(x0, cx0), max(y0, cy0), min(x1, cx1), min(y1, cy1)
        if ix1 <= ix0 or iy1 <= iy0:
            return
        crop = patch.crop((ix0 - x0, iy0 - y0, ix1 - x0, iy1 - y0))
        self.canvas.alpha_composite(crop, dest=(ix0, iy0))

    def draw_node(self, node, ox, oy, m, clip, alpha_mul, path):
        if node.get("visible", True) is False:
            return
        x, y, w, h = ox + node["_x"], oy + node["_y"], node["_w"], node["_h"]
        s = node["_s"]
        path = f"{path}/{node.get('name')}"
        node["_path"] = path
        rot = node.get("rotation") or 0
        if abs(rot) > 0.01:
            m = compose(m, rot_matrix(rot, x + w / 2, y + h / 2))

        gt = node.get("groupT") if node["class"] == "CanvasGroup" else None
        if gt:
            alpha_mul *= 1 - gt

        corner = mod(node, "UICorner")
        radius = 0.0
        if corner and corner.get("radius"):
            radius = corner["radius"][0] * min(w, h) + corner["radius"][1] * s
        pts = [apply(m, px, py) for px, py in rounded_rect_points(x, y, w, h, radius)]
        # on-screen bookkeeping for the report
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        node["_abs"] = (min(xs), min(ys), max(xs), max(ys))
        node["_clip"] = clip
        node["_rotated"] = abs(m[1]) > 1e-6 or abs(m[3]) > 1e-6
        # Scrolled out of its ScrollingFrame, or clipped away by an ancestor:
        # not on screen, so nothing about it can be wrong on screen.
        node["_onscreen"] = not clip or (min(xs) < clip[2] and max(xs) > clip[0] and min(ys) < clip[3] and max(ys) > clip[1])

        bgT = node.get("bgT") if node.get("bgT") is not None else 0
        grad = mod(node, "UIGradient")
        if grad and grad.get("enabled") is False:
            grad = None
        if bgT < 0.999 and node["class"] not in ("TextBox",) or node["class"] == "TextBox" and bgT < 0.999:
            self.fill_poly(pts, node.get("bg") or [255, 255, 255], (1 - bgT) * alpha_mul, clip, gradient=grad, bbox_local=(x, y, w, h), m=m)

        if node["class"] in ("ImageLabel", "ImageButton") and node.get("image"):
            it = node.get("imageT") or 0
            self.fill_poly(pts, node.get("imageColor") or [255, 255, 255], (1 - it) * 0.5 * alpha_mul, clip)

        stroke = mod(node, "UIStroke")
        if stroke and stroke.get("enabled", True) is not False:
            mode = stroke.get("mode") or "Contextual"
            if not is_text(node) or mode == "Border":
                t = (stroke.get("thickness") or 1) * s
                outer = [apply(m, px, py) for px, py in rounded_rect_points(x - t, y - t, w + 2 * t, h + 2 * t, radius + t if radius else 0)]
                col = stroke.get("color") or [0, 0, 0]
                a = (1 - (stroke.get("transparency") or 0)) * alpha_mul
                self.draw_ring(outer, pts, col, a, clip)

        if is_text(node):
            self.draw_text(node, x, y, w, h, s, clip, m, alpha_mul)

        child_clip = clip
        if node.get("clips") or node["class"] == "ScrollingFrame":
            box = node["_abs"]
            child_clip = box if not clip else (max(clip[0], box[0]), max(clip[1], box[1]), min(clip[2], box[2]), min(clip[3], box[3]))

        kids = sorted(node.get("children") or [], key=lambda c: c.get("z") or 1)
        for c in kids:
            self.draw_node(c, x, y, m, child_clip, alpha_mul, path)

    def draw_ring(self, outer, inner, color, alpha, clip):
        if alpha <= 0.003:
            return
        sp_o = [(px * SS, py * SS) for px, py in outer]
        sp_i = [(px * SS, py * SS) for px, py in inner]
        xs = [p[0] for p in sp_o]
        ys = [p[1] for p in sp_o]
        x0, y0 = max(0, int(min(xs))), max(0, int(min(ys)))
        x1, y1 = min(self.canvas.width, int(max(xs)) + 2), min(self.canvas.height, int(max(ys)) + 2)
        if clip:
            x0, y0 = max(x0, int(clip[0] * SS)), max(y0, int(clip[1] * SS))
            x1, y1 = min(x1, int(clip[2] * SS)), min(y1, int(clip[3] * SS))
        if x1 <= x0 or y1 <= y0:
            return
        mask = Image.new("L", (x1 - x0, y1 - y0), 0)
        d = ImageDraw.Draw(mask)
        d.polygon([(x - x0, y - y0) for x, y in sp_o], fill=255)
        d.polygon([(x - x0, y - y0) for x, y in sp_i], fill=0)
        layer = Image.new("RGBA", mask.size, tuple(color) + (0,))
        layer.putalpha(mask.point(lambda v: int(v * alpha)))
        self.canvas.alpha_composite(layer, dest=(x0, y0))

    def render(self):
        screens = [sc for sc in self.data["screens"] if sc.get("enabled", True) is not False]
        screens.sort(key=lambda sc: sc.get("order") or 0)
        inset = 0 if False else 36
        for sc in screens:
            top = 0 if sc.get("ignoreInset") else inset
            uiscale = mod(sc, "UIScale")
            s = uiscale["scale"] if uiscale and uiscale.get("scale") else 1.0
            pw, ph = self.vw, self.vh - top
            # A UIScale directly under a ScreenGui is drawn the PESSIMISTIC way:
            # it scales the Scale part of the ScreenGui's children as well as
            # their pixel offsets, so a fromScale(1, 1) root covers only `s` of
            # the screen. Whether the engine really does that is not known (the
            # Lune sandbox has no layout engine), and drawing the kind answer is
            # how a wrong tree used to come out looking clean. UIController
            # therefore never puts a UIScale there - it hangs it on a host Frame
            # sized 1/scale, which measure() below handles exactly - so this only
            # shows up if someone puts one back, and then it shows up as a
            # screen that stops short of the edge.
            pw, ph = pw * s, ph * s
            for c in sc.get("children") or []:
                measure(c, pw, ph, s)
                pos = c.get("position") or [0, 0, 0, 0]
                anc = c.get("anchor") or [0, 0]
                c["_x"] = pos[0] * pw + pos[1] * s - anc[0] * c["_w"]
                c["_y"] = top + pos[2] * ph + pos[3] * s - anc[1] * c["_h"]
            for c in sorted(sc.get("children") or [], key=lambda n: n.get("z") or 1):
                self.draw_node(c, 0, 0, IDENT, (0, 0, self.vw, self.vh), 1.0, sc["name"])

    # Roblox's own chrome, drawn as outlines over the result.
    def chrome(self):
        u = self.vh
        guides = []
        # Roblox's own top-bar buttons (menu, chat, and the unibar they expand
        # into) sit in the top-left corner; the rest of the strip is free.
        guides.append(("topbar", (0, 0, 170, 40)))
        if self.data.get("touch"):
            guides.append(("jump", (self.vw - 0.39 * u, self.vh - 0.22 * u, self.vw - 0.22 * u, self.vh - 0.05 * u)))
            guides.append(("thumbstick", (0.06 * u, self.vh - 0.45 * u, 0.46 * u, self.vh - 0.05 * u)))
        return guides

    def overlay_chrome(self, img, scale):
        d = ImageDraw.Draw(img)
        for name, (x0, y0, x1, y1) in self.chrome():
            box = [x0 * scale, y0 * scale, x1 * scale, y1 * scale]
            if name in ("jump", "thumbstick"):
                d.ellipse(box, outline=(255, 255, 255, 200), width=2)
            else:
                d.rectangle(box, outline=(255, 255, 255, 90), width=1)
            try:
                f = ImageFont.truetype(FALLBACK, max(10, int(9 * scale)))
                d.text((box[0] + 4, box[1] + 2), f"roblox:{name}", fill=(255, 255, 255, 170), font=f)
            except Exception:  # noqa: BLE001
                pass

    def analyse(self):
        chrome = self.chrome()

        def walk(node, container):
            if node.get("visible", True) is False or "_abs" not in node or not node.get("_onscreen"):
                return
            clip = node.get("_clip")
            viewport_clip = not clip or (clip[0] <= 0 and clip[1] <= 0 and clip[2] >= self.vw and clip[3] >= self.vh)
            x0, y0, x1, y1 = node["_abs"]
            drawn = (node.get("bgT") is not None and node["bgT"] < 0.99) or (is_text(node) and node.get("text"))
            if viewport_clip and drawn and (x0 < -1 or y0 < -1 or x1 > self.vw + 1 or y1 > self.vh + 1) and (x1 - x0) < self.vw * 1.5:
                self.issues.append({"kind": "offscreen", "path": node["_path"], "rect": [round(v) for v in (x0, y0, x1, y1)]})
            ink = node.get("_inkbox")
            if ink and container is not None and "_abs" in container and not node.get("_rotated"):
                c0, c1, c2, c3 = container["_abs"]
                over = max(c0 - ink[0], ink[2] - c2)
                if over > 2:
                    self.issues.append({"kind": "spill", "path": node["_path"], "text": strip_rich(node.get("text") or "")[:40], "container": container["_path"], "by_px": round(over, 1)})
            if drawn and not self._in_menu and node["class"] not in ("TextButton", "ImageButton"):
                for name, (a0, b0, a1, b1) in chrome:
                    if name == "topbar":
                        continue
                    ix = min(x1, a1) - max(x0, a0)
                    iy = min(y1, b1) - max(y0, b0)
                    if ix > 3 and iy > 3 and (is_text(node) and node.get("text")):
                        self.issues.append({"kind": "covered", "with": name, "path": node["_path"], "text": strip_rich(node.get("text") or "")[:30], "rect": [round(v) for v in (x0, y0, x1, y1)]})
            # A full-screen click-catcher (a panel's dimmed backdrop) covers
            # everything by design; it is not a control sitting on the chrome.
            backdrop = (x1 - x0) * (y1 - y0) > 0.5 * self.vw * self.vh
            if node["class"] in ("TextButton", "ImageButton") and not backdrop and not self._in_menu and (x1 - x0) > 2 and (y1 - y0) > 2:
                for name, (a0, b0, a1, b1) in chrome:
                    if x0 < a1 and x1 > a0 and y0 < b1 and y1 > b0:
                        self.issues.append({"kind": "chrome", "with": name, "path": node["_path"], "rect": [round(v) for v in (x0, y0, x1, y1)]})
            is_container = node.get("bgT") is not None and node["bgT"] < 0.9 and not is_text(node) or node["class"] in ("TextButton", "ImageButton") and node.get("bgT", 1) < 0.9
            for c in node.get("children") or []:
                walk(c, node if is_container else container)

        for sc in self.data["screens"]:
            if sc.get("enabled", True) is False:
                continue
            # Menus and result cards draw over Roblox's touch controls and
            # nobody moves or jumps while one is open, so "under the jump
            # button" is not a problem there. Everything below them is played
            # through: the HUD, the side buttons, the kill feed, notices.
            self._in_menu = (sc.get("order") or 0) >= MENU_DISPLAY_ORDER
            for c in sc.get("children") or []:
                walk(c, None)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    ensure_fonts()
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    r = Renderer(data)
    r.render()
    r.analyse()

    # A dark, slightly blue backdrop standing in for the 3D scene, so white
    # text and translucent panels read the way they would over a map.
    bg = Image.new("RGBA", r.canvas.size, (38, 44, 56, 255))
    grid = ImageDraw.Draw(bg)
    for gx in range(0, r.canvas.width, 40 * SS):
        grid.line([(gx, 0), (gx, r.canvas.height)], fill=(44, 51, 64, 255))
    for gy in range(0, r.canvas.height, 40 * SS):
        grid.line([(0, gy), (r.canvas.width, gy)], fill=(44, 51, 64, 255))
    bg.alpha_composite(r.canvas)

    out_scale = 2 if r.vw <= 1024 else 1
    out = bg.resize((int(r.vw * out_scale), int(r.vh * out_scale)), Image.LANCZOS)
    r.overlay_chrome(out, out_scale)
    out.convert("RGB").save(sys.argv[2])

    report = {"device": data.get("device"), "scenario": data.get("scenario"), "menu": data.get("menu"), "issues": r.issues}
    if len(sys.argv) > 3:
        json.dump(report, open(sys.argv[3], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    kinds = {}
    for i in r.issues:
        kinds[i["kind"]] = kinds.get(i["kind"], 0) + 1
    print(f"{sys.argv[2]}: {kinds or 'no issues'}")


if __name__ == "__main__":
    main()
