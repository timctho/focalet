# Zommi branding

The Zommi logo uses the Ocean palette:

| Asset | Color |
| --- | --- |
| [Light-surface logo](exports/ocean/lockup-light.svg) | `#387DA8` |
| [Dark-surface logo](exports/ocean/lockup-dark.svg) | `#ACCEE6` |
| [App icon](exports/ocean/app.svg) | White on Ocean |

Editable geometry is in `masters/`; the wordmark is outlined Manrope. Preserve
the supplied proportions and leave at least one symbol stroke width of clear
space. The font's [SIL Open Font License](Manrope-OFL.txt) is retained here.

To regenerate SVGs and the Flutter, Windows and macOS icons from the repository
root, install CairoSVG and Pillow, then run:

```sh
python3 scripts/generate_brand_assets.py
```
