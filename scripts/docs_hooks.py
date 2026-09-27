"""Publish existing repository guides without maintaining duplicate documents."""
from pathlib import Path
import posixpath
import re
from urllib.parse import urlsplit

from mkdocs.structure.files import File

ROOT = Path(__file__).resolve().parents[1]
GENERATED = {"contributing.md": "CONTRIBUTING.md", "security.md": "SECURITY.md", "agent-guide.md": "AGENTS.md"}


def on_files(files, config):
    for destination, source in GENERATED.items():
        files.append(File.generated(config, destination, content=(ROOT / source).read_text()))
    return files


def on_page_markdown(markdown, page, config, files):
    source = ROOT / GENERATED.get(page.file.src_uri, "docs/" + page.file.src_uri)
    def rewrite(match):
        prefix, address, suffix = match.groups()
        url = urlsplit(address)
        if url.scheme or url.netloc or not url.path or url.path.startswith("/"):
            return match.group(0)
        target = (source.parent / url.path).resolve()
        if not target.is_relative_to(ROOT) or not target.exists():
            return match.group(0)
        relative = target.relative_to(ROOT).as_posix()
        reverse = {value: key for key, value in GENERATED.items()}
        destination = reverse.get(relative)
        if relative.startswith("docs/"):
            destination = relative.removeprefix("docs/")
        if destination:
            address = posixpath.relpath(destination, posixpath.dirname(page.file.src_uri) or ".")
        else:
            address = "https://github.com/timctho/zommi/blob/main/" + relative
        if url.fragment:
            address += "#" + url.fragment
        return prefix + address + suffix
    return re.sub(r"(\]\()([^\s)]+)(\))", rewrite, markdown)
