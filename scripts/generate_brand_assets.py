#!/usr/bin/env python3
"""Export the selected Focalet focus identity for desktop platforms (CairoSVG/Pillow)."""
from pathlib import Path
from io import BytesIO
import html
import re

import cairosvg
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
FLUTTER = ROOT / "src/Focalet.Flutter"
DESIGN = ROOT / "design/focalet-logo"
OCEAN = "#387DA8"  # FocaletThemeColor.ocean
OCEAN_LIGHT = "#ACCEE6"


def read_master(name):
    value = (DESIGN / 'masters' / f'{name}.svg').read_text()
    vb = re.search(r'viewBox="([^"]+)"', value).group(1)
    inner = value.split('>', 1)[1].rsplit('</svg>', 1)[0]
    inner = re.sub(r'<title[^>]*>.*?</title>', '', inner)
    return vb, inner


def nested(name, x, y, width, height, color=OCEAN):
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


def lockup(name, color=OCEAN):
    return document(490, 132, nested(name, 0, 2, 128, 128, color) +
                    nested('wordmark', 157, 27, 321, 78, color), 'Focalet logo')


def app_icon(name, background=OCEAN, foreground="#FFFFFF", size=1024):
    return document(size, size, rect(0, 0, size, size, background, size * .235) +
                    nested(name, size * .08, size * .08, size * .84, size * .84, foreground),
                    f'Focalet {name} app icon')


def ocean_exports() -> Path:
    """Generate the Ocean logo from the maintained vector masters."""
    folder = DESIGN / "exports/ocean"
    folder.mkdir(parents=True, exist_ok=True)
    for tone, color in (("light", OCEAN), ("dark", OCEAN_LIGHT)):
        logo = lockup("focus", color)
        (folder / f"lockup-{tone}.svg").write_text(logo)
        # Supersample the README image, then filter its transparent edges.
        # Keep ample resolution for the 240 px lockup on high-DPI displays.
        with Image.open(BytesIO(cairosvg.svg2png(
            bytestring=logo.encode(), output_width=1960, output_height=528,
        ))) as rendered:
            rendered.resize((980, 264), Image.Resampling.LANCZOS).save(
                folder / f"lockup-{tone}.png", optimize=True)
    (folder / "mark.svg").write_text(document(
        128, 128, nested("focus", 0, 0, 128, 128, OCEAN), "Focalet Ocean"))
    (folder / "app.svg").write_text(app_icon("focus", OCEAN, "#FFFFFF"))
    for name, source in (("focalet-mark.svg", "mark.svg"),
                         ("focalet-wordmark.svg", None),
                         ("focalet-logo.svg", "lockup-light.svg")):
        content = (folder / source).read_text() if source else document(
            321, 78, nested("wordmark", 0, 0, 321, 78, OCEAN), "Focalet")
        (DESIGN / "exports" / name).write_text(content)
    return folder


def main() -> None:
    assets = FLUTTER / "assets/branding"
    assets.mkdir(parents=True, exist_ok=True)
    mark = (DESIGN / "masters/focus.svg").read_bytes()
    app_icon = (ocean_exports() / "app.svg").read_bytes()
    for name, source, size in (
        ("app-icon.png", app_icon, 256),
        ("mark.png", mark, 256),
        ("tray-template.png", mark, 32),
    ):
        cairosvg.svg2png(bytestring=source, write_to=str(assets / name),
                        output_width=size, output_height=size)

    # Supply native frames rather than asking Windows to resize a large bitmap.
    sizes = (16, 24, 32, 48, 64, 128, 256)
    frames = [Image.open(BytesIO(cairosvg.svg2png(
        bytestring=app_icon, output_width=size, output_height=size))) for size in sizes]
    try:
        frames[-1].save(ROOT / "src/Focalet.CaptureTool/app.ico",
                       format="ICO", sizes=[(n, n) for n in sizes],
                       append_images=frames[:-1])
        frames[-1].save(FLUTTER / "windows/runner/resources/app_icon.ico",
                       format="ICO", sizes=[(n, n) for n in sizes],
                       append_images=frames[:-1])
    finally:
        for frame in frames:
            frame.close()

    # Keep the standard macOS icon inset; menu-bar artwork is a separate mask.
    mac_icon = (b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
                + app_icon.replace(b'<svg ', b'<svg x="102" y="102" ', 1)
                          .replace(b'width="1024" height="1024"',
                                   b'width="820" height="820"', 1)
                + b'</svg>')
    catalog = FLUTTER / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for size in (16, 32, 64, 128, 256, 512, 1024):
        cairosvg.svg2png(bytestring=mac_icon, write_to=str(catalog / f"app_icon_{size}.png"),
                        output_width=size, output_height=size)


if __name__ == "__main__":
    main()
