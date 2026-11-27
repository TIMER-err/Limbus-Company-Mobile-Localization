"""Run the complete build against isolated HTTP resources, without external downloads."""

import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from urllib.parse import urlsplit
import zipfile


ROOT = Path(__file__).resolve().parents[1]
CURL = shutil.which("curl")


def make_zip(files):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, raw in files.items():
            archive.writestr(name, raw)
    return buffer.getvalue()


@unittest.skipUnless(CURL, "the build requires curl")
class BuildDownloadTests(unittest.TestCase):
    def test_current_version_archive_and_manifest_are_used_from_separate_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            resource_prefix = "/l20261126_fixture"
            resources = {
                "JP_Test.json": json.dumps({"dataList": [{"text": "日本語"}]}, ensure_ascii=False).encode(),
                "JP_ScenarioModelCodes-AutoCreated.json": b'{"dataList": []}',
            }
            manifest = json.dumps({"Files": {
                "Assets/Resources_moved/Localize/jp/" + name: {
                    "Hash": hashlib.md5(raw).hexdigest(), "Size": len(raw),
                } for name, raw in resources.items()
            }}).encode()
            responses = {
                resource_prefix + "/Assets/Resources_moved/Localize/localize_jp.zip": make_zip({
                    "LocalizeTemp_jp/" + name: raw for name, raw in resources.items()
                }),
                resource_prefix + "/Assets/LocalizePatch/LocalizePatchInfo.json": manifest,
                resource_prefix + "/Assets/LocalizePatch/LocalizePatchInfo.hash": hashlib.md5(manifest).hexdigest().encode(),
                "/translation.zip": make_zip({
                    "Test.json": json.dumps({"dataList": [{"text": "缺"}]}, ensure_ascii=False).encode(),
                }),
            }

            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *args):
                    pass

                def do_GET(self):
                    payload = responses.get(urlsplit(self.path).path)
                    if payload is None:
                        self.send_error(404)
                        return
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)

            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            worker = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.01), daemon=True)
            worker.start()
            try:
                origin = f"http://127.0.0.1:{server.server_port}"
                mapping = root / "map.json"
                charset = root / "charset.txt"
                mapping.write_text('{"缺": "漢"}', encoding="utf-8")
                charset.write_text("漢\n", encoding="utf-8")
                commands = root / "bin"
                commands.mkdir()
                curl = commands / "curl"
                # Rewrite only the upstream transport to localhost; real curl performs all HTTP requests.
                curl.write_text(
                    f"#!{sys.executable}\n"
                    "import os, sys\n"
                    "args = sys.argv[1:]\n"
                    "for index, argument in enumerate(args):\n"
                    "    if argument == 'https://github.com/fixture/translations/releases/download/fixture/LimbusLocalize_fixture.zip':\n"
                    f"        args[index] = {origin + '/translation.zip'!r}\n"
                    "    elif argument.startswith('https://'):\n"
                    "        raise SystemExit('unexpected external request in isolated build')\n"
                    f"os.execv({CURL!r}, [{CURL!r}, '-q', *args])\n",
                    encoding="utf-8",
                )
                curl.chmod(0o755)
                for trailing_slash in ("", "/"):
                    with self.subTest(trailing_slash=trailing_slash):
                        output = root / ("with-slash" if trailing_slash else "without-slash")
                        environment = dict(
                            os.environ, LOCALIZE_REPO="fixture/translations", LOCALIZE_TAG="fixture",
                            OFFICIAL_PATCH_URL=origin + resource_prefix + "/Assets/LocalizePatch" + trailing_slash,
                            OFFICIAL_XAPK_URL="", OFFICIAL_CDN_IP="", OUTPUT_DIR=str(output),
                            GLYPH_MAP=str(mapping), FONT_CHARSET=str(charset), PYTHON=sys.executable,
                            TMPDIR=str(root), PATH=str(commands) + os.pathsep + os.environ.get("PATH", ""),
                            no_proxy="127.0.0.1", NO_PROXY="127.0.0.1",
                        )
                        for name in ("CHECK_ONLY", "RESOLVE_ONLY", "EXPECTED_GAME_VERSION"):
                            environment.pop(name, None)
                        result = subprocess.run(["sh", str(ROOT / "scripts/build.sh")], cwd=ROOT,
                                                env=environment, capture_output=True, text=True, timeout=20)
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        with zipfile.ZipFile(output / "localize_jp.zip") as archive:
                            raw = archive.read("LocalizeTemp_jp/JP_Test.json")
                        self.assertEqual(json.loads(raw)["dataList"][0]["text"], "漢")
                        generated = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
                        entry = generated["Files"]["Assets/Resources_moved/Localize/jp/JP_Test.json"]
                        self.assertEqual(entry["Size"], len(raw))
                        self.assertEqual(entry["Hash"], hashlib.md5(raw.replace(b"\r\n", b"\n")).hexdigest())
            finally:
                server.shutdown()
                server.server_close()
                worker.join()


if __name__ == "__main__":
    unittest.main()
