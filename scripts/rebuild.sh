#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> Cleaning build directory"
rm -rf "$PROJECT_ROOT/build"

echo "==> Building and installing"
GGML_VULKAN=1 "$SCRIPT_DIR/install.sh" --model 'alan314159/Breeze-ASR-25-whispercpp' --language zh

echo "==> Reloading systemd configuration"
systemctl --user daemon-reload
systemctl --user enable fcitx5-whispercpp-daemon.service

echo "==> Restarting daemon service"
systemctl --user restart fcitx5-whispercpp-daemon.service
sleep 2

echo "==> Verifying daemon is running"
if systemctl --user is-active --quiet fcitx5-whispercpp-daemon.service; then
    echo "✓ Daemon is running"
else
    echo "✗ Daemon failed to start"
    journalctl --user -u fcitx5-whispercpp-daemon.service -n 20
    exit 1
fi

echo "==> Restarting fcitx5"
pkill -9 fcitx5 2>/dev/null || true
pkill -9 fcitx5-wayland 2>/dev/null || true
sleep 2
fcitx5 -d
sleep 2

echo "✓ Done! fcitx5-whispercpp is ready"
echo ""
echo "Quick reference:"
echo "  - Shift+Space     : toggle recording"
echo "  - Ctrl+L          : show language menu"
echo "  - Ctrl+1 to Ctrl+6: select language pair"
echo ""
echo "Language pairs:"
echo "  1: auto→auto  (auto detect)"
echo "  2: zh→zh      (Chinese)"
echo "  3: zh→en      (Chinese→English)"
echo "  4: en→en      (English)"
echo "  5: ja→ja      (Japanese)"
echo "  6: ja→en      (Japanese→English)"
