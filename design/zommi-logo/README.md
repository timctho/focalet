# Zommi logo study

**Selected: Relay (01), adopted 2026-09-19.** Two rounded forms compose a Z around an open diagonal gap. The two sides represent the context on the user's screen and the agent conversation; Zommi carries information between them. This follows the product's existing [context companion intent](../../docs/product-intent.md).

Open [preview.html](preview.html) for the original exploration with light, dark and mint backgrounds, actual-size samples and SVG downloads. [directions.png](directions.png) compares the three directions; [relay-brand-board.png](relay-brand-board.png) presents the selected identity. Orbit and Focus remain archived alternatives.

| Direction | Character | Tradeoff |
| --- | --- | --- |
| **01 Relay** | Compact, rounded Z; deliberate gap; context exchange | Strongest letter recognition and simplest silhouette. |
| **02 Orbit** | Continuous curved Z; soft, nearly circular outline | Warmer and more expressive; can also read as an abstract loop. |
| **03 Focus** | Two capture corners around a diagonal stroke | Clearest connection to selection; less immediately recognizable as a Z. |

## Reference study

- **OpenAI** — studied the Blossom's repeated geometry, controlled negative space and monochrome recognition. The [official brand page](https://openai.com/brand/) describes its combination of circles and right angles.
- **Claude / Anthropic** — studied the Claude symbol's approachable silhouette and the restrained typography and neutral palette on [Anthropic's company site](https://www.anthropic.com/company).
- **Perplexity** — studied the structured, economical line construction of its symbol. See [Perplexity](https://www.perplexity.ai/) and the [reference SVG](https://github.com/lobehub/lobe-icons/blob/master/packages/static-svg/icons/perplexity.svg).

Reference artwork inspected on 2026-09-19 also included the OpenAI and Claude SVGs from [Lobe Icons](https://github.com/lobehub/lobe-icons/tree/master/packages/static-svg/icons), the source already used by Zommi's runtime icons. The Perplexity brand-resource page returned HTTP 403, so no claim about its current brand guidelines is made. The observations above are design interpretations. The new Zommi symbols are original geometry; third-party logo paths are not included in these assets.

## Identity

| Role | Value |
| --- | --- |
| Ink | `#202823` |
| Paper | `#F4F3ED` |
| Mint accent | `#C5ECD4` |
| Wordmark | Lowercase Manrope, weight 650, tightened spacing; converted to vector paths |
| Recommended clear space | At least one symbol stroke width on all sides |
| Smallest supplied icon | 16 × 16 px |

Use Ink on light surfaces and white/Paper on dark surfaces. Mint is an optional application background; the symbol needs no color, gradients or shadows to work. Maintain the supplied proportions and the open middle gap. App icon exports include a rounded-square background. Transparent mark files contain only the symbol.

## Deliverables

- `masters/`: editable SVG symbols and an outlined wordmark.
- `exports/zommi-mark.svg`, `zommi-wordmark.svg`, `zommi-logo.svg`: recommended Relay identity.
- `exports/{relay,orbit,focus}/`: transparent ink/white marks and lockups, dark/light/mint app icons at 16, 24, 32, 48, 64, 128, 256, 512 and 1024 px, and Windows ICO files.
- `zommi-logo-kit.zip`: all three export sets, master vectors, review boards, interactive preview and font license.

The application uses Relay on Mint for its desktop icon and the transparent mark for setup and the macOS menu bar. Windows embeds a multi-resolution ICO; macOS uses its standard optical inset. Flutter, Linux and Windows notification assets are bundled under `assets/branding`. Regenerate production assets with `python scripts/generate_brand_assets.py` (CairoSVG and Pillow). The exploration ZIP remains the original review kit.

## Rebuilding exports

With Python, `cairosvg` and `Pillow` installed, run:

```sh
python design/zommi-logo/build_assets.py
```

The renderer uses the committed SVG masters and makes no network requests. Text on review boards uses the system sans-serif font. The logo wordmark itself is outlined and has no font dependency.

Manrope source: [Google Fonts](https://github.com/google/fonts/tree/main/ofl/manrope), SIL Open Font License 1.1; see [Manrope-OFL.txt](Manrope-OFL.txt). The outlined wordmark uses the original lowercase glyphs at weight 650 with 18 font units removed from the advance between letters.
