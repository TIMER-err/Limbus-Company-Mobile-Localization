"""Exercise the production packer with isolated resource archives, without downloads."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile


BUILD = Path(__file__).resolve().parents[1] / "scripts/build.sh"
PACK_CODE = BUILD.read_text(encoding="utf-8").split(
    '"$PYTHON" - "$build_dir/base.zip"', 1
)[1].split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]


class BuildGlyphTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.base = self.root / "base.zip"
        self.translation = self.root / "translation.zip"
        self.manifest = self.root / "manifest.json"
        self.mapping = self.root / "map.json"
        self.charset = self.root / "charset.txt"
        self.output = self.root / "output.zip"
        resources = {
            "JP_Test.json": b'{"dataList": []}',
            "JP_ScenarioModelCodes-AutoCreated.json": b'{"dataList": []}',
        }
        with zipfile.ZipFile(self.base, "w") as archive:
            for name, raw in resources.items():
                archive.writestr("LocalizeTemp_jp/" + name, raw)
        self.manifest.write_text(json.dumps({"Files": {
            "Assets/Resources_moved/Localize/jp/" + name: {
                "Hash": hashlib.md5(raw).hexdigest(), "Size": len(raw),
            } for name, raw in resources.items()
        }}), encoding="utf-8")
        self.charset.write_text("漢虹\n", encoding="utf-8")

    def pack(self, text, mapping, *, escaped=False):
        self.mapping.write_text(json.dumps(mapping, ensure_ascii=False), encoding="utf-8")
        with zipfile.ZipFile(self.translation, "w") as archive:
            archive.writestr("Test.json", json.dumps(
                {"dataList": [{"text": text}]}, ensure_ascii=escaped,
            ))
        return subprocess.run([
            sys.executable, "-", str(self.base), str(self.translation),
            str(self.manifest), str(self.mapping), str(self.charset),
            str(self.output), str(self.root / "output-manifest.json"),
        ], input=PACK_CODE, capture_output=True, text=True, timeout=15)

    def output_text(self):
        with zipfile.ZipFile(self.output) as archive:
            document = json.loads(archive.read("LocalizeTemp_jp/JP_Test.json"))
        return document["dataList"][0]["text"]

    def test_escaped_unicode_is_mapped_in_the_published_resource(self):
        result = self.pack("缺", {"缺": "漢"}, escaped=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.output_text(), "漢")

    def test_unmapped_supplementary_han_blocks_publication(self):
        result = self.pack("𫚉", {"缺": "漢"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("𫚉", result.stderr)
        self.assertFalse(self.output.exists())

    def test_reviewed_supplementary_mapping_can_be_published(self):
        result = self.pack("𫚉", {"𫚉": "虹"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.output_text(), "虹")


if __name__ == "__main__":
    unittest.main()
