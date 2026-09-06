# Daybreak SVG artwork

Original OrangeOS artwork: eight dimensional app icons and ten interface symbols.
These are SVG paths, not emoji, icon-font glyphs or Apple assets.
Licensed under the project's MIT license.

Run `tools/iconconv/desktop_icons.py` to regenerate the checked-in RGBA atlas.
App icons are baked at 192 px (96 logical points at 2×); interface symbols at
48 px. The framebuffer renderer uses premultiplied-alpha bilinear sampling.
The guest does not need an SVG parser, and ordinary builds do not need CairoSVG.

On the development Mac, regenerate with an isolated build-only dependency:

```sh
python3 -m pip install --target build/svg-tools 'CairoSVG==2.8.2'
PYTHONPATH=build/svg-tools DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib \
  python3 tools/iconconv/desktop_icons.py
```

The shared renderer's native tests draw every icon at 1x and 2x with clipping.
The OS atlas preserves full RGBA gradients; it is not palette-quantized.
