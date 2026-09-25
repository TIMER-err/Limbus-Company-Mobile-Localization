#!/usr/bin/env python3
"""从公开镜像的 XAPK 中提取官方资源版本目录，只用 HTTP Range，不下载整包。

资源版本目录（形如 l20260924_<token>）并非由任何接口下发，而是烤在客户端的
Unity 资源里。XAPK 是一层 ZIP，内层 UnityDataAssetPack.apk 未压缩因而可直接
寻址，目录字符串位于其 assets/bin/Data/ 下某个几百字节的条目中。

用法：extract-version.py <xapk-url>
成功时向 stdout 输出 token=... 与 game_version=...，诊断信息走 stderr。
"""

import email.parser
import io
import re
import sys
import time
import urllib.parse
import urllib.request
import zipfile

USER_AGENT = "Mozilla/5.0 (Linux; Android 12)"
TOKEN = re.compile(rb"downloadcommon\.limbuscompanycdn\.org/(l\d{8}_[A-Za-z0-9_-]+)")
GAME_VERSION = re.compile(r"(?<![\d.])(\d+\.\d+\.\d+)(?![\d.])")
# 目录字符串所在的条目只有几百字节，放宽到 2KB 足够覆盖。
MAX_ENTRY_SIZE = 2048
# 相隔小于此值的区间合并，用更少的请求换少量多余流量。
MERGE_GAP = 65536
RANGES_PER_REQUEST = 20
ATTEMPTS = 4
METADATA_ATTEMPTS = 2

stats = {"requests": 0, "bytes": 0}


def log(message):
    print(message, file=sys.stderr)


def parse_game_version(*sources):
    """从响应头或重定向 URL 中提取客户端版本号。"""
    for source in sources:
        if not source:
            continue
        match = GAME_VERSION.search(urllib.parse.unquote_plus(source))
        if match:
            return match.group(1)
    return ""


def fetch_metadata(url):
    """用单字节 Range GET 读取远程包大小与版本，避开镜像对 HEAD 的限制。"""
    for attempt in range(1, METADATA_ATTEMPTS + 1):
        try:
            request = urllib.request.Request(
                url,
                headers={"User-Agent": USER_AGENT, "Range": "bytes=0-0"},
            )
            with urllib.request.urlopen(request, timeout=30) as response:
                content_range = response.headers.get("Content-Range", "")
                if "/" in content_range:
                    total = int(content_range.rsplit("/", 1)[1])
                else:
                    total = int(response.headers["Content-Length"])
                disposition = response.headers.get("Content-Disposition", "")
                final_url = response.geturl()
            return total, parse_game_version(disposition, final_url)
        except Exception as exc:
            if attempt == METADATA_ATTEMPTS:
                raise
            log(f"  元数据请求失败（{type(exc).__name__}），{2 * attempt} 秒后重试")
            time.sleep(2 * attempt)


def fetch(url, ranges):
    """取若干字节区间，返回 [(start, data), ...]。多区间走 multipart/byteranges。"""
    spec = ",".join(f"{start}-{end - 1}" for start, end in ranges)
    for attempt in range(1, ATTEMPTS + 1):
        try:
            request = urllib.request.Request(
                url, headers={"User-Agent": USER_AGENT, "Range": f"bytes={spec}"}
            )
            with urllib.request.urlopen(request, timeout=120) as response:
                content_type = response.headers.get("Content-Type", "")
                body = response.read()
            break
        except Exception as exc:
            if attempt == ATTEMPTS:
                raise
            log(f"  区间请求失败（{type(exc).__name__}），{2 * attempt} 秒后重试")
            time.sleep(2 * attempt)

    stats["requests"] += 1
    stats["bytes"] += len(body)

    if "multipart/byteranges" not in content_type:
        return [(ranges[0][0], body)]

    boundary = content_type.split("boundary=", 1)[1].strip('"').encode()
    parts = []
    for chunk in body.split(b"--" + boundary):
        head, _, payload = chunk.partition(b"\r\n\r\n")
        if not payload:
            continue
        headers = email.parser.BytesParser().parsebytes(
            head.lstrip(b"\r\n") + b"\r\n\r\n"
        )
        content_range = headers.get("Content-Range")
        if content_range:
            start = int(content_range.split()[1].split("-")[0])
            parts.append((start, payload.rstrip(b"\r\n")))
    return parts


class RemoteSlice(io.RawIOBase):
    """把远程文件的 [base, base+size) 一段当成可 seek 的只读流。"""

    def __init__(self, url, size, base=0):
        self.url = url
        self.size = size
        self.base = base
        self.pos = 0

    def readable(self):
        return True

    def seekable(self):
        return True

    def seek(self, offset, whence=0):
        origin = {0: 0, 1: self.pos, 2: self.size}[whence]
        self.pos = max(0, min(self.size, origin + offset))
        return self.pos

    def tell(self):
        return self.pos

    def readinto(self, buf):
        count = min(len(buf), self.size - self.pos)
        if count <= 0:
            return 0
        start = self.base + self.pos
        data = fetch(self.url, [(start, start + count)])[0][1][:count]
        buf[: len(data)] = data
        self.pos += len(data)
        return len(data)


def open_remote_zip(url, size, base=0):
    return zipfile.ZipFile(io.BufferedReader(RemoteSlice(url, size, base), 1 << 16))


def entry_data_offset(archive, info):
    """跳过本地文件头，得到条目数据相对该 ZIP 起点的偏移。"""
    archive.fp.seek(info.header_offset)
    header = archive.fp.read(30)
    name_length = int.from_bytes(header[26:28], "little")
    extra_length = int.from_bytes(header[28:30], "little")
    return info.header_offset + 30 + name_length + extra_length


def extract(url):
    total, game_version = fetch_metadata(url)
    log(f"  远程包 {total:,} 字节" + (f"，客户端 {game_version}" if game_version else ""))

    outer = open_remote_zip(url, total)
    try:
        inner_info = next(
            info for info in outer.infolist()
            if "UnityDataAssetPack.apk" in info.filename
        )
    except StopIteration:
        raise SystemExit("XAPK 中没有 UnityDataAssetPack.apk")
    if inner_info.compress_type != zipfile.ZIP_STORED:
        raise SystemExit("内层 APK 被压缩，无法嵌套寻址")

    inner_base = entry_data_offset(outer, inner_info)
    inner = open_remote_zip(url, inner_info.file_size, inner_base)
    candidates = sorted(
        (
            info for info in inner.infolist()
            if info.filename.startswith("assets/bin/Data/")
            and not info.is_dir()
            and info.compress_size <= MAX_ENTRY_SIZE
        ),
        key=lambda info: info.header_offset,
    )
    if not candidates:
        raise SystemExit("内层 APK 中没有候选条目")

    limit = inner_base + inner_info.file_size
    spans = []
    for info in candidates:
        start = inner_base + info.header_offset
        # 本地文件头长度不定，留出余量；末尾必须钳制，越界服务端会回 416。
        end = min(start + 140 + info.compress_size, limit, total)
        if spans and start - spans[-1][1] <= MERGE_GAP:
            spans[-1][1] = max(spans[-1][1], end)
        else:
            spans.append([start, end])
    log(f"  候选条目 {len(candidates)} 个，合并为 {len(spans)} 段，"
        f"合计 {sum(end - start for start, end in spans):,} 字节")

    for index in range(0, len(spans), RANGES_PER_REQUEST):
        batch = [(start, end) for start, end in spans[index:index + RANGES_PER_REQUEST]]
        for _, data in fetch(url, batch):
            match = TOKEN.search(data)
            if match:
                log(f"  {stats['requests']} 个请求，传输 {stats['bytes']:,} 字节"
                    f"（整包的 {100 * stats['bytes'] / total:.4f}%）")
                return match.group(1).decode(), game_version
    raise SystemExit("候选条目中没有找到资源版本目录")


def main(argv):
    version_only = len(argv) == 3 and argv[1] == "--game-version"
    if not version_only and len(argv) != 2:
        raise SystemExit(f"用法：{argv[0]} [--game-version] <xapk-url>")
    try:
        if version_only:
            _, game_version = fetch_metadata(argv[2])
            if not game_version:
                raise SystemExit("XAPK 响应中没有客户端版本号")
            print(game_version)
            return 0
        token, game_version = extract(argv[1])
    except SystemExit:
        raise
    except Exception as exc:
        # 网络与镜像改版都会走到这里，只报一行，别把调用方的输出淹掉。
        raise SystemExit(f"XAPK 提取失败：{type(exc).__name__}: {exc}")
    print(f"token={token}")
    print(f"game_version={game_version}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
