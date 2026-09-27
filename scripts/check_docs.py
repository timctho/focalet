"""Build searchable documentation and check repository Markdown file links."""
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]


def main():
    failures = []
    documents = list(ROOT.glob("*.md")) + list((ROOT / "docs").rglob("*.md"))
    for document in documents:
        text = re.sub(r"```.*?```", "", document.read_text(), flags=re.S)
        for address in re.findall(r"\]\(([^\s)]+)\)", text):
            url = urlsplit(address)
            if url.scheme or url.netloc or not url.path or url.path.startswith("/"):
                continue
            if not (document.parent / unquote(url.path)).exists():
                failures.append(f"{document.relative_to(ROOT)}: missing {url.path}")
    if failures:
        raise SystemExit("\n".join(failures))
    subprocess.run([sys.executable, "-m", "mkdocs", "build", "--strict"], cwd=ROOT, check=True)
    print("Documentation built; local links and site anchors verified.")


if __name__ == "__main__":
    main()
