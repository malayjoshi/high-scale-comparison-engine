import os
from pathlib import Path


def load_env(path):
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        key, separator, value = line.partition("=")
        if separator:
            os.environ.setdefault(key.strip(), value.strip())
