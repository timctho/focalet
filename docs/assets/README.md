# Repository presentation assets

`social-card.png` is a 1280×640 composition generated with
`python scripts/generate_repo_banner.py`. It reuses the Ocean logo and the
reviewed `docs/demos/sheets.mp4` frame at 8 seconds plus `sheets-poster.webp`.
The sheet is synthetic and the response is from the recorded live agent demo.
Source recording identity and review are retained in `docs/demos/manifest.json`.

The card is used by the README, documentation site and GitHub social preview.
Review the exported image after changing its generator or source assets.
Pillow, FFmpeg and DejaVu Sans fonts are needed to regenerate it.
