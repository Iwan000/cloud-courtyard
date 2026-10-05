"""字体子集化：只保留游戏中实际用到的字形，把 25MB 的思源宋体压到几百 KB。

扫描 scripts/ 下所有 .gd 和 levels/ 下所有 .json 中出现的字符，再加上常用标点与 ASCII，
用 fontTools 生成子集（保留可变字重轴）。编辑器中用户输入的其它汉字由系统字体回退显示。

用法：python3 tools/subset_fonts.py <原始字体目录>
"""
import pathlib
import sys

from fontTools import subset
from fontTools.ttLib import TTFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "fonts_src"
OUT = ROOT / "fonts"

EXTRA = (
    "".join(chr(c) for c in range(0x20, 0x7F))
    + "，。、；：？！“”‘’（）《》【】—…·～ ＋－×÷→←↑↓◇◆✓"
    + "零一二三四五六七八九十百千万"
)


def collect_chars() -> str:
    chars = set(EXTRA)
    for pattern in ("scripts/**/*.gd", "levels/*.json"):
        for path in ROOT.glob(pattern):
            chars.update(path.read_text(encoding="utf-8"))
    return "".join(sorted(c for c in chars if c.isprintable()))


def make_subset(src: pathlib.Path, dst: pathlib.Path, text: str) -> None:
    font = TTFont(src)
    cmap = font.getBestCmap()
    missing = [c for c in text if ord(c) not in cmap and not c.isspace()]
    opts = subset.Options()
    opts.layout_features = ["*"]
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    sub = subset.Subsetter(opts)
    sub.populate(text=text)
    sub.subset(font)
    font.save(dst)
    print(f"{dst.name}: {dst.stat().st_size / 1024:.0f} KB, missing {len(missing)} chars"
          + (f" (e.g. {''.join(missing[:20])})" if missing else ""))


def main() -> None:
    text = collect_chars()
    latin = "".join(c for c in text if ord(c) < 0x2000) + "·—–’‘“”…"
    OUT.mkdir(exist_ok=True)
    make_subset(SRC / "NotoSerifSC.ttf", OUT / "NotoSerifSC-Subset.ttf", text)
    make_subset(SRC / "CormorantGaramond.ttf", OUT / "CormorantGaramond-Subset.ttf", latin)
    make_subset(SRC / "CormorantGaramond-Italic.ttf", OUT / "CormorantGaramond-Italic-Subset.ttf", latin)


if __name__ == "__main__":
    main()
