#!/usr/bin/env python3
"""Extract ASCII glyph outlines from a TTF and emit a Zig source table.

Each glyph becomes a `Glyph` struct with:
  - advance_width (in font units, 2048 upem)
  - path (SVG path d-string, font units, y-down SVG convention)

At render time the engine scales by font_size/units_per_em and translates.
"""
import sys
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

FONT_PATH = "/System/Library/Fonts/SFNS.ttf"
OUTPUT = sys.argv[1] if len(sys.argv) > 1 else "src/render/glyphs.zig"
# ASCII printable range + space
CHARS = [chr(c) for c in range(0x20, 0x7F)]


def zig_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def main():
    font = TTFont(FONT_PATH)
    upem = font["head"].unitsPerEm
    cmap = font.getBestCmap()
    glyph_set = font.getGlyphSet()

    lines = [
        "// shieldcn-zig — render/glyphs.zig",
        f"// Auto-generated from {FONT_PATH} by tools/extract_glyphs.py.",
        f"// {len(CHARS)} ASCII glyphs at {upem} units/em. Do not edit manually.",
        "",
        "pub const units_per_em: u32 = 2048;",
        "",
        "pub const Glyph = struct {",
        "    advance_width: u32,",
        "    path: []const u8,",
        "};",
        "",
        "/// Lookup table: ASCII code (0x20..0x7E) → Glyph.",
        "/// Index = char_code - 0x20. Returns null for chars outside range.",
        "pub const glyphs = [_]Glyph{",
    ]

    for ch in CHARS:
        code = ord(ch)
        glyph_name = cmap.get(code)
        if glyph_name is None:
            lines.append(f"    .{{ .advance_width = {upem // 2}, .path = \"\" }}, // 0x{code:02X} {repr(ch)}")
            continue
        pen = SVGPathPen(glyph_set)
        # Flip Y: font coords are y-up, SVG is y-down.
        # scale(1, -1) flips y around the baseline (y=0).
        tpen = TransformPen(pen, (1, 0, 0, -1, 0, 0))
        glyph_set[glyph_name].draw(tpen)
        path = pen.getCommands()
        # Get advance width from hmtx
        advance = font["hmtx"][glyph_name][0]
        if not path:
            path_str = ""
        else:
            path_str = zig_escape(path)
        comment = f" // 0x{code:02X} {repr(ch)}"
        lines.append(f'    .{{ .advance_width = {advance}, .path = "{path_str}" }},{comment}')

    lines.append("};")
    lines.append("")
    lines.append("/// Look up a glyph by ASCII char code. Returns null if out of range.")
    lines.append("pub fn getGlyph(c: u8) ?Glyph {")
    lines.append("    if (c < 0x20 or c > 0x7E) return null;")
    lines.append("    return glyphs[c - 0x20];")
    lines.append("}")
    lines.append("")

    with open(OUTPUT, "w") as f:
        f.write("\n".join(lines))
    print(f"wrote {OUTPUT}: {len(CHARS)} glyphs, {upem} upem")


if __name__ == "__main__":
    main()
