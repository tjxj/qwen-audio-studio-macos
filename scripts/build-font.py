#!/usr/bin/env python3
"""Build the distributable OFL serif subset. This is a build-time tool only.

Usage: python3 scripts/build-font.py /path/to/SourceHanSerifSC-VF.ttf
Requires fontTools. The result is checked into Resources/Fonts, so end users
need neither the source font nor Python.
"""

from pathlib import Path
import sys

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont


def supported_characters() -> set[int]:
    characters = set(range(0x20, 0x7F))
    for lead in range(0xA1, 0xF8):
        for trail in range(0xA1, 0xFF):
            try:
                characters.add(ord(bytes((lead, trail)).decode("gb2312")))
            except UnicodeDecodeError:
                pass
    characters.update(ord(ch) for ch in "·—…“”‘’（）【】《》「」『』℃°≤≥→×✓")
    return characters


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python3 scripts/build-font.py /path/to/SourceHanSerifSC-VF.ttf")

    source = Path(sys.argv[1])
    if not source.is_file():
        raise SystemExit(f"Source font not found: {source}")

    font = TTFont(source)
    options = subset.Options()
    options.name_IDs = ["*"]
    options.name_languages = ["*"]
    options.layout_features = ["*"]
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=supported_characters())
    subsetter.subset(font)

    if "fvar" in font:
        font = instantiateVariableFont(font, {"wght": 400}, inplace=True)

    name = font["name"]
    for record in list(name.names):
        if record.nameID in (1, 2, 3, 4, 6, 16, 17, 25):
            name.removeNames(nameID=record.nameID)

    for platform_id, encoding_id, language_id in ((3, 1, 0x409), (1, 0, 0)):
        for name_id, value in (
            (1, "Qwen Studio Serif"),
            (2, "Regular"),
            (3, "QwenStudioSerif-Regular-1.0"),
            (4, "Qwen Studio Serif Regular"),
            (6, "QwenStudioSerif-Regular"),
            (16, "Qwen Studio Serif"),
            (17, "Regular"),
        ):
            name.setName(value, name_id, platform_id, encoding_id, language_id)

    output = Path(__file__).resolve().parent.parent / "Resources/Fonts/QwenStudioSerif-Regular.ttf"
    output.parent.mkdir(parents=True, exist_ok=True)
    font.save(output, reorderTables=True)
    print(f"Wrote {output} ({output.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
