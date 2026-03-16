# Fcitx5 Custom Input Method Installation Checklist

Use this checklist when installing or debugging a self-built fcitx5 input method (including this project).

## Pre-install

- [ ] Confirm fcitx5 is installed and running in the current session.
- [ ] Confirm build dependencies are installed: `cmake`, `g++`, `pkg-config`, `libdbus-1-dev`, fcitx5 dev headers.
- [ ] Build against the same fcitx5 version/ABI used by the current system.
- [ ] Decide one install prefix only (`~/.local` or `/usr`) and avoid mixing both.
- [ ] Ensure the plugin `.so` links cleanly (`ldd` shows no missing libraries).

## File layout and metadata

- [ ] Plugin shared object is installed to `PREFIX/lib/fcitx5/`.
- [ ] Addon config is installed to `PREFIX/share/fcitx5/addon/`.
- [ ] Input method config is installed to `PREFIX/share/fcitx5/inputmethod/`.
- [ ] Names are consistent across files (`UniqueName`, addon name, input method name).
- [ ] If D-Bus is used, service name/interface/path match between plugin and daemon.

## Runtime and service

- [ ] If using a daemon, systemd user service is enabled and active.
- [ ] User-level D-Bus interface/service files are present if required.
- [ ] Required runtime files (models, prompts, config) exist and are readable.
- [ ] Audio/input backend dependencies are available (for speech IME projects).

## Activation

- [ ] Input method appears in fcitx5 config UI and can be added.
- [ ] Hotkey does not conflict with global/system shortcuts.
- [ ] Reload fcitx5 after install (`fcitx5-remote -r`) or restart session.
- [ ] Test commit path in real apps (terminal, browser, editor).

## Environment

- [ ] IM env vars are set correctly for the session (`GTK_IM_MODULE`, `QT_IM_MODULE`, `XMODIFIERS`).
- [ ] Wayland/X11-specific integration requirements are satisfied.

## Uninstall / upgrade hygiene

- [ ] Uninstall removes both plugin files and service files.
- [ ] No stale copy remains in the other prefix (`/usr` vs `~/.local`).
- [ ] Reinstall path is consistent with previous install method.

## Debug quick path

- [ ] Run `fcitx5-diagnose` and review warnings/errors.
- [ ] Check logs: `journalctl --user -u fcitx5* -n 200 --no-pager`.
- [ ] Check daemon logs/status if applicable.
- [ ] Verify plugin files still exist after rebuild/upgrade.
