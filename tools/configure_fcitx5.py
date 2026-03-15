#!/usr/bin/env python3
"""Configure fcitx5 profile and hotkey settings for whispercpp."""

from pathlib import Path


def find_section(lines: list[str], section: str) -> tuple[int, int]:
    """Return (section_start, section_end) indices, or (-1, len(lines)) if not found."""
    header = f"[{section}]"
    section_start = -1
    section_end = len(lines)
    for i, line in enumerate(lines):
        if line.strip() == header:
            section_start = i
            break
    if section_start >= 0:
        for i in range(section_start + 1, len(lines)):
            if lines[i].startswith("[") and lines[i].endswith("]"):
                section_end = i
                break
    return section_start, section_end


def ensure_key(lines: list[str], section: str, key: str, value: str) -> list[str]:
    header = f"[{section}]"
    key_prefix = f"{key}="
    section_start, section_end = find_section(lines, section)

    if section_start == -1:
        if lines and lines[-1].strip():
            lines.append("")
        lines.extend([header, f"{key_prefix}{value}"])
        return lines

    for i in range(section_start + 1, section_end):
        stripped = lines[i].strip()
        if stripped.startswith(key_prefix):
            lines[i] = f"{key_prefix}{value}"
            return lines

    lines.insert(section_end, f"{key_prefix}{value}")
    return lines


def ensure_list_first(lines: list[str], section: str, value: str) -> list[str]:
    header = f"[{section}]"
    section_start, section_end = find_section(lines, section)

    if section_start == -1:
        if lines and lines[-1].strip():
            lines.append("")
        lines.extend([header, f"0={value}"])
        return lines

    replaced = False
    remove_indices: list[int] = []
    for i in range(section_start + 1, section_end):
        stripped = lines[i].strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("0="):
            lines[i] = f"0={value}"
            replaced = True
            continue
        # Keep only one effective hotkey entry in this list section.
        if stripped.split("=", 1)[0].isdigit():
            remove_indices.append(i)

    for i in reversed(remove_indices):
        del lines[i]

    if not replaced:
        lines.insert(section_start + 1, f"0={value}")
    return lines


def configure() -> None:
    fcitx_dir = Path.home() / ".config" / "fcitx5"
    fcitx_dir.mkdir(parents=True, exist_ok=True)

    profile_path = fcitx_dir / "profile"
    try:
        profile_lines = profile_path.read_text().splitlines()
    except FileNotFoundError:
        profile_lines = []

    if not profile_lines:
        profile_lines = [
            "[Groups/0]",
            "Name=Default",
            "Default Layout=us",
            "DefaultIM=keyboard-us",
            "",
            "[Groups/0/Items/0]",
            "Name=keyboard-us",
            "Layout=",
            "",
            "[GroupOrder]",
            "0=Default",
        ]

    has_whispercpp = any(line.strip() == "Name=whispercpp" for line in profile_lines)
    if not has_whispercpp:
        item_indices: list[int] = []
        for line in profile_lines:
            line = line.strip()
            if line.startswith("[Groups/0/Items/") and line.endswith("]"):
                idx = line[len("[Groups/0/Items/"):-1]
                if idx.isdigit():
                    item_indices.append(int(idx))
        next_idx = max(item_indices) + 1 if item_indices else 0
        if profile_lines and profile_lines[-1].strip():
            profile_lines.append("")
        profile_lines.extend(
            [
                f"[Groups/0/Items/{next_idx}]",
                "Name=whispercpp",
                "Layout=",
            ]
        )
    else:
        # Existing non-keyboard IM entries may carry a keyboard layout from UI edits;
        # that can prevent switching to this IM.
        for i, line in enumerate(profile_lines):
            if line.strip() != "Name=whispercpp":
                continue
            for j in range(i + 1, len(profile_lines)):
                if profile_lines[j].startswith("[") and profile_lines[j].endswith("]"):
                    break
                if profile_lines[j].startswith("Layout="):
                    profile_lines[j] = "Layout="
                    break
            break

    profile_path.write_text("\n".join(profile_lines) + "\n")

    config_path = fcitx_dir / "config"
    try:
        config_lines = config_path.read_text().splitlines()
    except FileNotFoundError:
        config_lines = []
    config_lines = ensure_list_first(config_lines, "Hotkey/TriggerKeys", "Control+space")
    config_lines = ensure_list_first(config_lines, "Hotkey/EnumerateGroupForwardKeys", "Control+space")
    config_lines = ensure_key(config_lines, "Hotkey", "EnumerateWithTriggerKeys", "True")
    config_path.write_text("\n".join(config_lines) + "\n")


if __name__ == "__main__":
    configure()
