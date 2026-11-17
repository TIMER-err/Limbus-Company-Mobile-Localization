#!/usr/bin/env python3
"""Review missing mobile Han glyphs; proposed substitutions always require human approval.

Scanning uses only the standard library. Visual ranking additionally needs Pillow,
fontTools and a local CJK font (including TTC collections, face zero).
"""

import argparse
import html
import json
from pathlib import Path, PurePosixPath
import sys
import zipfile


ROOT = Path(__file__).resolve().parent.parent
CANDIDATE_COUNT = 5


def is_han(character):
    code = ord(character)
    return (
        0x3400 <= code <= 0x4DBF
        or 0x4E00 <= code <= 0x9FFF
        or 0xF900 <= code <= 0xFAFF
        or 0x20000 <= code <= 0x2A6DF
        or 0x2A700 <= code <= 0x2B73F
        or 0x2B740 <= code <= 0x2B81F
        or 0x2B820 <= code <= 0x2CEAF
        or 0x2CEB0 <= code <= 0x2EBEF
        or 0x2EBF0 <= code <= 0x2EE5F
        or 0x2F800 <= code <= 0x2FA1F
        or 0x30000 <= code <= 0x3134F
        or 0x31350 <= code <= 0x323AF
        or 0x323B0 <= code <= 0x3347F
        or code == 0x3007
    )


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON object key")
        result[key] = value
    return result


def invalid_constant(value):
    raise ValueError(f"invalid JSON constant: {value}")


def decode_json(raw):
    return json.loads(raw.decode("utf-8-sig"), object_pairs_hook=unique_object,
                      parse_constant=invalid_constant)


def strings_in(value):
    pending = [value]
    while pending:
        item = pending.pop()
        if isinstance(item, str):
            if any(0xD800 <= ord(char) <= 0xDFFF for char in item):
                raise ValueError("JSON contains an unpaired Unicode surrogate")
            yield item
        elif isinstance(item, dict):
            pending.extend(item.keys())
            pending.extend(item.values())
        elif isinstance(item, list):
            pending.extend(item)


def load_data(map_path, charset_path):
    charset = set()
    for line in charset_path.read_text(encoding="utf-8-sig").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            charset.update(line)
    if not charset:
        raise ValueError("reference charset is empty")
    mapping = decode_json(map_path.read_bytes())
    if not isinstance(mapping, dict):
        raise ValueError("glyph map must be a JSON object")
    for source, target in mapping.items():
        if (len(source) != 1 or not isinstance(target, str) or len(target) != 1
                or any(0xD800 <= ord(char) <= 0xDFFF for char in source + target)):
            raise ValueError("glyph map must contain single Unicode character keys and values")
        if target not in charset:
            raise ValueError(f"glyph map target U+{ord(target):04X} is not in reference charset")
    return mapping, charset


def scan_archive(path, mapping, charset):
    missing = {}
    file_count = 0
    with zipfile.ZipFile(path) as archive:
        members = sorted(archive.infolist(), key=lambda member: member.filename)
        for member in members:
            name = PurePosixPath(member.filename).name
            if member.is_dir() or not name.lower().endswith(".json") or name.lower() == "version.json":
                continue
            file_count += 1
            try:
                document = decode_json(archive.read(member))
                for text in strings_in(document):
                    for index, source in enumerate(text):
                        # Exactly one lookup: chained substitutions would disagree with the build.
                        target = mapping.get(source, source)
                        if not is_han(target) or target in charset:
                            continue
                        record = missing.setdefault(target, {"files": set(), "contexts": [], "count": 0})
                        record["files"].add(member.filename)
                        record["count"] += 1
                        context = (member.filename, text[max(0, index - 32):index + 33])
                        if len(record["contexts"]) < 3 and context not in record["contexts"]:
                            record["contexts"].append(context)
            except (ValueError, UnicodeError, RecursionError) as exc:
                raise ValueError(f"invalid translation JSON in {member.filename!r}: {exc}") from exc
    if not file_count:
        raise ValueError("archive contains no translation JSON files")
    return missing, file_count


def font_codepoints(path):
    """Use the font's actual Unicode cmap, not fallback/tofu rendering."""
    try:
        from fontTools.ttLib import TTFont, TTLibError
    except ImportError as exc:
        raise ValueError("visual candidates require fontTools; install python3-fonttools or fonttools") from exc
    try:
        with TTFont(path, fontNumber=0, lazy=True) as font:
            return {code for code, glyph in (font.getBestCmap() or {}).items()
                    if glyph != ".notdef"}
    except (OSError, TTLibError) as exc:
        raise ValueError(f"cannot read candidate font {str(path)!r}: {exc}") from exc


class GlyphRenderer:
    def __init__(self, path):
        try:
            from PIL import Image, ImageDraw, ImageFont
        except ImportError as exc:
            raise ValueError("visual candidates require Pillow; install python3-pil or Pillow") from exc
        self.Image = Image
        self.ImageDraw = ImageDraw
        try:
            self.coverage = font_codepoints(path)
            self.font = ImageFont.truetype(str(path), 48, index=0)
        except (OSError, ValueError, IndexError) as exc:
            raise ValueError(f"cannot load candidate font {str(path)!r}: {exc}") from exc
        self.tofu = bytes(self.font.getmask(chr(0x10FFFF), mode="L"))

    def render(self, character):
        if ord(character) not in self.coverage:
            return None
        mask = bytes(self.font.getmask(character, mode="L"))
        if not any(mask) or mask == self.tofu:
            return None
        box = self.font.getbbox(character)
        width, height = box[2] - box[0], box[3] - box[1]
        if width <= 0 or height <= 0:
            return None
        image = self.Image.new("L", (width, height))
        self.ImageDraw.Draw(image).text((-box[0], -box[1]), character, font=self.font, fill=255)
        # A fixed normalized grid compares shape, not language or meaning.
        image = image.resize((24, 24), self.Image.Resampling.LANCZOS)
        return image.tobytes()


def generate_candidates(missing, charset, renderer):
    # Render each eligible target only once for the entire archive.
    targets = []
    for character in sorted(charset):
        if is_han(character):
            bitmap = renderer.render(character)
            if bitmap is not None:
                targets.append((character, bitmap))
    result = {}
    for source in sorted(missing):
        bitmap = renderer.render(source)
        if bitmap is None:
            result[source] = []
            continue
        scores = [
            (sum(abs(left - right) for left, right in zip(bitmap, target)), character)
            for character, target in targets if character != source
        ]
        result[source] = [(character, score / (len(bitmap) * 255))
                          for score, character in sorted(scores)[:CANDIDATE_COUNT]]
    return result


def literal(value):
    # Archive-controlled text is inert even with HTML, Markdown, bidi and newlines.
    value = "".join(char if char.isprintable() else f"\\u{ord(char):04x}" for char in value)
    return "<pre>" + html.escape(value, quote=True) + "</pre>"


def make_report(missing, file_count, tag, candidates):
    lines = ["# 移动端缺字审核", "", "上游版本：", literal(tag or "未指定"), "",
             f"已扫描 {file_count} 个译文 JSON 文件，发现 {len(missing)} 个缺字。", ""]
    if not missing:
        lines.extend(["应用现有映射一次后，未发现字库清单以外的汉字。", ""])
        return "\n".join(lines)
    lines.extend(["**发布已暂停，等待人工审核。**",
                  "以下候选仅按字形相似度排序，不代表语义等价。请逐项确认并按需修改映射，",
                  "合并后才会重新检查并决定是否发布。", "",
                  "分数为归一化位图差异，越小越相似。", ""])
    for character in sorted(missing):
        record = missing[character]
        lines.extend([f"## U+{ord(character):04X}", literal(character),
                      f"出现次数：{record['count']}", "", "来源文件："])
        lines.extend(literal(name) for name in sorted(record["files"]))
        lines.extend(["", "原文上下文（最多三处，每处最多 65 个字符）："])
        for name, context in record["contexts"]:
            lines.extend([literal(name), literal(context)])
        lines.extend(["", "候选字形："])
        if candidates is None:
            lines.append("未生成候选：本次只扫描，未指定候选字体。")
        elif not candidates[character]:
            lines.append("无候选：候选字体无法渲染原字，或没有可用的已确认目标字。")
        else:
            for rank, (target, score) in enumerate(candidates[character], 1):
                lines.extend([f"{rank}. U+{ord(target):04X}；差异 {score:.6f}", literal(target)])
        lines.append("")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--tag", default="")
    parser.add_argument("--glyph-map", type=Path, default=ROOT / "data/mobile-glyph-map.json")
    parser.add_argument("--charset", type=Path, default=ROOT / "data/mobile-font-charset.txt")
    parser.add_argument("--font", type=Path)
    parser.add_argument("--proposal", type=Path)
    args = parser.parse_args(argv)
    try:
        outputs = [args.report] + ([args.proposal] if args.proposal else [])
        inputs = [args.archive, args.glyph_map, args.charset] + ([args.font] if args.font else [])
        if (len({path.resolve() for path in outputs}) != len(outputs)
                or {path.resolve() for path in outputs} & {path.resolve() for path in inputs}):
            raise ValueError("report and proposal must be distinct from each other and all inputs")
        mapping, charset = load_data(args.glyph_map, args.charset)
        missing, file_count = scan_archive(args.archive, mapping, charset)
        candidates = generate_candidates(missing, charset, GlyphRenderer(args.font)) if args.font else None
        report = make_report(missing, file_count, args.tag, candidates)
        proposal = dict(mapping)
        if candidates:
            for source, ranked in candidates.items():
                if ranked and source not in proposal:
                    proposal[source] = ranked[0][0]
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(report, encoding="utf-8")
        if args.proposal:
            args.proposal.parent.mkdir(parents=True, exist_ok=True)
            args.proposal.write_text(json.dumps(proposal, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                                     encoding="utf-8")
        print(f"Scanned {file_count} JSON files; {len(missing)} missing Han characters.")
        return 2 if missing else 0
    except (OSError, ValueError, zipfile.BadZipFile, RuntimeError, RecursionError) as exc:
        print(f"Glyph scan failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
