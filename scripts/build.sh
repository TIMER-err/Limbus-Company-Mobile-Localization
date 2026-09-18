#!/bin/sh

set -eu

REFERENCE_REPO="${REFERENCE_REPO:-ghcruise/LimbusCompany-IOS-Localization}"
REFERENCE_TAG="${REFERENCE_TAG:-v1.114.0-alpha}"
SOURCE_REPO="${SOURCE_REPO:-haool871/Limbus-Company-Chapter-10-Week-1-Chinese-Localization-Share}"
SOURCE_REF="${SOURCE_REF:-a05c0b00c74c3b4c9c39a7e501d0012bbea317d7}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/dist}"
PYTHON="${PYTHON:-python3}"

for command_name in git curl "$PYTHON"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '缺少构建依赖：%s\n' "$command_name" >&2
        exit 1
    fi
done

if [ "$REFERENCE_TAG" = "latest" ]; then
    release_url="https://github.com/$REFERENCE_REPO/releases/latest/download"
else
    release_url="https://github.com/$REFERENCE_REPO/releases/download/$REFERENCE_TAG"
fi

if [ -n "${TMPDIR:-}" ]; then
    tmp_base="$TMPDIR"
elif [ -n "${PREFIX:-}" ] && [ -d "$PREFIX/tmp" ]; then
    tmp_base="$PREFIX/tmp"
else
    tmp_base="/tmp"
fi
build_dir=$(mktemp -d "$tmp_base/limbus-mobile-pack.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

printf '下载参考资源：%s\n' "$REFERENCE_REPO ($REFERENCE_TAG)"
curl -fsSL --retry 3 --retry-delay 1 \
    -o "$build_dir/base.zip" "$release_url/localize_jp.zip"
curl -fsSL --retry 3 --retry-delay 1 \
    -o "$build_dir/manifest.json" "$release_url/manifest.json"

printf '获取增量资源：%s\n' "$SOURCE_REPO ($SOURCE_REF)"
git init -q "$build_dir/source"
git -C "$build_dir/source" remote add origin "https://github.com/$SOURCE_REPO.git"
git -C "$build_dir/source" fetch -q --depth 1 origin "$SOURCE_REF"
git -C "$build_dir/source" checkout -q --detach FETCH_HEAD

mkdir -p "$build_dir/output"

"$PYTHON" - "$build_dir/base.zip" \
    "$build_dir/source/patch" \
    "$build_dir/manifest.json" \
    "$build_dir/output/localize_jp.zip" <<'PY'
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import zipfile

base_zip = Path(sys.argv[1])
patch_dir = Path(sys.argv[2])
manifest = Path(sys.argv[3])
output_zip = Path(sys.argv[4])

if not patch_dir.is_dir():
    raise SystemExit(f"找不到上游 patch 目录：{patch_dir}")

with manifest.open(encoding="utf-8-sig") as stream:
    json.load(stream)

with tempfile.TemporaryDirectory(prefix="limbus-stage-") as stage_name:
    stage = Path(stage_name)

    with zipfile.ZipFile(base_zip) as archive:
        bad_member = archive.testzip()
        if bad_member is not None:
            raise SystemExit(f"参考 ZIP 校验失败：{bad_member}")

        stage_resolved = stage.resolve()
        for member in archive.infolist():
            target = (stage / member.filename).resolve()
            if stage_resolved not in target.parents and target != stage_resolved:
                raise SystemExit(f"参考 ZIP 包含不安全路径：{member.filename}")
        archive.extractall(stage)

    resource_root = stage / "LocalizeTemp_jp"
    if not resource_root.is_dir():
        raise SystemExit("参考 ZIP 缺少 LocalizeTemp_jp 目录")

    patch_files = sorted(path for path in patch_dir.rglob("*") if path.is_file())
    if not patch_files:
        raise SystemExit("上游 patch 目录中没有资源文件")

    non_json = [path for path in patch_files if path.suffix.lower() != ".json"]
    if non_json:
        raise SystemExit(f"patch 中存在非 JSON 文件：{non_json[0]}")

    expected_hashes = {}
    for source in patch_files:
        relative = source.relative_to(patch_dir)
        destination_relative = relative.parent / f"JP_{relative.name}"
        destination = resource_root / destination_relative

        if not destination.is_file():
            raise SystemExit(
                f"参考包中找不到增量资源的目标位置：{destination_relative.as_posix()}"
            )

        with source.open(encoding="utf-8-sig") as stream:
            json.load(stream)

        shutil.copyfile(source, destination)
        expected_hashes[
            f"LocalizeTemp_jp/{destination_relative.as_posix()}"
        ] = hashlib.sha256(source.read_bytes()).digest()

    resource_files = sorted(path for path in resource_root.rglob("*") if path.is_file())
    for resource in resource_files:
        if resource.suffix.lower() == ".json":
            with resource.open(encoding="utf-8-sig") as stream:
                json.load(stream)

    with zipfile.ZipFile(
        output_zip,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
    ) as archive:
        for resource in resource_files:
            name = resource.relative_to(stage).as_posix()
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            info.flag_bits |= 0x800
            archive.writestr(info, resource.read_bytes(), compresslevel=9)

    with zipfile.ZipFile(output_zip) as archive:
        bad_member = archive.testzip()
        if bad_member is not None:
            raise SystemExit(f"生成的 ZIP 校验失败：{bad_member}")

        names = archive.namelist()
        if len(names) != len(resource_files):
            raise SystemExit("生成的 ZIP 文件数量不正确")

        for name, expected_hash in expected_hashes.items():
            actual_hash = hashlib.sha256(archive.read(name)).digest()
            if actual_hash != expected_hash:
                raise SystemExit(f"覆盖文件校验失败：{name}")

print(f"资源文件：{len(resource_files)}")
print(f"增量覆盖：{len(patch_files)}")
PY

cp "$build_dir/manifest.json" "$build_dir/output/manifest.json"
chmod 0644 "$build_dir/output/localize_jp.zip" "$build_dir/output/manifest.json"

mkdir -p "$OUTPUT_DIR"
mv "$build_dir/output/localize_jp.zip" "$OUTPUT_DIR/localize_jp.zip"
mv "$build_dir/output/manifest.json" "$OUTPUT_DIR/manifest.json"

printf '构建完成：%s\n' "$OUTPUT_DIR"
"$PYTHON" - "$OUTPUT_DIR/localize_jp.zip" "$OUTPUT_DIR/manifest.json" <<'PY'
import hashlib
from pathlib import Path
import sys

for name in sys.argv[1:]:
    path = Path(name)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    print(f"{digest}  {path.name}")
PY
