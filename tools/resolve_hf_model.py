#!/usr/bin/env python3
"""Download a whisper.cpp model file from a Hugging Face repo.

Usage:
    resolve_hf_model.py <repo_id> [<filename>]

Prints the local path of the downloaded model to stdout.
Exit codes:
    1 - network / unexpected error
    2 - repo has no .gguf/.bin files
    3 - requested filename not found in repo
"""

import sys
from pathlib import Path
from urllib.parse import quote
from urllib.request import urlopen, urlretrieve
import json


def score(name: str) -> tuple[int, int]:
    lower = name.lower()
    return (
        int("ggml" in lower or "whisper" in lower),
        int(lower.endswith(".gguf")),
    )


def resolve(repo: str, model_file: str) -> Path:
    api_url = f"https://huggingface.co/api/models/{quote(repo, safe='/')}"
    try:
        with urlopen(api_url, timeout=20) as response:
            data = json.load(response)
    except Exception as exc:
        print(
            f"Failed to query Hugging Face model repo '{repo}': {exc}", file=sys.stderr
        )
        sys.exit(1)

    siblings = data.get("siblings", [])
    if not siblings:
        print(f"No files found in Hugging Face repo '{repo}'", file=sys.stderr)
        sys.exit(1)

    file_names = [e.get("rfilename", "") for e in siblings if e.get("rfilename")]
    compatible = [n for n in file_names if n.endswith(".gguf") or n.endswith(".bin")]
    if not compatible:
        print(
            f"Repo '{repo}' has no whisper.cpp model file (.gguf/.bin). "
            "This repo is not directly usable by pywhispercpp.",
            file=sys.stderr,
        )
        sys.exit(2)

    if model_file:
        if model_file not in compatible:
            print(
                f"Requested file '{model_file}' not found in repo '{repo}' as a .gguf/.bin model.",
                file=sys.stderr,
            )
            sys.exit(3)
        chosen = model_file
    else:
        compatible.sort(key=score, reverse=True)
        chosen = compatible[0]

    cache_dir = (
        Path.home()
        / ".cache"
        / "fcitx5-whispercpp"
        / "models"
        / repo.replace("/", "__")
    )
    cache_dir.mkdir(parents=True, exist_ok=True)
    target = cache_dir / Path(chosen).name

    if not target.exists():
        download_url = (
            f"https://huggingface.co/{repo}/resolve/main/{quote(chosen, safe='/')}"
        )
        try:
            urlretrieve(download_url, target)
        except Exception as exc:
            print(
                f"Failed to download '{chosen}' from repo '{repo}': {exc}",
                file=sys.stderr,
            )
            sys.exit(1)

    return target


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <repo_id> [<filename>]", file=sys.stderr)
        sys.exit(1)
    repo = sys.argv[1]
    file = sys.argv[2] if len(sys.argv) > 2 else ""
    print(resolve(repo, file))
