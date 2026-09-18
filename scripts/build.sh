#!/bin/sh

set -eu

REFERENCE_REPO="${REFERENCE_REPO:-ghcruise/LimbusCompany-IOS-Localization}"
REFERENCE_TAG="${REFERENCE_TAG:-v1.114.0-alpha}"
SOURCE_REPO="${SOURCE_REPO:-haool871/Limbus-Company-Chapter-10-Week-1-Chinese-Localization-Share}"
SOURCE_REF="${SOURCE_REF:-a05c0b00c74c3b4c9c39a7e501d0012bbea317d7}"
OFFICIAL_MANIFEST_URL="${OFFICIAL_MANIFEST_URL:-https://downloadcommon.limbuscompanycdn.org/l20260917_Xb6H-4JImhMTHdjlghDt/Assets/LocalizePatch/LocalizePatchInfo.json}"
OFFICIAL_MANIFEST_SHA256="${OFFICIAL_MANIFEST_SHA256:-b54880d24c6b5f85a572c7ad2f46e232899a3145cf0abba7e84499f1653545fc}"
OFFICIAL_CDN_IP="${OFFICIAL_CDN_IP:-}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/dist}"
PYTHON="${PYTHON:-python3}"
GLYPH_MAP="${GLYPH_MAP:-$PROJECT_ROOT/data/mobile-glyph-map.json}"

for command_name in git curl "$PYTHON"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '缺少构建依赖：%s\n' "$command_name" >&2
        exit 1
    fi
done

if [ ! -f "$GLYPH_MAP" ]; then
    printf '找不到移动端字形映射：%s\n' "$GLYPH_MAP" >&2
    exit 1
fi

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

printf '下载官方校验清单：%s\n' "$OFFICIAL_MANIFEST_URL"
if [ -n "$OFFICIAL_CDN_IP" ]; then
    curl -fsSL --retry 3 --retry-delay 1 \
        --resolve "downloadcommon.limbuscompanycdn.org:443:$OFFICIAL_CDN_IP" \
        -o "$build_dir/manifest.json" "$OFFICIAL_MANIFEST_URL"
else
    curl -fsSL --retry 3 --retry-delay 1 \
        -o "$build_dir/manifest.json" "$OFFICIAL_MANIFEST_URL"
fi

actual_manifest_sha256=$(
    "$PYTHON" - "$build_dir/manifest.json" <<'PY'
import hashlib
from pathlib import Path
import sys

print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)
if [ "$actual_manifest_sha256" != "$OFFICIAL_MANIFEST_SHA256" ]; then
    printf '官方校验清单 SHA-256 不匹配：%s\n' "$actual_manifest_sha256" >&2
    exit 1
fi

printf '获取增量资源：%s\n' "$SOURCE_REPO ($SOURCE_REF)"
git init -q "$build_dir/source"
git -C "$build_dir/source" remote add origin "https://github.com/$SOURCE_REPO.git"
git -C "$build_dir/source" fetch -q --depth 1 origin "$SOURCE_REF"
git -C "$build_dir/source" checkout -q --detach FETCH_HEAD

mkdir -p "$build_dir/output"

"$PYTHON" - "$build_dir/base.zip" \
    "$build_dir/source/patch" \
    "$build_dir/manifest.json" \
    "$GLYPH_MAP" \
    "$build_dir/output/localize_jp.zip" \
    "$build_dir/output/manifest.json" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import zipfile

base_zip = Path(sys.argv[1])
patch_dir = Path(sys.argv[2])
manifest = Path(sys.argv[3])
glyph_map_path = Path(sys.argv[4])
output_zip = Path(sys.argv[5])
output_manifest = Path(sys.argv[6])

if not patch_dir.is_dir():
    raise SystemExit(f"找不到上游 patch 目录：{patch_dir}")

with manifest.open(encoding="utf-8-sig") as stream:
    manifest_data = json.load(stream)

manifest_files = manifest_data.get("Files")
if not isinstance(manifest_files, dict):
    raise SystemExit("官方校验清单缺少 Files 字典")

with glyph_map_path.open(encoding="utf-8") as stream:
    glyph_map = json.load(stream)

if not isinstance(glyph_map, dict) or not glyph_map:
    raise SystemExit("移动端字形映射为空或格式错误")
if any(
    not isinstance(source, str)
    or not isinstance(target, str)
    or len(source) != 1
    or len(target) != 1
    for source, target in glyph_map.items()
):
    raise SystemExit("移动端字形映射必须由单字符键值组成")

translation_table = str.maketrans(glyph_map)


def is_cjk(character):
    return (
        "\u3400" <= character <= "\u9fff"
        or "\uf900" <= character <= "\ufaff"
    )

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

    resource_files = sorted(path for path in resource_root.rglob("*") if path.is_file())
    reference_characters = set()
    for resource in resource_files:
        if resource.suffix.lower() == ".json":
            text = resource.read_text(encoding="utf-8-sig")
            json.loads(text)
            reference_characters.update(text)

    patch_files = sorted(path for path in patch_dir.rglob("*") if path.is_file())
    if not patch_files:
        raise SystemExit("上游 patch 目录中没有资源文件")

    non_json = [path for path in patch_files if path.suffix.lower() != ".json"]
    if non_json:
        raise SystemExit(f"patch 中存在非 JSON 文件：{non_json[0]}")

    expected_hashes = {}
    replaced_characters = 0
    patched_destinations = []
    for source in patch_files:
        relative = source.relative_to(patch_dir)
        destination_relative = relative.parent / f"JP_{relative.name}"
        destination = resource_root / destination_relative

        if not destination.is_file():
            raise SystemExit(
                f"参考包中找不到增量资源的目标位置：{destination_relative.as_posix()}"
            )

        source_text = source.read_text(encoding="utf-8-sig")
        transformed_text = source_text.translate(translation_table)
        json.loads(transformed_text)

        unsupported = sorted(
            {
                character
                for character in transformed_text
                if is_cjk(character) and character not in reference_characters
            }
        )
        if unsupported:
            characters = "".join(unsupported)
            raise SystemExit(
                f"{relative.as_posix()} 仍包含参考字库中未出现的汉字：{characters}"
            )

        transformed_bytes = transformed_text.encode("utf-8")
        destination.write_bytes(transformed_bytes)
        patched_destinations.append((relative, destination))
        replaced_characters += sum(
            source_text.count(character) for character in glyph_map
        )
        expected_hashes[
            f"LocalizeTemp_jp/{destination_relative.as_posix()}"
        ] = hashlib.sha256(transformed_bytes).digest()

    scenario_model_path = resource_root / "JP_ScenarioModelCodes-AutoCreated.json"
    with scenario_model_path.open(encoding="utf-8-sig") as stream:
        scenario_model_data = json.load(stream)

    scenario_rows = scenario_model_data.get("dataList")
    if not isinstance(scenario_rows, list):
        raise SystemExit("角色表缺少 dataList 数组")

    scenario_names = {
        row["id"]: (row.get("name", ""), row.get("nickName", ""))
        for row in scenario_rows
        if isinstance(row, dict) and isinstance(row.get("id"), str)
    }

    speaker_fields_added = {"teller": 0, "title": 0}

    def fill_story_speaker_fields(value, source_name):
        if isinstance(value, dict):
            model = value.get("model")
            if isinstance(model, str) and model and "content" in value:
                names = scenario_names.get(model)
                missing_fields = [
                    field for field in ("teller", "title") if field not in value
                ]
                if missing_fields and names is None:
                    fields = ", ".join(missing_fields)
                    raise SystemExit(
                        f"{source_name} 中的角色 {model!r} 缺少 {fields}，"
                        "且无法从角色表补全"
                    )
                if "teller" not in value:
                    value["teller"] = names[0]
                    speaker_fields_added["teller"] += 1
                if "title" not in value:
                    value["title"] = names[1]
                    speaker_fields_added["title"] += 1

            for child in value.values():
                fill_story_speaker_fields(child, source_name)
        elif isinstance(value, list):
            for child in value:
                fill_story_speaker_fields(child, source_name)

    for relative, destination in patched_destinations:
        if not relative.parts or relative.parts[0] != "StoryData":
            continue

        with destination.open(encoding="utf-8-sig") as stream:
            story_data = json.load(stream)
        fill_story_speaker_fields(story_data, relative.as_posix())
        story_bytes = (
            json.dumps(story_data, ensure_ascii=False, indent=2) + "\n"
        ).encode("utf-8")
        destination.write_bytes(story_bytes)
        destination_name = destination.relative_to(stage).as_posix()
        expected_hashes[destination_name] = hashlib.sha256(story_bytes).digest()

    for resource in resource_files:
        if resource.suffix.lower() == ".json":
            with resource.open(encoding="utf-8-sig") as stream:
                json.load(stream)

        resource_bytes = resource.read_bytes()
        relative = resource.relative_to(resource_root).as_posix()
        manifest_key = f"Assets/Resources_moved/Localize/jp/{relative}"
        manifest_entry = manifest_files.get(manifest_key)
        if not isinstance(manifest_entry, dict):
            raise SystemExit(f"官方校验清单缺少日文资源：{manifest_key}")

        # 官方 Hash 是将 CRLF 标准化为 LF 后的 MD5；Size 使用原始字节数。
        manifest_entry["Hash"] = hashlib.md5(
            resource_bytes.replace(b"\r\n", b"\n")
        ).hexdigest()
        manifest_entry["Size"] = len(resource_bytes)

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

    output_manifest.write_text(
        json.dumps(manifest_data, ensure_ascii=False, indent=4) + "\n",
        encoding="utf-8",
    )

print(f"资源文件：{len(resource_files)}")
print(f"增量覆盖：{len(patch_files)}")
print(f"兼容字形替换：{replaced_characters}")
print(f"剧情说话人补全：{speaker_fields_added['teller']}")
print(f"剧情职位补全：{speaker_fields_added['title']}")
print(f"清单更新：{len(resource_files)}")
PY

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
