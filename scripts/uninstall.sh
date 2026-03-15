#!/usr/bin/env bash
set -euo pipefail

echo "==> Uninstalling fcitx5-whispercpp"

systemctl --user disable --now fcitx5-whispercpp-daemon.service || true
rm -f "$HOME/.config/systemd/user/fcitx5-whispercpp-daemon.service"
systemctl --user daemon-reload

if [[ -f /usr/lib/fcitx5/whispercpp.so ]]; then
    sudo rm -f /usr/lib/fcitx5/whispercpp.so
    sudo rm -f /usr/share/fcitx5/addon/whispercpp.conf
    sudo rm -f /usr/share/fcitx5/inputmethod/whispercpp.conf
fi

rm -f "$HOME/.local/lib/fcitx5/whispercpp.so"
rm -f "$HOME/.local/share/fcitx5/addon/whispercpp.conf"
rm -f "$HOME/.local/share/fcitx5/inputmethod/whispercpp.conf"

rm -f "$HOME/.local/bin/fcitx5-whispercpp-daemon"
rm -f "$HOME/.local/share/dbus-1/interfaces/org.fcitx.Fcitx5.WhisperCpp.xml"
rm -rf "$HOME/.config/fcitx5-whispercpp"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/../tools/deconfigure_fcitx5.py"

if command -v fcitx5-remote >/dev/null 2>&1; then
    fcitx5-remote -r || true
else
    fcitx5 -r || true
fi

echo "Uninstall finished"
