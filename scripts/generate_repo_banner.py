"""Create the 1280x640 social card from reviewed demo media and existing branding.

Requires Pillow and the DejaVu Sans fonts (fonts-dejavu-core on Ubuntu).
No new screenshot or personal browser content is captured.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parents[1]


def main():
    card = Image.new("RGB", (1280, 640), "#edf4f8")
    draw = ImageDraw.Draw(card)
    def font(size, bold=False):
        return ImageFont.truetype("DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf", size)
    def text(x, y, value, size=20, bold=False, fill="#183c4d"):
        draw.text((x, y), value, font=font(size, bold), fill=fill)
    logo = Image.open(ROOT / "design/zommi-logo/exports/ocean/lockup-light.png").convert("RGBA")
    logo.thumbnail((180, 55), Image.Resampling.LANCZOS)
    card.paste(logo, (40, 34), logo)
    text(264, 29, "Sketch the chart. See it change.", 30, True)
    text(265, 80, "Visual context for Codex, Claude Code and more.", 21)
    text(42, 135, "BEFORE", 18, True, "#286688")
    text(662, 135, "AFTER", 18, True, "#286688")
    for x in (40, 660):
        draw.rounded_rectangle((x, 171, x + 580, 575), radius=16, fill="white", outline="#d1e0e8", width=2)
    comparison = Image.open(ROOT / "docs/demos/frontend-poster.webp").convert("RGB")
    for x, bounds in ((55, (75, 318, 915, 852)), (675, (1005, 318, 1845, 852))):
        panel = ImageOps.contain(comparison.crop(bounds), (550, 378), Image.Resampling.LANCZOS)
        card.paste(panel, (x + (550 - panel.width) // 2, 184 + (378 - panel.height) // 2))
    text(40, 600, "Windows  ·  macOS  ·  Ubuntu GNOME Wayland", 17)
    text(999, 600, "Open source · Apache 2.0", 16)
    destination = ROOT / "docs/assets/social-card.png"
    destination.parent.mkdir(parents=True, exist_ok=True)
    card.save(destination, optimize=True)
    print(f"{destination.relative_to(ROOT)}: {destination.stat().st_size:,} bytes")


if __name__ == "__main__":
    main()
