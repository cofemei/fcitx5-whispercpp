# fcitx5-whispercpp

Local speech-to-text input method for fcitx5 powered by [whisper.cpp](https://github.com/ggerganov/whisper.cpp) via [pywhispercpp](https://github.com/abdeladim-s/pywhispercpp).

Press `Shift+Space` to start recording, press again to stop — transcribed text is committed into the active input field.

## Architecture

Three components communicate over D-Bus:

1. **C++ plugin** — fcitx5 input method engine; handles key events and commits text to the active input context
2. **Python daemon** — records audio via sounddevice and runs local whisper transcription via pywhispercpp
3. **D-Bus interface** — `org.fcitx.Fcitx5.WhisperCpp` coordinates recording control and text delivery

Everything runs locally — no network access is required for transcription.

## Requirements

- Linux with fcitx5
- C++ build tools: `cmake`, `g++`, `pkg-config`, `libdbus-1-dev`, fcitx5 development headers
- Python 3.12+
- [`uv`](https://github.com/astral-sh/uv)

## Install

```bash
./scripts/install.sh
```

| Flag | Default | Description |
|------|---------|-------------|
| `--model <name>` | `base` | Whisper model to use |
| `--language <code>` | `zh` | Transcription language code |

Install path is always `~/.local` (no sudo required).

**Model options:**

```bash
# Built-in pywhispercpp model name
./scripts/install.sh --model base

# Local .gguf / .bin file
./scripts/install.sh --model /path/to/model.gguf

# Hugging Face repo (auto-selects best .gguf/.bin file)
./scripts/install.sh --model username/repo

# Hugging Face repo with specific file
./scripts/install.sh --model username/repo@ggml-model-q5_k.gguf
```

Downloaded HF models are cached in `~/.cache/fcitx5-whispercpp/models/`.

**GPU acceleration:**

```bash
GGML_VULKAN=1 ./scripts/install.sh      # Vulkan (AMD / Intel)
GGML_CUDA=1   ./scripts/install.sh      # CUDA (NVIDIA)
WHISPER_CUDA=1 ./scripts/install.sh     # alias for GGML_CUDA
```

**Whisper prompt:**

Edit `prompt.md` before running install to prime the transcription with example phrases or vocabulary. The file is copied to `~/.config/fcitx5-whispercpp/prompt.md` and passed as `initial_prompt` to whisper on every transcription.

## After Install

1. Open fcitx5 configuration → **Input Methods**.
2. Add **fcitx5-whispercpp**.
3. Switch to this input method.
4. Press **Shift+Space** to start recording; press again to stop and commit.

The status indicator in the input panel shows the current state:

| Display | State |
|---------|-------|
| `W: Shift+Space to start` | idle, waiting |
| `W: recording...` | recording audio |
| `W: stopped` | processing |
| `W: text committed` | done |

## Uninstall

```bash
./scripts/uninstall.sh
```

Removes: plugin files, systemd service, D-Bus interface file, daemon symlink, `~/.config/fcitx5-whispercpp/`, and the whispercpp entry from `~/.config/fcitx5/profile`.

## Directory Layout

```text
fcitx5-whispercpp/
├── CMakeLists.txt                       C++ build root
├── daemon/                              Python D-Bus daemon
│   ├── __init__.py
│   ├── dbus_service.py                  Recorder + WhisperCppService
│   └── main.py                          Entry point (CLI)
├── dbus/
│   └── org.fcitx.Fcitx5.WhisperCpp.xml D-Bus interface definition
├── plugin/                              C++ fcitx5 plugin
│   ├── CMakeLists.txt
│   ├── dbus_client.cpp / .h             Low-level D-Bus client
│   ├── whispercpp_engine.cpp / .h       Input method engine
│   ├── whispercpp_engine_factory.cpp
│   ├── whispercpp-addon.conf.in         Addon config template
│   └── whispercpp.conf                  Input method registration
├── prompt.md                            Default whisper initial prompt
├── pyproject.toml
├── scripts/
│   ├── install.sh
│   └── uninstall.sh
├── systemd/
│   └── fcitx5-whispercpp-daemon.service Systemd user service template
├── tools/                               Install/uninstall helpers
│   ├── configure_fcitx5.py              Write fcitx5 profile + hotkey config
│   ├── deconfigure_fcitx5.py            Remove whispercpp from fcitx5 profile
│   └── resolve_hf_model.py              Download model from Hugging Face
└── uv.lock
```

## Development

Run lint/format checks with the project environment:

```bash
uv run ruff check daemon tools
uv run ruff format daemon tools
uv run shellcheck -x scripts/*.sh
```

## Automation

- **CI (`.github/workflows/ci.yml`)**: runs on push/PR to `main` and checks Python lint/format, shell scripts, and workflow syntax.
- **CodeQL (`.github/workflows/codeql.yml`)**: runs on push/PR to `main` and weekly schedule for Python/C++ static analysis.
- **Dependabot (`.github/dependabot.yml`)**: weekly updates for GitHub Actions and Python dependencies.
- **Release (`.github/workflows/release.yml`)**: pushes a tag like `v0.1.0` to create a GitHub Release with auto-generated notes.
- **Release message template (`.github/release.yml`)**: controls release note categories by PR labels.
