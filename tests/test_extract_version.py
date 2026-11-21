"""Resolve versions from real ZIP fixtures over isolated HTTP Range responses."""

from contextlib import redirect_stdout
import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import unittest
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("extract_version", ROOT / "scripts/extract-version.py")
versions = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(versions)
PACKAGE = "com.ProjectMoon.LimbusCompany"


def package_bytes(version="1.119.1", token="l20261119_first", manifest=None):
    inner = io.BytesIO()
    with zipfile.ZipFile(inner, "w") as archive:
        archive.writestr("assets/bin/Data/config",
                         "https://downloadcommon.limbuscompanycdn.org/" + token + "/Assets/LocalizePatch")
    outer = io.BytesIO()
    with zipfile.ZipFile(outer, "w") as archive:
        archive.writestr("padding.bin", b"x" * 524288)
        archive.writestr("UnityDataAssetPack.apk", inner.getvalue())
        archive.writestr("manifest.json", json.dumps(manifest if manifest is not None else {
            "package_name": PACKAGE, "version_name": version,
        }))
    return outer.getvalue()


class VersionResolutionTests(unittest.TestCase):
    def setUp(self):
        self.packages = {
            "/opaque-a": package_bytes(),
            "/opaque-b": package_bytes("1.120.0", "l20261120_second"),
        }
        self.latest_requests = 0
        self.transferred = 0
        self.rotate = False
        self.deny_requests = False
        self.ignore_range = False
        self.disposition = ""
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                if owner.deny_requests:
                    self.send_response(403)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if self.path == "/latest":
                    owner.latest_requests += 1
                    target = "/opaque-b" if owner.rotate and owner.latest_requests > 1 else "/opaque-a"
                    self.send_response(302)
                    self.send_header("Location", target)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                data = owner.packages[self.path]
                match = re.fullmatch(r"bytes=(\d+)-(\d+)", self.headers.get("Range", ""))
                if match is None:
                    self.send_error(400)
                    return
                start, end = map(int, match.groups())
                body = data[start:end + 1]
                self.send_response(200 if owner.ignore_range else 206)
                if not owner.ignore_range:
                    self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
                self.send_header("Content-Length", str(len(body)))
                if owner.disposition:
                    self.send_header("Content-Disposition", owner.disposition)
                self.end_headers()
                self.wfile.write(body)
                owner.transferred += len(body)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.worker = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.worker.start()
        self.addCleanup(self.stop_server)
        self.proxy_environment = patch.dict(os.environ, {
            "http_proxy": "", "HTTP_PROXY": "", "https_proxy": "", "HTTPS_PROXY": "",
            "all_proxy": "", "ALL_PROXY": "", "no_proxy": "127.0.0.1", "NO_PROXY": "127.0.0.1",
        })
        self.proxy_environment.start()
        self.addCleanup(self.proxy_environment.stop)
        self.url = f"http://127.0.0.1:{self.server.server_port}/latest"

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.worker.join()

    def version_only(self):
        output = io.StringIO()
        with redirect_stdout(output):
            status = versions.main(["extract-version.py", "--game-version", self.url])
        self.assertEqual(status, 0)
        return output.getvalue().strip()

    def test_opaque_mirror_response_resolves_the_embedded_version_without_full_download(self):
        self.assertEqual(self.version_only(), "1.119.1")
        self.assertLess(self.transferred, len(self.packages["/opaque-a"]) // 4)

    def test_filename_version_cannot_override_the_package_version(self):
        self.disposition = 'attachment; filename="Limbus_9.9.9.xapk"'
        self.assertEqual(self.version_only(), "1.119.1")

    def test_changing_latest_keeps_resource_token_and_version_from_the_same_package(self):
        self.rotate = True
        token, version = versions.extract(self.url)
        self.assertEqual((token, version), ("l20261119_first", "1.119.1"))

    def test_invalid_manifest_never_falls_back_to_a_filename_version(self):
        self.disposition = 'attachment; filename="Limbus_1.119.1.xapk"'
        for manifest in ({"package_name": "another.app", "version_name": "1.119.1"},
                         {"package_name": PACKAGE},
                         {"package_name": PACKAGE, "version_name": 119},
                         {"package_name": PACKAGE, "version_name": "1.119.1/invalid"}):
            with self.subTest(manifest=manifest):
                self.packages["/opaque-a"] = package_bytes(manifest=manifest)
                with self.assertRaises(SystemExit):
                    self.version_only()

    def test_missing_or_oversized_manifest_is_rejected(self):
        for filename, content in (("other.json", "{}"), ("manifest.json", " " * 65537)):
            with self.subTest(filename=filename):
                data = io.BytesIO()
                with zipfile.ZipFile(data, "w") as archive:
                    archive.writestr(filename, content)
                with zipfile.ZipFile(io.BytesIO(data.getvalue())) as archive:
                    with self.assertRaises(ValueError):
                        versions.read_game_version(archive)

    def test_mirror_ignoring_range_is_rejected(self):
        self.ignore_range = True
        with patch.object(versions.time, "sleep"):
            with self.assertRaisesRegex(ValueError, "Range"):
                versions.fetch_metadata(self.url)

    def test_check_only_preserves_the_http_error_and_exits_unsuccessfully(self):
        self.deny_requests = True
        environment = dict(os.environ, CHECK_ONLY="1", LOCALIZE_TAG="2026111901",
                           OFFICIAL_XAPK_URL=self.url, PYTHON=sys.executable)
        result = subprocess.run(["sh", str(ROOT / "scripts/build.sh")], cwd=ROOT,
                                env=environment, capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("403", result.stderr)
        self.assertNotIn("game_version=", result.stdout)


if __name__ == "__main__":
    unittest.main()
