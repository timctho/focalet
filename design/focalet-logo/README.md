# Focalet branding

The Focalet logo uses a tilted rounded aperture with a curved negative-space opening with an outlined Manrope
wordmark in the Ocean palette:

| Asset | Color |
| --- | --- |
| [Light-surface logo](exports/ocean/lockup-light.svg) | `#387DA8` |
| [Dark-surface logo](exports/ocean/lockup-dark.svg) | `#ACCEE6` |
| [App icon](exports/ocean/app.svg) | White on Ocean |

Editable geometry is in `masters/`; the wordmark is outlined Manrope at weight 650. Preserve
the supplied proportions and leave at least one symbol stroke width of clear
space. The font's [SIL Open Font License](Manrope-OFL.txt) is retained here.

The README uses transparent 980 × 264 PNG exports displayed at 360 px wide.
They are rendered from the same vectors with supersampling for smooth edges
on standard and high-DPI screens; light and dark variants match the page theme.

To regenerate SVGs and the Flutter, Windows and macOS icons from the repository
root, install CairoSVG and Pillow, then run:

```sh
python3 scripts/generate_brand_assets.py
```
