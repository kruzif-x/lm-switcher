#!/usr/bin/env python3
"""Export the engine-selection map (docs/engine-map.html) as a standalone SVG
(docs/engine-map.svg) so it can be embedded in README.md — GitHub renders
neither inline <svg> in markdown nor .html blobs, but it does render SVG
images.

Keeps the map's own <style> block verbatim (theme variables + light/dark via
prefers-color-scheme), adds the required xmlns, and paints the panel-coloured
backdrop the HTML page provided via CSS.

Run from anywhere after editing docs/engine-map.html:
    python3 scripts/export-engine-map-svg.py
"""
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
HTML = ROOT / "docs" / "engine-map.html"
OUT = ROOT / "docs" / "engine-map.svg"

html = HTML.read_text()

style_m = re.search(r"<style>(.*?)</style>", html, re.S)
svg_m = re.search(r"<svg\b.*?</svg>", html, re.S)
if not style_m or not svg_m:
    sys.exit("could not find <style> and/or <svg> in " + str(HTML))

style = style_m.group(1).strip("\n")
svg = svg_m.group(0)

# Required namespace + intrinsic size (GitHub scales it to the content column).
svg = svg.replace(
    "<svg ",
    '<svg xmlns="http://www.w3.org/2000/svg" width="1500" height="800" ',
    1,
)

# Panel-coloured backdrop instead of the HTML page's .panel CSS.
svg = svg.replace(
    "</defs>",
    '</defs>\n  <rect x="0" y="0" width="1500" height="800" fill="var(--panel)"></rect>',
    1,
)

open_tag = svg[: svg.index(">") + 1]
body = svg[svg.index(">") + 1 :]
out = (
    "<!-- Generated from docs/engine-map.html by scripts/export-engine-map-svg.py — do not edit by hand. -->\n"
    + open_tag
    + "\n<style>\n"
    + style
    + "\n</style>\n"
    + body
)

OUT.write_text(out)

# Validate: parses as XML, keeps every class and the arrow marker.
ET.fromstring(out)
classes_html = set(re.findall(r'class="([^"]+)"', svg_m.group(0)))
classes_svg = set(re.findall(r'class="([^"]+)"', out))
missing = classes_html - classes_svg
if missing:
    sys.exit(f"classes lost in export: {missing}")
if 'id="arr"' not in out:
    sys.exit("arrow marker lost")

print(f"wrote {OUT} relative to {ROOT}")
print(f"  bytes: {OUT.stat().st_size}")
print(f"  classes preserved: {sorted(classes_html)}")
print("  parses as XML: yes")
