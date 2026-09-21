#!/usr/bin/env python3
"""Export the selected Relay identity for desktop platforms (CairoSVG/Pillow)."""
from pathlib import Path
from io import BytesIO
import importlib.util

import cairosvg
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
FLUTTER = ROOT / "src/Zommi.Flutter"
DESIGN = ROOT / "design/zommi-logo"
OCEAN = "#387DA8"  # ZommiThemeColor.ocean
OCEAN_LIGHT = "#ACCEE6"


def ocean_exports() -> Path:
    """Use the original Relay geometry without rewriting the archived study."""
    spec = importlib.util.spec_from_file_location("logo_study", DESIGN / "build_assets.py")
    study = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(study)
    folder = DESIGN / "exports/ocean"
    folder.mkdir(parents=True, exist_ok=True)
    for tone, color in (("light", OCEAN), ("dark", OCEAN_LIGHT)):
        (folder / f"lockup-{tone}.svg").write_text(study.lockup("relay", color))
    (folder / "mark.svg").write_text(study.document(
        128, 128, study.nested("relay", 0, 0, 128, 128, OCEAN), "Zommi Ocean"))
    (folder / "app.svg").write_text(study.app_icon("relay", OCEAN, "#FFFFFF"))
    for name, source in (("zommi-mark.svg", "mark.svg"),
                         ("zommi-wordmark.svg", None),
                         ("zommi-logo.svg", "lockup-light.svg")):
        content = (folder / source).read_text() if source else study.document(
            321, 78, study.nested("wordmark", 0, 0, 321, 78, OCEAN), "Zommi")
        (DESIGN / "exports" / name).write_text(content)
    return folder


def main() -> None:
    assets = FLUTTER / "assets/branding"
    assets.mkdir(parents=True, exist_ok=True)
    mark = (DESIGN / "masters/relay.svg").read_bytes()
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
