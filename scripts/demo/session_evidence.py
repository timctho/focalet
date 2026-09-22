"""Read captured context from real agent sessions for demo verification."""

import hashlib
import json
import re


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def objects_after(text, label):
    decoder = json.JSONDecoder()
    for match in re.finditer(re.escape(label) + r"[^\n]*\n", text):
        value, _ = decoder.raw_decode(text[match.end() :].lstrip())
        yield value


def inline_objects_after(text, label):
    decoder = json.JSONDecoder()
    for match in re.finditer(re.escape(label), text):
        value, _ = decoder.raw_decode(text[match.end() :].lstrip())
        yield value
