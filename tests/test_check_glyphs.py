"""Consumer-visible glyph review regressions; no network, Pillow or CJK font required."""

from collections import Counter
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check-glyphs.py"
SPEC = importlib.util.spec_from_file_location("check_glyphs", SCRIPT)
glyphs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(glyphs)


class FakeRenderer:
    def __init__(self, bitmaps):
        self.bitmaps = bitmaps
        self.calls = Counter()

    def render(self, character):
        self.calls[character] += 1
        return self.bitmaps.get(character)


class GlyphReviewTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.archive = self.root / "translation.zip"
        self.mapping = self.root / "map.json"
        self.charset = self.root / "charset.txt"
        self.report = self.root / "review.md"
        self.proposal = self.root / "proposal.json"
        self.set_data({}, "一二三漢")

    def set_data(self, mapping, charset):
        self.mapping.write_text(json.dumps(mapping, ensure_ascii=False), encoding="utf-8")
        self.charset.write_text("# Reference coverage\n\n" + charset + "\n", encoding="utf-8")

    def write_archive(self, members):
        with zipfile.ZipFile(self.archive, "w") as archive:
            for name, value in members.items():
                archive.writestr(name, value)

    def scan(self):
        mapping, charset = glyphs.load_data(self.mapping, self.charset)
        return glyphs.scan_archive(self.archive, mapping, charset)

    def run_cli(self, *extra):
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return glyphs.main([
                str(self.archive), "--report", str(self.report),
                "--glyph-map", str(self.mapping), "--charset", str(self.charset), *extra,
            ])

    def test_whole_archive_aggregates_every_missing_character_and_filename(self):
        self.write_archive({
            "first.json": json.dumps({"text": "缺缺漢"}),
            "nested/last.JSON": json.dumps(["字缺", {"末": "尾"}]),
            "version.json": "not JSON",
            "nested/version.json": "not JSON",
            "ignored.txt": "略",
        })
        missing, count = self.scan()
        self.assertEqual(count, 2)
        self.assertEqual(set(missing), set("缺字末尾"))
        self.assertEqual(missing["缺"]["count"], 3)
        self.assertEqual(missing["缺"]["files"], {"first.json", "nested/last.JSON"})
        self.assertEqual(self.run_cli(), 2)
        report = self.report.read_text(encoding="utf-8")
        for character in missing:
            self.assertIn(f"U+{ord(character):04X}", report)
        self.assertIn("first.json", report)
        self.assertIn("nested/last.JSON", report)

    def test_decodes_escaped_nested_keys_values_and_supplementary_ideographs(self):
        self.write_archive({"nested.json": br'{"outer":[{"\u7f3a":["\u5b57",{"x":"\ud840\udc00\ud888\udc00"}]}]}'})
        missing, _ = self.scan()
        self.assertEqual(set(missing), {"缺", "字", "𠀀", chr(0x32000)})
        self.assertEqual(self.run_cli(), 2)
        self.assertIn("U+20000", self.report.read_text(encoding="utf-8"))

    def test_existing_map_is_applied_once_and_never_overridden(self):
        self.set_data({"缺": "一", "一": "二"}, "一二三漢")
        self.write_archive({"text.json": json.dumps(["缺", "字"])})
        renderer = FakeRenderer({"一": (0,), "二": (10,), "三": (20,), "字": (0,)})
        with patch.object(glyphs, "GlyphRenderer", return_value=renderer):
            self.assertEqual(self.run_cli("--font", "unused.ttf", "--proposal", str(self.proposal)), 2)
        proposed = json.loads(self.proposal.read_text(encoding="utf-8"))
        self.assertEqual(proposed, {"缺": "一", "一": "二", "字": "一"})
        self.assertEqual(json.loads(self.mapping.read_text(encoding="utf-8")), {"缺": "一", "一": "二"})
        # A chained lookup would incorrectly mark 一 as supported through 二.
        missing, _ = glyphs.scan_archive(self.archive, {"缺": "一", "一": "二"}, {"二"})
        self.assertIn("一", missing)
        self.assertNotIn("缺", missing)

    def test_clean_scan_and_scan_only_proposal_preserve_existing_map(self):
        self.set_data({"缺": "一"}, "一二")
        self.write_archive({"clean.json": json.dumps("缺二 ASCII")})
        self.assertEqual(self.run_cli("--proposal", str(self.proposal)), 0)
        self.assertEqual(json.loads(self.proposal.read_text(encoding="utf-8")), {"缺": "一"})
        self.write_archive({"missing.json": json.dumps("缺字")})
        self.assertEqual(self.run_cli("--proposal", str(self.proposal)), 2)
        self.assertEqual(json.loads(self.proposal.read_text(encoding="utf-8")), {"缺": "一"})

    def test_invalid_map_shapes_and_unused_unsupported_targets_fail(self):
        self.write_archive({"valid.json": '"漢"'})
        for value in ([], {"缺缺": "一"}, {"缺": "一二"}, {"缺": 1},
                      {"缺": "字"}, {"缺": "x"}, {"缺": "𠀀"}, {"缺": "\ud800"}):
            with self.subTest(value=repr(value)):
                self.mapping.write_text(json.dumps(value), encoding="utf-8")
                self.assertEqual(self.run_cli(), 1)
        self.mapping.write_text('{"缺":"一","缺":"二"}', encoding="utf-8")
        self.assertEqual(self.run_cli(), 1)
        self.mapping.write_text("{}", encoding="utf-8")
        self.charset.write_text("# Empty reference\n", encoding="utf-8")
        self.assertEqual(self.run_cli(), 1)

    def test_malformed_archive_or_any_translation_json_fails_not_clean(self):
        for raw in (b'{"text":', b'"\xff"', br'"\ud800"', b'{"x":NaN}', b'{"x":1,"x":2}'):
            with self.subTest(raw=raw):
                self.write_archive({"valid.json": '"漢"', "last.json": raw})
                self.assertEqual(self.run_cli(), 1)
        self.archive.write_bytes(b"not a zip")
        self.assertEqual(self.run_cli(), 1)
        self.write_archive({"version.json": "{}", "readme.txt": "ignored"})
        self.assertEqual(self.run_cli(), 1)

    def test_context_is_bounded_and_archive_text_is_inert(self):
        filename = "<img src=x onerror=alert(1)>.json"
        hostile = "<script>alert(1)</script>\n[click](https://example.com)\u202e" + "缺" * 1000
        self.write_archive({filename: json.dumps(hostile)})
        missing, count = self.scan()
        self.assertLessEqual(len(missing["缺"]["contexts"]), 3)
        for _, context in missing["缺"]["contexts"]:
            self.assertLessEqual(len(context), 65)
        report = glyphs.make_report(missing, count, "</pre><script>bad</script>", None)
        self.assertNotIn("<script>", report)
        self.assertNotIn("<img ", report)
        self.assertIn("&lt;script&gt;", report)
        self.assertEqual(glyphs.literal("[click](https://example.com)\n\u202e"),
                         "<pre>[click](https://example.com)\\u000a\\u202e</pre>")

    def test_candidates_are_supported_han_distinct_and_deterministic(self):
        renderer = FakeRenderer({
            "缺": (100, 100), "字": (100, 100), "一": (90, 100), "二": (100, 90),
            "三": (0, 0), "x": (100, 100), "外": (100, 100),
        })
        candidates = glyphs.generate_candidates({"缺": {}, "字": {}}, set("一二三漢x"), renderer)
        for ranked in candidates.values():
            self.assertEqual([character for character, _ in ranked], ["一", "二", "三"])
            self.assertTrue(all(character in "一二三" for character, _ in ranked))
        for character in "一二三漢":
            self.assertEqual(renderer.calls[character], 1)
        self.assertEqual(renderer.calls["x"], 0)
        self.assertEqual(renderer.calls["外"], 0)
        second = glyphs.generate_candidates({"字": {}, "缺": {}}, set("x漢三二一"), renderer)
        self.assertEqual(candidates, second)
        same = glyphs.generate_candidates({"一": {}}, {"一", "二"}, renderer)
        self.assertEqual([character for character, _ in same["一"]], ["二"])

    def test_unrenderable_source_has_no_placeholder_mapping(self):
        self.write_archive({"text.json": json.dumps("缺𠀀")})
        renderer = FakeRenderer({"缺": (0,), "一": (0,), "二": (5,)})
        with patch.object(glyphs, "GlyphRenderer", return_value=renderer):
            self.assertEqual(self.run_cli("--font", "unused.ttf", "--proposal", str(self.proposal)), 2)
        proposed = json.loads(self.proposal.read_text(encoding="utf-8"))
        self.assertEqual(proposed, {"缺": "一"})
        self.assertNotIn("𠀀", proposed)
        self.assertIn("U+20000", self.report.read_text(encoding="utf-8"))


    def test_renderer_rejects_missing_tofu_and_blank_glyphs(self):
        renderer = glyphs.GlyphRenderer.__new__(glyphs.GlyphRenderer)
        renderer.coverage = {ord("一"), ord("二")}
        renderer.tofu = bytes((10, 20))

        class Font:
            def getmask(self, character, mode):
                return (10, 20) if character == "一" else (0, 0)

        renderer.font = Font()
        self.assertIsNone(renderer.render("缺"))
        self.assertIsNone(renderer.render("一"))
        self.assertIsNone(renderer.render("二"))

    def test_outputs_cannot_overwrite_inputs_or_each_other(self):
        self.write_archive({"text.json": '"漢"'})
        self.assertEqual(self.run_cli("--proposal", str(self.mapping)), 1)
        self.assertEqual(self.run_cli("--proposal", str(self.report)), 1)
        self.assertEqual(json.loads(self.mapping.read_text(encoding="utf-8")), {})


if __name__ == "__main__":
    unittest.main()
