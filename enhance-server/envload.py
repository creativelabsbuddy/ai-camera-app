"""Tiny .env loader (no dependency). Never overrides variables already set
in the real environment, never logs values."""
from __future__ import annotations

import os


def load_env_file(path: str) -> int:
    n = 0
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return 0
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[7:].strip()
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
            v = v[1:-1]
        if k and k not in os.environ:
            os.environ[k] = v
            n += 1
    return n
