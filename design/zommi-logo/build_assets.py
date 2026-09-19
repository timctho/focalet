#!/usr/bin/env python3
"""Render the Zommi logo study. Requires cairosvg and Pillow; no network access."""
from pathlib import Path
import html
import re
import shutil
import zipfile

import cairosvg
from PIL import Image

ROOT = Path(__file__).resolve().parent
INK = '#202823'
PAPER = '#F4F3ED'
SIGNAL = '#C5ECD4'
MUTED = '#657168'
WHITE = '#FFFFFF'
SIZES = (16, 24, 32, 48, 64, 128, 256, 512, 1024)
DIRECTIONS = {
    'relay': ('01', 'Relay', 'Two sides. One shared context.'),
    'orbit': ('02', 'Orbit', 'A softer, continuous Z.'),
    'focus': ('03', 'Focus', 'A frame for what matters.'),
}


def read_master(name):
    value = (ROOT / 'masters' / f'{name}.svg').read_text()
    vb = re.search(r'viewBox="([^"]+)"', value).group(1)
    inner = value.split('>', 1)[1].rsplit('</svg>', 1)[0]
    inner = re.sub(r'<title[^>]*>.*?</title>', '', inner)
    return vb, inner


def nested(name, x, y, width, height, color=INK):
    vb, inner = read_master(name)
    return (f'<svg x="{x}" y="{y}" width="{width}" height="{height}" '
            f'viewBox="{vb}" color="{color}" fill="currentColor">{inner}</svg>')


def document(width, height, content, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
            f'viewBox="0 0 {width} {height}" role="img" aria-labelledby="title">'
            f'<title id="title">{html.escape(title)}</title>{content}</svg>\n')


def rect(x, y, w, h, fill, radius=0, stroke=None):
    outline = f' stroke="{stroke}"' if stroke else ''
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}" fill="{fill}"{outline}/>'


def text(x, y, value, size=18, color=INK, weight=400, spacing=0):
    return (f'<text x="{x}" y="{y}" fill="{color}" font-family="Arial, sans-serif" '
            f'font-size="{size}" font-weight="{weight}" letter-spacing="{spacing}">'
            f'{html.escape(value)}</text>')


def lockup(name, color=INK):
    return document(490, 132, nested(name, 0, 2, 128, 128, color) +
                    nested('wordmark', 157, 27, 321, 78, color), 'Zommi logo')


def app_icon(name, background=INK, foreground=PAPER, size=1024):
    return document(size, size, rect(0, 0, size, size, background, size * .235) +
                    nested(name, size * .08, size * .08, size * .84, size * .84, foreground),
                    f'Zommi {name} app icon')


def save_svg_png(path, svg, png_width=None):
    path.write_text(svg)
    cairosvg.svg2png(bytestring=svg.encode(), write_to=str(path.with_suffix('.png')),
                    output_width=png_width)


def export_assets():
    exports = ROOT / 'exports'
    exports.mkdir(exist_ok=True)
    for name in DIRECTIONS:
        folder = exports / name
        folder.mkdir(exist_ok=True)
        for tone, color in [('ink', INK), ('white', WHITE)]:
            mark = document(128, 128, nested(name, 0, 0, 128, 128, color), f'Zommi {name}')
            save_svg_png(folder / f'mark-{tone}.svg', mark, 1024)
            save_svg_png(folder / f'lockup-{tone}.svg', lockup(name, color), 1960)
        for scheme, background, foreground in [('dark', INK, PAPER), ('light', PAPER, INK), ('mint', SIGNAL, INK)]:
            svg = app_icon(name, background, foreground)
            (folder / f'app-{scheme}.svg').write_text(svg)
            for size in SIZES:
                cairosvg.svg2png(bytestring=svg.encode(), write_to=str(folder / f'app-{scheme}-{size}.png'),
                                output_width=size, output_height=size)
        Image.open(folder / 'app-dark-1024.png').save(folder / 'app.ico', format='ICO',
            sizes=[(n, n) for n in (16, 24, 32, 48, 64, 128, 256)])
    shutil.copyfile(ROOT / 'masters' / 'relay.svg', exports / 'zommi-mark.svg')
    shutil.copyfile(ROOT / 'masters' / 'wordmark.svg', exports / 'zommi-wordmark.svg')
    (exports / 'zommi-logo.svg').write_text(lockup('relay'))


def comparison_board():
    parts = [rect(0, 0, 1560, 1160, PAPER)]
    parts += [text(56, 52, 'ZOMMI  /  IDENTITY EXPLORATION', 14, MUTED, 600, 2),
              text(56, 127, 'Context, connected.', 54, INK, 600, -1.6),
              text(58, 170, 'Three original symbols for the link between your screen and your agent.', 20, MUTED),
              text(1190, 52, 'SEPTEMBER 2026', 13, MUTED, 500, 1.5)]
    for index, (name, (number, label, caption)) in enumerate(DIRECTIONS.items()):
        x = 56 + index * 492
        parts += [rect(x, 226, 464, 570, WHITE, 24), text(x+28, 273, number, 14, MUTED, 600, 1),
                  text(x+61, 274, label, 21, INK, 600)]
        if name == 'relay':
            parts += [rect(x+290, 252, 146, 31, SIGNAL, 15), text(x+310, 273, 'RECOMMENDED', 11, INK, 600, .8)]
        parts += [nested(name, x+105, 324, 254, 254), nested('wordmark', x+145, 607, 174, 43),
                  text(x+28, 696, caption, 17, MUTED), rect(x+28, 721, 408, 1, '#E5E8E2')]
        for j,(bg,fg) in enumerate([(INK,PAPER),(PAPER,INK),(SIGNAL,INK)]):
            px=x+28+j*54
            parts += [rect(px,741,38,38,bg,10), nested(name,px+3,744,32,32,fg)]
        parts += [text(x+208,765,'16 / 24 / 32 / 64 px ready',12,MUTED)]
    parts += [rect(56, 834, 1448, 220, INK, 24), text(86,879,'DESIGN REFERENCES',12,SIGNAL,600,1.5),
              text(86,917,'OpenAI',23,PAPER,600), text(86,949,'Geometric continuity',16,'#B9C6BD'),
              text(550,917,'Claude / Anthropic',23,PAPER,600), text(550,949,'Warmth in the silhouette',16,'#B9C6BD'),
              text(1014,917,'Perplexity',23,PAPER,600), text(1014,949,'Clear geometric construction',16,'#B9C6BD'),
              text(86,1012,'Zommi combines a readable Z, a deliberate gap, and rounded terminals into its own symbol.',16,PAPER),
              text(56,1108,'Monochrome first.  Mint as an accent.  Outlined wordmark.  Editable SVG originals.',15,MUTED)]
    save_svg_png(ROOT / 'directions.svg', document(1560,1160,''.join(parts),'Three Zommi logo directions'))


def brand_board():
    parts=[rect(0,0,1560,1200,PAPER), text(56,54,'ZOMMI  /  RELAY',14,MUTED,600,2),
           text(1190,54,'PRIMARY DIRECTION',13,MUTED,500,1.5),
           nested('relay',126,152,310,310),nested('wordmark',510,228,780,190),
           text(515,478,'Your context. In the conversation.',25,MUTED)]
    parts += [rect(56,568,704,428,INK,28),text(88,616,'DESKTOP ICON',12,SIGNAL,600,1.4),
              rect(106,672,220,220,SIGNAL,52),nested('relay',124,690,184,184,INK),
              nested('relay',397,691,148,148,PAPER),text(399,882,'One color.',22,PAPER,600),
              text(399,915,'A clear Z at any scale.',16,'#B9C6BD')]
    parts += [rect(788,568,716,428,WHITE,28),text(820,616,'SMALL-SIZE CHECK',12,MUTED,600,1.4)]
    for i,size in enumerate((16,24,32,48,64)):
        x=828+i*128
        parts += [nested('relay',x,718+(64-size)/2,size,size),text(x,826,f'{size} px',14,MUTED)]
    parts += [text(820,900,'The gap stays open at 16 px.',21,INK,600),text(820,934,'No gradients or fine detail needed.',17,MUTED)]
    for i,(color,label) in enumerate([(INK,'INK  #202823'),(PAPER,'PAPER  #F4F3ED'),(SIGNAL,'MINT  #C5ECD4')]):
        x=56+i*492
        parts += [rect(x,1034,52,52,color,14,'#D9DED6'),text(x+70,1067,label,15,MUTED,600,.8)]
    parts += [text(56,1150,'Relay: two rounded forms hand context across a clear central gap, together reading as Z.',18,MUTED)]
    save_svg_png(ROOT/'relay-brand-board.svg',document(1560,1200,''.join(parts),'Zommi Relay logo and application study'))


def main():
    export_assets()
    comparison_board()
    brand_board()
    with zipfile.ZipFile(ROOT / 'zommi-logo-kit.zip', 'w', zipfile.ZIP_DEFLATED) as bundle:
        for folder in ['masters','exports']:
            for path in sorted((ROOT/folder).rglob('*')):
                if path.is_file(): bundle.write(path, path.relative_to(ROOT))
        for name in ['README.md','Manrope-OFL.txt','directions.png','relay-brand-board.png','preview.html']:
            if (ROOT/name).exists():bundle.write(ROOT/name,name)
    print('Rendered three directions, two review boards, and SVG/PNG/ICO export kits.')


if __name__ == '__main__':
    main()
