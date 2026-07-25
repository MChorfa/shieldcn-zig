#!/usr/bin/env python3
"""Generate src/icons/embedded.zig from developer-icons SVG files."""

import sys
from pathlib import Path

DEV_ICONS_DIR = Path(
    "/Users/mchorfa/Documents/projects/github.com/public/developer-icons/icons"
)
OUT_FILE = Path(
    "/Users/mchorfa/Documents/projects/github.com/public/shieldcn-zig/src/icons/embedded.zig"
)

MAX_ICONS = 320  # Limit to avoid comptime bloat; adjust as needed


def escape_zig_string(s: bytes) -> str:
    """Escape a byte sequence for a Zig string literal."""
    result = []
    for b in s:
        if b == 34:  # double quote
            result.append('\\"')
        elif b == 92:  # backslash
            result.append("\\\\")
        elif b == 10:
            result.append("\\n")
        elif b == 13:
            result.append("\\r")
        elif b == 9:
            result.append("\\t")
        elif 32 <= b < 127:
            result.append(chr(b))
        else:
            result.append(f"\\x{b:02x}")
    return "".join(result)


def main():
    if not DEV_ICONS_DIR.exists():
        print(f"Error: {DEV_ICONS_DIR} does not exist", file=sys.stderr)
        sys.exit(1)

    svg_files = sorted([f for f in DEV_ICONS_DIR.iterdir() if f.suffix == ".svg"])
    if not svg_files:
        print(f"Error: no SVG files found in {DEV_ICONS_DIR}", file=sys.stderr)
        sys.exit(1)

    svg_files = svg_files[:MAX_ICONS]

    lines = [
        'const std = @import("std");',
        "",
        "/// shieldcn-zig — icons/embedded.zig",
        "/// Auto-generated from developer-icons. Do not edit manually.",
        '/// Maps icon slugs (e.g. "reactjs") to embedded SVG byte strings.',
        "",
    ]

    # Generate individual icon constants
    for svg_path in svg_files:
        slug = svg_path.stem
        raw = svg_path.read_bytes()
        escaped = escape_zig_string(raw)
        lines.append(f'pub const {slug.replace("-", "_")} = "{escaped}";')

    lines.append("")
    lines.append(
        "// ------------------------------------------------------------------"
    )
    lines.append("// Lookup table")
    lines.append(
        "// ------------------------------------------------------------------"
    )
    lines.append("")

    # Build entries for StaticStringMap
    entries = []
    for svg_path in svg_files:
        slug = svg_path.stem
        var_name = slug.replace("-", "_")
        entries.append(f'    .{{ "{slug}", {var_name} }}')

    lines.append("pub const icon_map = std.StaticStringMap([]const u8).initComptime(.{")
    lines.append(",\n".join(entries))
    lines.append("});")
    lines.append("")

    # Lookup helper
    lines.append("/// Resolve an icon slug to embedded SVG bytes.")
    lines.append("pub fn getEmbeddedIcon(slug: []const u8) ?[]const u8 {")
    lines.append("    return icon_map.get(slug);")
    lines.append("}")
    lines.append("")

    OUT_FILE.write_text("\n".join(lines) + "\n")
    print(f"Generated {OUT_FILE} with {len(svg_files)} icons")


if __name__ == "__main__":
    main()
