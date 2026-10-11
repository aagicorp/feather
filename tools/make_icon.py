#!/usr/bin/env python3
"""Generates Feather's app icon.

No third-party packages: the artwork is computed here and written as SVG, then macOS's own
`sips` and `iconutil` turn it into Resources/AppIcon.icns.

    python3 tools/make_icon.py [variant]      # paper, mist, lavender, mint, sand, cloud, ink

The idea: a quill feather whose lower barbs are lines of code.
"""
import math
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Resources"
SIZE = 1024

# --- feather geometry, in a frame where the shaft is vertical and the tip points up -----------------------
TIP_Y, VANE_END_Y, QUILL_Y = -350.0, 190.0, 372.0
HALF_WIDTH = 172.0
LEAN = 40            # degrees the finished feather leans to the right
BEND = 46.0          # how far the shaft bows sideways


def half_width(y: float) -> float:
    """Half-width of the vane at height y: pointed at the tip, fullest below the middle, tapering to the quill."""
    t = (y - TIP_Y) / (VANE_END_Y - TIP_Y)
    if not 0 <= t <= 1:
        return 0.0
    return HALF_WIDTH * math.sin(math.pi * t ** 0.62) ** 0.85


def bend(x: float, y: float) -> tuple[float, float]:
    """Bows the feather so it reads as organic rather than ruler-straight."""
    t = (y - TIP_Y) / (QUILL_Y - TIP_Y)
    return x + BEND * math.sin(math.pi * t) , y


def point(x: float, y: float) -> str:
    bx, by = bend(x, y)
    return f"{bx:.1f},{by:.1f}"


def vane_path() -> str:
    """The solid right-hand half of the vane."""
    steps = 90
    ys = [TIP_Y + (VANE_END_Y - TIP_Y) * i / steps for i in range(steps + 1)]
    outer = [point(half_width(y), y) for y in ys]
    inner = [point(5, y) for y in reversed(ys)]
    return "M" + " L".join(outer + inner) + " Z"


def slits() -> str:
    """Two thin wedges cut into the solid half, the way real barbs separate."""
    wedges = []
    for y, depth in ((-120.0, 0.62), (48.0, 0.5)):
        w = half_width(y)
        a, b, c = (w + 8, y - 5), (w + 8, y + 17), (w * (1 - depth), y + 40)
        wedges.append(f'<polygon points="{point(*a)} {point(*b)} {point(*c)}" fill="black"/>')
    return "\n      ".join(wedges)


def code_lines() -> str:
    """The left-hand half: barbs drawn as rounded lines of code, of uneven length like real source."""
    lengths = [0.78, 0.55, 0.95, 0.7, 1.0, 0.62, 0.9, 0.74, 0.5]
    top, bottom = TIP_Y + 150, VANE_END_Y - 30
    lines = []
    for i, fraction in enumerate(lengths):
        y = top + (bottom - top) * i / (len(lengths) - 1)
        # Measure the silhouette where the barb ends (higher up), so a long line never pokes outside the feather.
        reach = (min(half_width(y), half_width(y - 40)) - 20) * fraction
        rise = reach * math.tan(math.radians(15))        # barbs sweep up toward the tip
        opacity = 0.95 - 0.045 * i
        lines.append(
            f'<line x1="{bend(-22, y)[0]:.1f}" y1="{y:.1f}" x2="{bend(-22 - reach, y - rise)[0]:.1f}" y2="{y - rise:.1f}" '
            f'stroke="url(#code)" stroke-width="25" stroke-linecap="round" opacity="{opacity:.2f}"/>')
    return "\n    ".join(lines)


def shaft_path() -> str:
    steps = 60
    ys = [TIP_Y + 26 + (QUILL_Y - TIP_Y - 26) * i / steps for i in range(steps + 1)]
    return "M" + " L".join(point(0, y) for y in ys)


# Flat backgrounds. The feather never changes; only the tile, and the shaft colour that has to read against it.
VARIANTS = {
    "paper":    {"name": "Paper",      "bg": "#F7F8FA", "shaft": "#1F2937", "light": True},
    "mist":     {"name": "Mist blue",  "bg": "#E3EEF9", "shaft": "#1E3A5F", "light": True},
    "lavender": {"name": "Lavender",   "bg": "#ECE8FB", "shaft": "#2E1F5E", "light": True},
    "mint":     {"name": "Mint",       "bg": "#E2F3EC", "shaft": "#14403A", "light": True},
    "sand":     {"name": "Sand",       "bg": "#F4EEE3", "shaft": "#3B2F20", "light": True},
    "cloud":    {"name": "Cloud grey", "bg": "#E6E8EC", "shaft": "#1F2937", "light": True},
    "ink":      {"name": "Ink",        "bg": "#141A2E", "shaft": "#F8FAFC", "light": False},
}
DEFAULT_VARIANT = "paper"


def svg(variant: str = DEFAULT_VARIANT, uid: str = "") -> str:
    """`uid` keeps gradient and filter ids unique when several icons share one HTML page."""
    look = VARIANTS[variant]
    # Apple's icon grid: an 824pt rounded square centred on a 1024pt canvas.
    inset, side, radius = 100, 824, 186
    edge = "#0F172A" if look["light"] else "#FFFFFF"
    shadow = ("#0F172A", "0.24") if look["light"] else ("#000000", "0.45")
    art = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#7C3AED"/><stop offset="0.5" stop-color="#4F46E5"/><stop offset="1" stop-color="#0891B2"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.68" cy="0.3" r="0.62">
      <stop offset="0" stop-color="#F0ABFC" stop-opacity="0.38"/><stop offset="1" stop-color="#F0ABFC" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="vane" x1="0" y1="1" x2="0.35" y2="0">
      <stop offset="0" stop-color="#2563EB"/><stop offset="0.5" stop-color="#22D3EE"/><stop offset="1" stop-color="#A7F3D0"/>
    </linearGradient>
    <linearGradient id="code" x1="1" y1="0" x2="0" y2="0">
      <stop offset="0" stop-color="#C4B5FD"/><stop offset="1" stop-color="#8B5CF6"/>
    </linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.16"/><stop offset="0.4" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <mask id="cuts">
      <rect x="-600" y="-600" width="1200" height="1200" fill="white"/>
      {slits()}
    </mask>
    <filter id="shadow" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="14" stdDeviation="18" flood-color="{shadow[0]}" flood-opacity="{shadow[1]}"/>
    </filter>
    <clipPath id="tile"><rect x="{inset}" y="{inset}" width="{side}" height="{side}" rx="{radius}"/></clipPath>
  </defs>

  <rect x="{inset}" y="{inset}" width="{side}" height="{side}" rx="{radius}" fill="{look["bg"]}"/>
  <rect x="{inset + 1.5}" y="{inset + 1.5}" width="{side - 3}" height="{side - 3}" rx="{radius - 1.5}"
        fill="none" stroke="{edge}" stroke-opacity="0.10" stroke-width="3"/>

  <g transform="translate(478 506) rotate({LEAN})" filter="url(#shadow)">
    <path d="{vane_path()}" fill="url(#vane)" mask="url(#cuts)"/>
    {code_lines()}
    <path d="{shaft_path()}" fill="none" stroke="{look["shaft"]}" stroke-width="12" stroke-linecap="round" stroke-linejoin="round"/>
  </g>

  <!-- the text cursor the quill has just written -->
  <rect x="338" y="776" width="150" height="30" rx="15" fill="#22D3EE"/>
</svg>
'''
    if uid:
        for name in ("bg", "glow", "vane", "code", "sheen", "cuts", "shadow", "tile"):
            art = art.replace(f'id="{name}"', f'id="{name}{uid}"').replace(f"url(#{name})", f"url(#{name}{uid})")
    return art


def run(*command: str) -> None:
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main() -> int:
    variant = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_VARIANT
    if variant not in VARIANTS:
        print(f"Unknown variant {variant!r}. Choose one of: {', '.join(VARIANTS)}")
        return 1
    RESOURCES.mkdir(exist_ok=True)
    source = RESOURCES / "AppIcon.svg"
    source.write_text(svg(variant))

    master = RESOURCES / "AppIcon.png"
    run("sips", "-s", "format", "png", "-z", str(SIZE), str(SIZE), str(source), "--out", str(master))

    with tempfile.TemporaryDirectory() as temporary:
        iconset = Path(temporary) / "AppIcon.iconset"
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = points * scale
                name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
                run("sips", "-z", str(pixels), str(pixels), str(master), "--out", str(iconset / name))
        run("iconutil", "-c", "icns", str(iconset), "-o", str(RESOURCES / "AppIcon.icns"))

    print(f"Wrote {source.relative_to(ROOT)}, {master.relative_to(ROOT)} and Resources/AppIcon.icns")
    return 0


if __name__ == "__main__":
    sys.exit(main())
