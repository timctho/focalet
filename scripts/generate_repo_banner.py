"""Create the 1280x640 social card from reviewed demo media and existing branding.

Requires Pillow, FFmpeg and the DejaVu Sans fonts (fonts-dejavu-core on Ubuntu).
No new screenshot or personal browser content is captured.
"""
from io import BytesIO
from pathlib import Path
import subprocess

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
    text(264, 29, "Show your agent what you mean.", 34, True)
    text(265, 80, "Visual context for Codex, Claude Code and more.", 21)
    text(42, 135, "01  SELECT + SKETCH", 18, True, "#286688")
    text(662, 135, "02  ASK YOUR AGENT", 18, True, "#286688")
    for x in (40, 660):
        draw.rounded_rectangle((x, 171, x + 580, 575), radius=16, fill="white", outline="#d1e0e8", width=2)
    frame = Image.open(BytesIO(subprocess.check_output([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", "8", "-i",
        str(ROOT / "docs/demos/sheets.mp4"), "-frames:v", "1", "-f", "image2pipe", "-vcodec", "png", "-",
    ]))).convert("RGB")
    selection = frame.crop((0, 0, int(frame.width * .625), frame.height))
    selection = ImageOps.contain(selection, (550, 378), Image.Resampling.LANCZOS)
    card.paste(selection, (55 + (550 - selection.width) // 2, 184 + (378 - selection.height) // 2))
    text(682, 198, '“Turn my sketch into two quotes.”', 22)
    text(682, 239, "A real response from the recorded demo:", 17, fill="#526b78")
    response = Image.open(ROOT / "docs/demos/sheets-poster.webp").convert("RGB")
    response = response.crop((205, 270, 1715, 810))
    response = ImageOps.contain(response, (554, 266), Image.Resampling.LANCZOS)
    card.paste(response, (673, 294))
    text(40, 600, "Windows  ·  macOS  ·  Ubuntu GNOME Wayland", 17)
    text(999, 600, "Open source · Apache 2.0", 16)
    destination = ROOT / "docs/assets/social-card.png"
    destination.parent.mkdir(parents=True, exist_ok=True)
    card.save(destination, optimize=True)
    print(f"{destination.relative_to(ROOT)}: {destination.stat().st_size:,} bytes")


if __name__ == "__main__":
    main()
