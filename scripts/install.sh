#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODEL="base"
LANGUAGE="zh"
LOCAL_INSTALL=false
USE_BACKEND_BUILD=false
RESOLVED_MODEL=""

usage() {
    cat <<USAGE
Usage: $0 [--local] [--model <name>] [--language <code>]

Options:
  --local            Install to ~/.local
  --model <name>     whispercpp model (default: base)
                     - built-in name (e.g. base)
                     - local model file path (.bin/.gguf)
                     - Hugging Face repo id with whisper.cpp model files
                     - Hugging Face specific file: <repo_id>@<filename>
  --language <code>  language code (default: zh)

Backend build environment variables:
  GGML_VULKAN=1      Build pywhispercpp/whisper.cpp with Vulkan support
  GGML_CUDA=1        Build pywhispercpp/whisper.cpp with CUDA support
  WHISPER_CUDA=1     Alias of GGML_CUDA=1
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --local)
            LOCAL_INSTALL=true
            shift
            ;;
        --model)
            MODEL="$2"
            shift 2
            ;;
        --language)
            LANGUAGE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ "${WHISPER_CUDA:-0}" == "1" && "${GGML_CUDA:-0}" != "1" ]]; then
    # Compatibility alias used by some whisper.cpp wrappers.
    GGML_CUDA=1
fi

if [[ "${GGML_VULKAN:-0}" == "1" || "${GGML_CUDA:-0}" == "1" ]]; then
    USE_BACKEND_BUILD=true
fi

resolve_hf_model_repo() {
    uv run python "$SCRIPT_DIR/../tools/resolve_hf_model.py" "$1" "${2:-}"
}

RESOLVED_MODEL="$MODEL"
if [[ "$MODEL" == */* && ! -f "$MODEL" ]]; then
    HF_REPO="$MODEL"
    HF_FILE=""
    if [[ "$MODEL" == *"@"* ]]; then
        HF_REPO="${MODEL%@*}"
        HF_FILE="${MODEL#*@}"
    fi
    echo "==> Resolving Hugging Face model repo: $HF_REPO"
    if [[ -n "$HF_FILE" ]]; then
        echo "==> Requested model file: $HF_FILE"
    fi
    RESOLVED_MODEL="$(resolve_hf_model_repo "$HF_REPO" "$HF_FILE")"
    echo "==> Using downloaded whisper.cpp model: $RESOLVED_MODEL"
fi

echo "==> Installing fcitx5-whispercpp"
uv sync

if [[ "$USE_BACKEND_BUILD" == "true" ]]; then
    echo "==> Rebuilding pywhispercpp from source with backend flags"
    CMAKE_ARGS=""
    [[ "${GGML_VULKAN:-0}" == "1" ]] && CMAKE_ARGS="${CMAKE_ARGS:+$CMAKE_ARGS }-DGGML_VULKAN=ON"
    [[ "${GGML_CUDA:-0}" == "1" ]] && CMAKE_ARGS="${CMAKE_ARGS:+$CMAKE_ARGS }-DGGML_CUDA=ON"
    export CMAKE_ARGS GGML_VULKAN GGML_CUDA
    uv pip install --reinstall --no-binary pywhispercpp pywhispercpp
fi

mkdir -p "$HOME/.local/bin"
if ! uv run which fcitx5-whispercpp-daemon >/dev/null 2>&1; then
    uv pip install -e .
fi
DAEMON_PATH="$(uv run which fcitx5-whispercpp-daemon)"
ln -sf "$DAEMON_PATH" "$HOME/.local/bin/fcitx5-whispercpp-daemon"

echo "==> Building fcitx5 plugin"
mkdir -p build
(
    cd build
    if [[ "$LOCAL_INSTALL" == "true" ]]; then
        cmake .. -DCMAKE_INSTALL_PREFIX="$HOME/.local" -DCMAKE_BUILD_TYPE=Release
        make -j"$(nproc)"
        make install
    else
        cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release
        make -j"$(nproc)"
        sudo make install
    fi
)

echo "==> Installing systemd user service"
mkdir -p "$HOME/.config/systemd/user"
PROMPT_SOURCE="$PROJECT_ROOT/prompt.md"
PROMPT_TARGET_DIR="$HOME/.config/fcitx5-whispercpp"
PROMPT_TARGET="$PROMPT_TARGET_DIR/prompt.md"
mkdir -p "$PROMPT_TARGET_DIR"
if [[ -f "$PROMPT_SOURCE" ]]; then
    cp "$PROMPT_SOURCE" "$PROMPT_TARGET"
    echo "==> Whisper prompt loaded from $PROMPT_SOURCE"
else
    : > "$PROMPT_TARGET"
    echo "==> No prompt file found at $PROMPT_SOURCE; using empty whisper prompt"
fi

escape_sed_replacement() {
    printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'
}

SED_MODEL="$(escape_sed_replacement "$RESOLVED_MODEL")"
SED_LANGUAGE="$(escape_sed_replacement "$LANGUAGE")"
SED_PROMPT_FILE="$(escape_sed_replacement "$PROMPT_TARGET")"

sed -e "s|__MODEL__|$SED_MODEL|g" \
    -e "s|__LANGUAGE__|$SED_LANGUAGE|g" \
    -e "s|__PROMPT_FILE__|$SED_PROMPT_FILE|g" \
    systemd/fcitx5-whispercpp-daemon.service \
    > "$HOME/.config/systemd/user/fcitx5-whispercpp-daemon.service"

systemctl --user daemon-reload
systemctl --user enable fcitx5-whispercpp-daemon.service
systemctl --user restart fcitx5-whispercpp-daemon.service

echo "==> Installing D-Bus interface"
mkdir -p "$HOME/.local/share/dbus-1/interfaces"
cp dbus/org.fcitx.Fcitx5.WhisperCpp.xml "$HOME/.local/share/dbus-1/interfaces/"

echo "==> Configuring fcitx5 input method and hotkey"
uv run python "$SCRIPT_DIR/../tools/configure_fcitx5.py"

echo "==> Reloading fcitx5"
if command -v fcitx5-remote >/dev/null 2>&1; then
    if fcitx5-remote --check >/dev/null 2>&1; then
        fcitx5-remote -r || true
        # Ensure current DISPLAY is known by fcitx for X11 clients.
        fcitx5-remote -x || true
    else
        echo "fcitx5 is not running in this session; start fcitx5 manually."
    fi
else
    echo "fcitx5-remote not found; please restart fcitx5 manually."
fi

echo "Installation finished. Input method id: whispercpp"
