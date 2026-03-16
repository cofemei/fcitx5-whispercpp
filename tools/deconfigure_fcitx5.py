#!/usr/bin/env python3
"""Remove whispercpp entries from fcitx5 profile."""

from pathlib import Path


def deconfigure() -> None:
    profile_path = Path.home() / ".config" / "fcitx5" / "profile"
    try:
        lines = profile_path.read_text().splitlines()
    except FileNotFoundError:
        return

    # Find and remove the [Groups/0/Items/N] section that has Name=whispercpp.
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith("[Groups/0/Items/") and line.endswith("]"):
            # Collect this section's lines.
            section_start = i
            section_end = i + 1
            while section_end < len(lines):
                next_line = lines[section_end].strip()
                if next_line.startswith("[") and next_line.endswith("]"):
                    break
                section_end += 1
            section_body = lines[section_start:section_end]
            if any(
                section_line.strip() == "Name=whispercpp"
                for section_line in section_body
            ):
                # Drop trailing blank line before section if present.
                if section_start > 0 and not lines[section_start - 1].strip():
                    del lines[section_start - 1 : section_end]
                else:
                    del lines[section_start:section_end]
                continue  # recheck same index after deletion
        i += 1

    profile_path.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    deconfigure()
