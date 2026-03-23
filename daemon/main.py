"""Entry point for fcitx5-whispercpp daemon."""

from __future__ import annotations

import argparse
import atexit
import logging
import logging.handlers
import os
import signal
import sys
from pathlib import Path

from gi.repository import GLib

from .dbus_service import start_dbus_service

service = None

_LOG_MAX_BYTES = 1024 * 1024  # 1 MiB per log file
_LOG_BACKUP_COUNT = 3


def _xdg_state_home() -> Path:
    """Return $XDG_STATE_HOME, defaulting to ~/.local/state per the XDG spec."""
    xdg = os.environ.get("XDG_STATE_HOME", "")
    return Path(xdg) if xdg else Path.home() / ".local" / "state"


def configure_logging(debug: bool) -> None:
    level = logging.DEBUG if debug else logging.INFO
    fmt = "%(asctime)s [%(levelname)s] %(name)s: %(message)s"
    datefmt = "%H:%M:%S"

    logging.basicConfig(level=level, format=fmt, datefmt=datefmt)

    log_dir = _xdg_state_home() / "fcitx5-whispercpp"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "fcitx5-whispercpp.log"

    file_handler = logging.handlers.RotatingFileHandler(
        log_file,
        maxBytes=_LOG_MAX_BYTES,
        backupCount=_LOG_BACKUP_COUNT,
        encoding="utf-8",
    )
    file_handler.setLevel(level)
    file_handler.setFormatter(logging.Formatter(fmt=fmt, datefmt=datefmt))
    logging.getLogger().addHandler(file_handler)


def cleanup() -> None:
    logging.info("fcitx5-whispercpp daemon stopped")


def _signal_handler(sig, frame) -> None:
    logging.info("Received signal %s", sig)
    sys.exit(0)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="fcitx5 whispercpp daemon")
    parser.add_argument("--debug", action="store_true", help="Enable debug logs")
    parser.add_argument("--model", default="base", help="Whisper model name")
    parser.add_argument("--language", default="zh", help="Language code")
    parser.add_argument("--device", type=int, default=None, help="Audio device index")
    parser.add_argument(
        "--prompt-file", default=None, help="Path to whisper initial prompt file"
    )
    return parser.parse_args()


def load_prompt(prompt_file: str | None) -> str | None:
    if not prompt_file:
        return None
    path = Path(prompt_file).expanduser()
    try:
        prompt = path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        logging.warning("Prompt file does not exist: %s", path)
        return None
    if not prompt:
        logging.info("Prompt file is empty: %s", path)
        return None
    logging.info("Loaded whisper prompt from %s", path)
    return prompt


def main() -> None:
    args = parse_args()
    configure_logging(args.debug)
    prompt = load_prompt(args.prompt_file)

    atexit.register(cleanup)
    signal.signal(signal.SIGINT, _signal_handler)
    signal.signal(signal.SIGTERM, _signal_handler)

    global service
    try:
        service = start_dbus_service(
            model=args.model,
            language=args.language,
            device=args.device,
            prompt=prompt,
        )
    except Exception as exc:
        logging.exception("Failed to start D-Bus service")
        raise SystemExit(1) from exc

    loop = GLib.MainLoop()
    loop.run()


if __name__ == "__main__":
    main()
