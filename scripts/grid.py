#!/usr/bin/env python3
"""Screenshot a simulator with a coordinate grid drawn over it.

A tap is aimed in points, a screenshot is measured in pixels, and mixing the two
sends the touch to the wrong place — a mistake that reads as "the button does not
work". This takes the shot, draws the grid in the units a tap actually takes, and
labels every crossing, so a coordinate can be read off the picture:

    scripts/grid.py <udid>                  # shot + grid, prints the paths
    scripts/grid.py <udid> --step 40        # coarser grid
    scripts/grid.py <udid> --tap 201 421    # tap that point, then shoot again

The labelled numbers are what `idb ui tap <udid> X Y` expects.
"""

import argparse
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

FONT = "/System/Library/Fonts/Supplemental/Arial.ttf"
INK = (255, 45, 85)
HALO = (255, 255, 255)


def shoot(udid, path):
    subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", str(path)],
                   check=True, capture_output=True)


def device_scale(udid, image):
    """Pixels per point. iPads render @2x while being wider in pixels than any
    @2x iPhone, so the width alone cannot tell the two apart — the device type
    is what actually decides."""
    listing = subprocess.run(["xcrun", "simctl", "list", "devices", "-j"],
                             check=True, capture_output=True, text=True).stdout
    if f'"udid" : "{udid}"' in listing:
        import json
        for devices in json.loads(listing)["devices"].values():
            for d in devices:
                if d["udid"] == udid:
                    return 2 if "iPad" in d["deviceTypeIdentifier"] else 3
    return 3 if image.width >= 1000 else 2


def draw_grid(src, dst, step, udid):
    image = Image.open(src).convert("RGB")
    scale = device_scale(udid, image)
    points = (image.width // scale, image.height // scale)
    canvas = ImageDraw.Draw(image, "RGBA")
    font = ImageFont.truetype(FONT, 9 * scale)

    for x in range(0, points[0] + 1, step):
        canvas.line([(x * scale, 0), (x * scale, image.height)], fill=(*INK, 70), width=1)
    for y in range(0, points[1] + 1, step):
        canvas.line([(0, y * scale), (image.width, y * scale)], fill=(*INK, 70), width=1)

    # every label sits on a plate of its own: over a screen that is itself full of
    # text, an outlined number is unreadable exactly where it is needed
    for x in range(0, points[0] + 1, step):
        for y in range(0, points[1] + 1, step):
            label = f"{x},{y}"
            box = canvas.textbbox((0, 0), label, font=font)
            w, h = box[2] - box[0], box[3] - box[1]
            left = min(x * scale + 3, image.width - w - 5)
            top = min(y * scale + 2, image.height - h - 6)
            canvas.rectangle([left - 2, top - 2, left + w + 3, top + h + 4],
                             fill=(255, 255, 255, 235))
            canvas.text((left, top), label, font=font, fill=(*INK, 255))

    image.save(dst)
    return points, scale


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("udid")
    parser.add_argument("--step", type=int, default=40, help="grid step in points")
    parser.add_argument("--tap", nargs=2, type=int, metavar=("X", "Y"),
                        help="tap this point (in points) before shooting")
    parser.add_argument("--out", default=None, help="where to write the grid image")
    args = parser.parse_args()

    if args.tap:
        subprocess.run(["idb", "ui", "tap", "--udid", args.udid,
                        str(args.tap[0]), str(args.tap[1])], check=True)

    out = Path(args.out) if args.out else Path(f"/tmp/grid-{args.udid[:8]}.png")
    raw = out.with_name(out.stem + "-raw.png")
    shoot(args.udid, raw)
    points, scale = draw_grid(raw, out, args.step, args.udid)
    print(f"{out}  ({points[0]}x{points[1]} points, @{scale}x, grid every {args.step})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
