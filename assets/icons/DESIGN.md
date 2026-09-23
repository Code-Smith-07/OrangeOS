# Desktop icon family — September 2026 refinement

Original SVG artwork, not copied macOS application assets. Use macOS as a
reference for optical balance, legibility and material restraint, not as a
source of redistributed system icons.

- A consistent 64-unit grid and 4-unit tile inset for application icons.
- Keep folder and wastebasket silhouettes independent of application tiles.
- Neutral ceramic, graphite and metal surrounds; color belongs to the symbol.
- No emoji glyphs, baked-in text, arbitrary decorative badges or random folder
  colors. A folder's tint must eventually represent an explicit user choice.
- Sidebar symbols use a separate 24-unit outline family, not miniature dock art.
- Rasterize original SVGs through `tools/iconconv/desktop_icons.py`; the guest
  samples the premultiplied atlas at its backing scale. Source SVG remains the
  editable master. The generator's contact sheet is a visual inspection aid.

The menu bar has a separate optical family: original 20-point SVG symbols and
23-point batteries, baked to exactly 40/46 pixels for 2x output. Consistent
1.3–1.5-point strokes, clear silhouettes and two toggle capsules replace generic
miniature toolbar art. Status tint and unknown/off indications remain real.

The compact dock uses 44-point artwork with dedicated prefiltered 88-pixel
sprites from the same SVG masters; it no longer samples 192-pixel app artwork
down to a small dock icon with only a bilinear filter. Warm citrus, cyan folder
enamel, deep terminal glass, blue information porcelain and layered violet
windows add colour; dial, gear and wastebasket retain material-specific metal
and glass detail. Running dots are outside the artwork, not painted into icons.

Validation: all 48 sprites render within clipping at 1x/2x; monochrome tint,
pointer capture and private publication tests pass. This is a refinement pass,
not a claim of macOS visual or functional parity.
