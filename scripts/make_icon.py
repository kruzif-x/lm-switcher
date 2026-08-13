#!/usr/bin/env python3
"""
make_icon.py — Generate the LM Switcher app icon set.

PURPOSE
-------
Produces the multi-resolution PNGs (16x16 through 1024x1024) that
macOS expects inside an `.iconset` directory, then compiles them
into a single `.icns` file via the `iconutil` command.

ICON DESIGN
-----------
A purple-to-blue vertical gradient (the "AI/tech" feel) forms the
background. Three connected nodes (top, middle, bottom) represent
the "switching between models" concept. The middle node glows
yellow to indicate the currently-active model. Curved brackets
on either side evoke the act of *selecting* or *switching*.

USAGE
-----
    python3 make_icon.py                  # regenerates icon.iconset/
    iconutil -c icns icon.iconset -o AppIcon.icns
    # (or just run install.sh, which does both)
"""

import os
from PIL import Image, ImageDraw

# Output directory (sibling of this script). macOS's iconutil expects
# the .iconset directory to be alongside the .icns output.
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icon.iconset")
os.makedirs(OUT_DIR, exist_ok=True)

# Sizes needed for a complete .icns bundle.
# macOS picks the appropriate size based on context (Finder, Launchpad,
# Dock, menu bar, etc.).
SIZES = [16, 32, 64, 128, 256, 512, 1024]

# Brand colors. All in 0-255 RGB.
COLOR_BG_TOP = (124, 58, 237)     # purple
COLOR_BG_BOTTOM = (37, 99, 235)   # blue
COLOR_ACCENT = (255, 255, 255)    # white
COLOR_GLOW = (199, 210, 254)      # light blue / lavender (brackets)
COLOR_HIGHLIGHT = (255, 255, 200) # pale yellow (active model node)


def make_icon(size, rounded=True):
    """Render the app icon at the given pixel size.

    We always render at 4x supersampling and downsample with
    LANCZOS. This avoids jagged edges and gives us a smooth icon
    that looks great on Retina displays too.

    Args:
        size: Final pixel size (one of 16, 32, 64, 128, 256, 512, 1024).
        rounded: If True (default), apply macOS's standard rounded
            corner radius. Otherwise render as a square.

    Returns:
        PIL.Image: An RGBA image of the requested size.
    """
    # Supersample: render at 4x and downsample.
    scale = 4
    s = size * scale

    # Start with a fully transparent image; we'll composite the
    # rounded-rect background on top of it.
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    # ------------------------------------------------------------------
    # Step 1: Gradient background with rounded corners.
    # ------------------------------------------------------------------
    # We draw a solid background, then iterate top-to-bottom, replacing
    # each scanline with a color interpolated between the top and bottom
    # of the gradient. This is the simplest way to get a smooth vertical
    # gradient without pulling in numpy.
    bg = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    bg_draw = ImageDraw.Draw(bg)
    radius = int(s * 0.22)  # macOS standard corner radius (~22%)
    if rounded:
        bg_draw.rounded_rectangle([(0, 0), (s, s)], radius=radius, fill=(0, 0, 0, 255))
    else:
        bg_draw.rectangle([(0, 0), (s, s)], fill=(0, 0, 0, 255))

    # Apply the gradient one scanline at a time. We use a temporary
    # Image because Pillow's `line()` is much faster than `point()`.
    for y in range(s):
        t = y / (s - 1) if s > 1 else 0
        r = int(COLOR_BG_TOP[0] * (1 - t) + COLOR_BG_BOTTOM[0] * t)
        g = int(COLOR_BG_TOP[1] * (1 - t) + COLOR_BG_BOTTOM[1] * t)
        b = int(COLOR_BG_TOP[2] * (1 - t) + COLOR_BG_BOTTOM[2] * t)
        bg_draw.line([(0, y), (s, y)], fill=(r, g, b, 255))

    # Composite the gradient onto the transparent canvas.
    img.paste(bg, (0, 0), bg)

    # ------------------------------------------------------------------
    # Step 2: The icon's central artwork.
    # ------------------------------------------------------------------
    # Layout: two main nodes (top, bottom) connected by a line, with a
    # glowing center node between them. Curved brackets on the sides
    # evoke "selecting" or "switching".
    draw = ImageDraw.Draw(img)
    cx, cy = s // 2, s // 2
    node_r = int(s * 0.10)

    top = (cx, cy - int(s * 0.18))
    bottom = (cx, cy + int(s * 0.18))
    middle = (cx, cy)

    # Connection lines (drawn first so they sit beneath the nodes).
    line_w = int(s * 0.04)
    draw.line([top, middle], fill=COLOR_ACCENT + (220,), width=line_w)
    draw.line([middle, bottom], fill=COLOR_ACCENT + (220,), width=line_w)

    # Side brackets. Drawn as 180° arcs (the "[" and "]" around the
    # switch). Arc width is the same as the connection lines.
    bracket_w = int(s * 0.06)
    bracket_h = int(s * 0.45)
    arc_w = int(s * 0.04)
    # Left bracket: arc from 90° to 270° (i.e. opening to the right).
    left_x = cx - int(s * 0.28)
    draw.arc(
        [(left_x - bracket_w // 2, cy - bracket_h // 2),
         (left_x + bracket_w // 2, cy + bracket_h // 2)],
        start=90, end=270, fill=COLOR_GLOW + (240,), width=arc_w
    )
    # Right bracket: arc from 270° to 90° (i.e. opening to the left).
    right_x = cx + int(s * 0.28)
    draw.arc(
        [(right_x - bracket_w // 2, cy - bracket_h // 2),
         (right_x + bracket_w // 2, cy + bracket_h // 2)],
        start=270, end=450, fill=COLOR_GLOW + (240,), width=arc_w
    )

    # ------------------------------------------------------------------
    # Step 3: Draw the three nodes (top, middle, bottom).
    # ------------------------------------------------------------------
    # Each node is a filled circle with a soft glow ring around it and
    # a small white highlight. The middle (active) node is yellow; the
    # others are white.
    for pos, color in [(top, COLOR_ACCENT), (middle, COLOR_HIGHLIGHT), (bottom, COLOR_ACCENT)]:
        x, y = pos
        # Concentric "glow" rings (decreasing alpha outward). The first
        # ring is the solid core; subsequent rings fade.
        for i in range(3):
            r = node_r + int(s * 0.02) * (3 - i)
            alpha = 60 - i * 20 if i > 0 else 255
            draw.ellipse(
                [(x - r, y - r), (x + r, y + r)],
                fill=color + (alpha,)
            )
        # Small inner highlight (top-left) to suggest a 3D ball.
        r2 = int(node_r * 0.4)
        draw.ellipse(
            [(x - r2, y - r2), (x + r2, y + r2)],
            fill=(255, 255, 255, 200)
        )

    # ------------------------------------------------------------------
    # Step 4: Downsample to the target size with LANCZOS.
    # ------------------------------------------------------------------
    # LANCZOS gives the best quality downsample. Without supersampling
    # we'd see jagged edges on curves and diagonals at small sizes.
    img = img.resize((size, size), Image.LANCZOS)
    return img


def main():
    """Generate every required PNG size and write them to icon.iconset/.

    macOS's iconutil expects specific filenames. We generate both the
    @1x and @2x variants for retina support.
    """
    for size in SIZES:
        if size in (16, 32, 64):
            # Generate @2x (twice the size) and the @1x versions.
            # The @2x is what Apple calls the "retina" version.
            img_2x = make_icon(size * 2, rounded=True)
            img_2x.save(os.path.join(OUT_DIR, f"icon_{size}x{size}@2x.png"))
            img = make_icon(size, rounded=True)
            img.save(os.path.join(OUT_DIR, f"icon_{size}x{size}.png"))
        elif size == 128:
            # 128 is its own size; the @2x is 256.
            img = make_icon(size, rounded=True)
            img.save(os.path.join(OUT_DIR, f"icon_128x128.png"))
        elif size == 256:
            # 256 = 128@2x and 256@1x.
            img = make_icon(size, rounded=True)
            img.save(os.path.join(OUT_DIR, f"icon_128x128@2x.png"))
            img.save(os.path.join(OUT_DIR, f"icon_256x256.png"))
        elif size == 512:
            # 512 = 256@2x and 512@1x.
            img = make_icon(size, rounded=True)
            img.save(os.path.join(OUT_DIR, f"icon_256x256@2x.png"))
            img.save(os.path.join(OUT_DIR, f"icon_512x512.png"))
        elif size == 1024:
            # 1024 = 512@2x and 1024@1x.
            img = make_icon(size, rounded=True)
            img.save(os.path.join(OUT_DIR, f"icon_512x512@2x.png"))
            img.save(os.path.join(OUT_DIR, f"icon_1024x1024.png"))

    print(f"Icon set generated in {OUT_DIR}")
    print("Files:")
    for f in sorted(os.listdir(OUT_DIR)):
        print(f"  {f}")


if __name__ == "__main__":
    main()
