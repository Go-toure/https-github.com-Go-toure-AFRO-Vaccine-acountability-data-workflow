"""
_env_loader.py
Author: Gorgui Ba Toure

Loads KEY=VALUE lines from config/secrets.env (or config/secrets.env.txt, which is what Windows creates when the
file extension is hidden) into os.environ. A variable that is already set in the real environment is NOT overwritten.
Secrets are never printed.
"""
import os
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_secrets_env(base_dir=None):
    base = Path(base_dir) if base_dir else HERE
    loaded = None
    for name in ("secrets.env", "secrets.env.txt"):
        path = base / "config" / name
        if not path.exists():
            continue
        with open(path, "r", encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                key, value = key.strip(), value.strip().strip('"').strip("'")
                if key and value and not os.environ.get(key):
                    os.environ[key] = value
        loaded = name
        break
    return loaded
