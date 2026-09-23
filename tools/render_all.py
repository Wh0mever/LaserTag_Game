#!/usr/bin/env python3
"""
tools/render_all.py
Renders every screen of the game on a phone, a tablet and a desktop, writes a
contact sheet, and fails if a layout is broken.

    python3 tools/render_all.py out_dir

For each scenario it runs tests/harness/export_gui.luau (the real client
modules, booted in the Lune sandbox at that device's viewport) and draws the
result with tools/render_gui.py. CI uploads out_dir, so every build carries
screenshots of what it changed — the owner can look at a phone layout in the
Actions tab instead of installing a build on a phone to find out.

WHAT FAILS THE BUILD: text drawn outside the button or panel that holds it,
text under Roblox's jump button or thumbstick, a control sitting on Roblox's
own buttons, and anything pushed off the screen. Truncation with an ellipsis
and tiny text are reported but do not fail: some of it is deliberate (a long
player name is meant to be cut), and those are judgement calls for a person
looking at the pictures, not for a threshold.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import render_gui  # noqa: E402

SCENARIOS = [
    ("phone", "hub", None),
    ("phone", "queue", None),
    ("phone", "hub", "SideMenu"),
    ("phone", "match", None),
    ("phone", "match", "SideMenu"),
    ("phone", "dead", None),
    ("phone", "results", None),
    ("phone", "match", "Side"),
    ("phone", "hub", "Shop"),
    ("phone", "hub", "Equip"),
    ("phone", "hub", "Spin"),
    ("phone", "hub", "Friends"),
    ("phone", "hub", "Settings"),
    ("phone", "hub", "Welcome"),
    ("tablet", "match", None),
    ("tablet", "hub", "Shop"),
    ("desktop", "hub", None),
    ("desktop", "match", None),
    ("desktop", "results", None),
    ("desktop", "match", "Side"),
    ("desktop", "hub", "Shop"),
    ("desktop", "hub", "Equip"),
    ("desktop", "hub", "Spin"),
    ("desktop", "hub", "Friends"),
    ("desktop", "hub", "Settings"),
    ("desktop", "hub", "Welcome"),
]

BLOCKING = {"spill", "covered", "chrome", "offscreen"}

# Deliberate, reviewed exceptions: (kind, path suffix) -> why it is fine.
ALLOWED = {
    # Roblox draws its version badge nowhere near a thumb, but on the smallest
    # phones the corner it sits in is the jump button's; it is four characters
    # of grey text nobody needs to read mid-fight.
    ("covered", "SideButtons/Root/Version"): "version label; not needed during play",
}


def allowed(issue):
    for (kind, suffix), _ in ALLOWED.items():
        if issue["kind"] == kind and issue.get("path", "").endswith(suffix):
            return True
    return False


def run(device, scenario, menu, out_dir):
    name = f"{device}_{scenario}" + (f"_{menu}" if menu else "")
    json_path = os.path.join(out_dir, f"{name}.json")
    png_path = os.path.join(out_dir, f"{name}.png")
    args = ["lune", "run", "tests/harness/export_gui", device, scenario] + ([menu] if menu else [])
    with open(json_path, "w", encoding="utf-8") as fh:
        proc = subprocess.run(args, cwd=ROOT, stdout=fh, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        return name, png_path, [{"kind": "export-failed", "path": name, "error": proc.stderr[-2000:]}]

    data = json.load(open(json_path, encoding="utf-8"))
    renderer = render_gui.Renderer(data)
    renderer.render()
    renderer.analyse()

    bg = Image.new("RGBA", renderer.canvas.size, (38, 44, 56, 255))
    bg.alpha_composite(renderer.canvas)
    scale = 2 if renderer.vw <= 1024 else 1
    img = bg.resize((int(renderer.vw * scale), int(renderer.vh * scale)), Image.LANCZOS)
    renderer.overlay_chrome(img, scale)
    img.convert("RGB").save(png_path)
    os.remove(json_path)
    return name, png_path, renderer.issues


def contact_sheet(entries, path):
    thumbs = []
    for name, png, _ in entries:
        if not os.path.exists(png):
            continue
        im = Image.open(png)
        w = 640
        h = int(im.height * w / im.width)
        thumbs.append((name, im.resize((w, h), Image.LANCZOS)))
    if not thumbs:
        return
    cols = 3
    cell_w = 640 + 16
    rows_h = []
    for i in range(0, len(thumbs), cols):
        rows_h.append(max(t.height for _, t in thumbs[i : i + cols]) + 34)
    sheet = Image.new("RGB", (cols * cell_w + 16, sum(rows_h) + 16), (16, 18, 24))
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.truetype(render_gui.FALLBACK, 16)
    y = 16
    for r, i in enumerate(range(0, len(thumbs), cols)):
        for c, (name, t) in enumerate(thumbs[i : i + cols]):
            x = 16 + c * cell_w
            draw.text((x, y), name, fill=(220, 230, 240), font=font)
            sheet.paste(t, (x, y + 24))
        y += rows_h[r]
    sheet.save(path)


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "ui-screenshots"
    os.makedirs(out_dir, exist_ok=True)
    render_gui.ensure_fonts()

    entries = []
    for device, scenario, menu in SCENARIOS:
        entries.append(run(device, scenario, menu, out_dir))

    contact_sheet(entries, os.path.join(out_dir, "00_overview.png"))

    blocking = []
    lines = ["## UI screenshots", "", "| screen | issues |", "|---|---|"]
    for name, _, issues in entries:
        counts = {}
        for issue in issues:
            counts[issue["kind"]] = counts.get(issue["kind"], 0) + 1
            if (issue["kind"] in BLOCKING or issue["kind"] == "export-failed") and not allowed(issue):
                blocking.append((name, issue))
        lines.append(f"| {name} | {', '.join(f'{k}: {v}' for k, v in sorted(counts.items())) or 'clean'} |")

    report = {name: issues for name, _, issues in entries}
    json.dump(report, open(os.path.join(out_dir, "report.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)

    if blocking:
        lines += ["", "### Blocking layout problems", ""]
        for name, issue in blocking:
            detail = {k: v for k, v in issue.items() if k not in ("kind",)}
            lines.append(f"- **{name}** `{issue['kind']}` {json.dumps(detail, ensure_ascii=False)}")

    summary = "\n".join(lines)
    print(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as fh:
            fh.write(summary + "\n")

    sys.exit(1 if blocking else 0)


if __name__ == "__main__":
    main()
