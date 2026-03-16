#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODEL="base"
LANGUAGE="zh"
USE_BACKEND_BUILD=false
RESOLVED_MODEL=""
LOCAL_PREFIX="$HOME/.local"
LOCAL_ADDON_DIR="$LOCAL_PREFIX/lib/fcitx5"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SERVICE_NAME="fcitx5-whispercpp-daemon.service"

usage() {
    cat <<USAGE
Usage: $0 [--model <name>] [--language <code>]

Options:
  --model <name>     whispercpp model (default: base)
                     - built-in name (e.g. base)
                     - local model file path (.bin/.gguf)
                     - Hugging Face repo id with whisper.cpp model files
                     - Hugging Face specific file: <repo_id>@<filename>
  --language <code>  language code (default: zh)

Install path:
  Always installs to ~/.local (no sudo required)

Backend build environment variables:
  GGML_VULKAN=1      Build pywhispercpp/whisper.cpp with Vulkan support
  GGML_CUDA=1        Build pywhispercpp/whisper.cpp with CUDA support
  WHISPER_CUDA=1     Alias of GGML_CUDA=1
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
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

mkdir -p "$LOCAL_PREFIX/bin"
if ! uv run which fcitx5-whispercpp-daemon >/dev/null 2>&1; then
    uv pip install -e .
fi
DAEMON_PATH="$(uv run which fcitx5-whispercpp-daemon)"
ln -sf "$DAEMON_PATH" "$LOCAL_PREFIX/bin/fcitx5-whispercpp-daemon"

echo "==> Building fcitx5 plugin"
mkdir -p build
(
    cd build
    cmake .. \
        -DCMAKE_INSTALL_PREFIX="$LOCAL_PREFIX" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_INSTALL_DATADIR=share \
        -DCMAKE_BUILD_TYPE=Release
    make -j"$(nproc)"
    make install
)

echo "==> Installing systemd user service"
mkdir -p "$SYSTEMD_USER_DIR"

echo "==> Persisting fcitx5 addon library path"
mkdir -p "$HOME/.config/environment.d"
SYSTEM_ADDON_DIRS=""
for dir in /usr/lib/fcitx5 /usr/lib64/fcitx5; do
    if [[ -d "$dir" ]]; then
        SYSTEM_ADDON_DIRS="${SYSTEM_ADDON_DIRS:+$SYSTEM_ADDON_DIRS:}$dir"
    fi
done
ENV_FILE="$HOME/.config/environment.d/fcitx5-whispercpp.conf"
FCITX_ADDON_DIRS="$LOCAL_ADDON_DIR${SYSTEM_ADDON_DIRS:+:$SYSTEM_ADDON_DIRS}"
cat > "$ENV_FILE" <<EOF
FCITX_ADDON_DIRS=$FCITX_ADDON_DIRS
EOF
export FCITX_ADDON_DIRS
systemctl --user import-environment FCITX_ADDON_DIRS || true

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

post_install_checks() {
    echo "==> Running post-install checks"
    local warnings=0

    if [[ -f "$LOCAL_ADDON_DIR/whispercpp.so" ]] \
        && [[ -f "$LOCAL_PREFIX/share/fcitx5/addon/whispercpp.conf" ]] \
        && [[ -f "$LOCAL_PREFIX/share/fcitx5/inputmethod/whispercpp.conf" ]]; then
        echo "[OK] Plugin files installed under ~/.local."
    else
        echo "[WARN] Missing plugin files under ~/.local; reinstall may be required."
        warnings=$((warnings + 1))
    fi

    if systemctl --user is-active --quiet "$SERVICE_NAME"; then
        echo "[OK] systemd user service is active."
    else
        echo "[WARN] fcitx5-whispercpp-daemon.service is not active."
        warnings=$((warnings + 1))
    fi

    if command -v busctl >/dev/null 2>&1; then
        if busctl --user list 2>/dev/null | grep -q 'org.fcitx.Fcitx5.WhisperCpp'; then
            echo "[OK] D-Bus name org.fcitx.Fcitx5.WhisperCpp is registered."
        else
            echo "[WARN] D-Bus name org.fcitx.Fcitx5.WhisperCpp is not registered."
            warnings=$((warnings + 1))
        fi
    fi

    if command -v fcitx5-remote >/dev/null 2>&1 && fcitx5-remote --check >/dev/null 2>&1; then
        local pid=""
        local env_line=""
        pid="$(pgrep -u "$USER" -x fcitx5 | head -n1 || true)"
        if [[ -n "$pid" && -r "/proc/$pid/environ" ]]; then
            env_line="$(tr '\0' '\n' < "/proc/$pid/environ" | grep '^FCITX_ADDON_DIRS=' || true)"
        fi

        if [[ "$env_line" == *"$LOCAL_ADDON_DIR"* ]]; then
            echo "[OK] Running fcitx5 process has ~/.local addon path in FCITX_ADDON_DIRS."
        else
            echo "[WARN] Running fcitx5 process does not include ~/.local/lib/fcitx5 in FCITX_ADDON_DIRS."
            echo "       Restart fcitx5 now (fcitx5-remote -r) or re-login to apply environment.d."
            warnings=$((warnings + 1))
        fi
    else
        echo "[WARN] fcitx5 is not running in this session."
        echo "       Start fcitx5 (or re-login), then test whispercpp input method."
        warnings=$((warnings + 1))
    fi

    if [[ "$warnings" -eq 0 ]]; then
        echo "Post-install checks passed."
    else
        echo "Post-install checks finished with $warnings warning(s)."
    fi
}

SED_MODEL="$(escape_sed_replacement "$RESOLVED_MODEL")"
SED_LANGUAGE="$(escape_sed_replacement "$LANGUAGE")"
SED_PROMPT_FILE="$(escape_sed_replacement "$PROMPT_TARGET")"

sed -e "s|__MODEL__|$SED_MODEL|g" \
    -e "s|__LANGUAGE__|$SED_LANGUAGE|g" \
    -e "s|__PROMPT_FILE__|$SED_PROMPT_FILE|g" \
    systemd/fcitx5-whispercpp-daemon.service \
    > "$SYSTEMD_USER_DIR/$SERVICE_NAME"

systemctl --user daemon-reload
systemctl --user enable "$SERVICE_NAME"
systemctl --user restart "$SERVICE_NAME"

echo "==> Installing D-Bus interface"
mkdir -p "$LOCAL_PREFIX/share/dbus-1/interfaces"
cp dbus/org.fcitx.Fcitx5.WhisperCpp.xml "$LOCAL_PREFIX/share/dbus-1/interfaces/"

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

post_install_checks

echo "Installation finished. Input method id: whispercpp"
