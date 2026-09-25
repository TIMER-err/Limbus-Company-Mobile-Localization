#!/bin/sh

set -eu

LOCALIZE_REPO="${LOCALIZE_REPO:-LocalizeLimbusCompany/LocalizeLimbusCompany}"
LOCALIZE_TAG="${LOCALIZE_TAG:-2026092102}"
OFFICIAL_PATCH_DEFAULT="https://downloadcommon.limbuscompanycdn.org/l20260924_4eb8-Rb7MrVjKfF17k-j/Assets/LocalizePatch"
OFFICIAL_PATCH_URL="${OFFICIAL_PATCH_URL-}"
# 版本目录烤在客户端的 resources.assets 里，该服务把它提取出来公开发布。
OFFICIAL_STATUS_URL="${OFFICIAL_STATUS_URL-https://limbus.lcta.top/api/status}"
# 客户端版本号，仅用于给产物命名；URL 里的 token 同样烤在客户端里。
OFFICIAL_SERVERINFO_URL="${OFFICIAL_SERVERINFO_URL-https://downloadcommon.limbuscompanycdn.org/serverinfos_nRtXsw5JLHS4z5PsiNio.json}"
# 官方大约每周换一次资源版本目录，过期的清单会让客户端反复重下语言包。
OFFICIAL_MAX_AGE_DAYS="${OFFICIAL_MAX_AGE_DAYS:-7}"
OFFICIAL_CDN_IP="${OFFICIAL_CDN_IP:-}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/dist}"
PYTHON="${PYTHON:-python3}"
GLYPH_MAP="${GLYPH_MAP:-$PROJECT_ROOT/data/mobile-glyph-map.json}"
FONT_CHARSET="${FONT_CHARSET:-$PROJECT_ROOT/data/mobile-font-charset.txt}"

for command_name in curl "$PYTHON"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '缺少构建依赖：%s\n' "$command_name" >&2
        exit 1
    fi
done

for data_file in "$GLYPH_MAP" "$FONT_CHARSET"; do
    if [ ! -f "$data_file" ]; then
        printf '找不到构建所需的数据文件：%s\n' "$data_file" >&2
        exit 1
    fi
done

# 官方 CDN 在本机被 hosts 指向代理时，用 --resolve 直连回源地址。
download_official() {
    if [ -n "$OFFICIAL_CDN_IP" ]; then
        curl -fsSL --retry 3 --retry-delay 1 \
            --resolve "downloadcommon.limbuscompanycdn.org:443:$OFFICIAL_CDN_IP" \
            -o "$2" "$1"
    else
        curl -fsSL --retry 3 --retry-delay 1 -o "$2" "$1"
    fi
}

md5_of() {
    "$PYTHON" - "$1" <<'PY'
import hashlib
from pathlib import Path
import sys

print(hashlib.md5(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

if [ -n "${TMPDIR:-}" ]; then
    tmp_base="$TMPDIR"
elif [ -n "${PREFIX:-}" ] && [ -d "$PREFIX/tmp" ]; then
    tmp_base="$PREFIX/tmp"
else
    tmp_base="/tmp"
fi
build_dir=$(mktemp -d "$tmp_base/limbus-mobile-pack.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

# 状态服务返回 {"latest_token": {"token": "l20260924_...", ...}}。
resolve_patch_dir() {
    curl -fsSL --retry 2 --retry-delay 1 --max-time 30 \
        -o "$build_dir/status.json" "$OFFICIAL_STATUS_URL" 2>/dev/null || return 1
    "$PYTHON" - "$build_dir/status.json" <<'PY'
import json
from pathlib import Path
import re
import sys

try:
    with Path(sys.argv[1]).open(encoding="utf-8-sig") as stream:
        data = json.load(stream)
except ValueError:
    raise SystemExit(1)

token = (data.get("latest_token") or {}).get("token")
# 只接受形如 l20260924_<token> 的取值，避免把异常响应当成目录用。
if isinstance(token, str) and re.fullmatch(r"l\d{8}_[A-Za-z0-9_-]+", token):
    print(token)
else:
    raise SystemExit(1)
PY
}

default_dir=$(printf '%s' "$OFFICIAL_PATCH_DEFAULT" | sed -n 's|.*/\(l[0-9]\{8\}_[^/]*\)/.*|\1|p')
if [ -n "$OFFICIAL_PATCH_URL" ]; then
    printf '资源版本目录：由 OFFICIAL_PATCH_URL 指定\n'
elif [ -z "$OFFICIAL_STATUS_URL" ]; then
    printf '资源版本目录：%s（状态服务已禁用，使用脚本内固定值）\n' "$default_dir"
    OFFICIAL_PATCH_URL="$OFFICIAL_PATCH_DEFAULT"
else
    resolved=$(resolve_patch_dir || true)
    if [ -z "$resolved" ]; then
        printf '资源版本目录：%s（状态服务不可用，回退到脚本内固定值）\n' "$default_dir"
        OFFICIAL_PATCH_URL="$OFFICIAL_PATCH_DEFAULT"
    elif [ "$resolved" = "$default_dir" ]; then
        printf '资源版本目录：%s（状态服务，与固定值一致）\n' "$resolved"
        OFFICIAL_PATCH_URL="$OFFICIAL_PATCH_DEFAULT"
    else
        printf '资源版本目录：%s（状态服务）\n' "$resolved"
        printf '  脚本内固定值 %s 已过时，建议更新成上面这个，\n' "$default_dir"
        printf '  以便状态服务不可用时也能构建出正确的包。\n'
        OFFICIAL_PATCH_URL=$(
            printf '%s' "$OFFICIAL_PATCH_DEFAULT" | sed "s|/$default_dir/|/$resolved/|"
        )
    fi
fi

# 版本目录形如 l20260924_<token>，日期部分用来判断固定值是否过期。
version_day=$(printf '%s' "$OFFICIAL_PATCH_URL" | sed -n 's|.*/l\([0-9]\{8\}\)_.*|\1|p')
if [ -n "$version_day" ]; then
    version_age=$(
        "$PYTHON" - "$version_day" <<'PY'
import datetime
import sys

day = datetime.datetime.strptime(sys.argv[1], "%Y%m%d").date()
print((datetime.date.today() - day).days)
PY
    )
    printf '官方资源版本：%s（%s 天前）\n' "$version_day" "$version_age"
    if [ "$version_age" -gt "$OFFICIAL_MAX_AGE_DAYS" ]; then
        printf '\n警告：正在使用的资源版本目录已过去 %s 天，官方很可能已经换版。\n' "$version_age" >&2
        printf '      用过期清单打出来的包会让客户端每次启动都重下语言包。\n' >&2
        printf '      启动一次游戏让本地代理记下新目录，再重新构建即可自动跟上。\n\n' >&2
    fi
fi

# 汉化文本的 Release 资源名里带有版本号，latest 需要先问出实际 tag。
if [ "$LOCALIZE_TAG" = "latest" ]; then
    curl -fsSL --retry 3 --retry-delay 1 \
        -o "$build_dir/release.json" \
        "https://api.github.com/repos/$LOCALIZE_REPO/releases/latest"
    LOCALIZE_TAG=$(
        "$PYTHON" - "$build_dir/release.json" <<'PY'
import json
from pathlib import Path
import sys

with Path(sys.argv[1]).open(encoding="utf-8") as stream:
    print(json.load(stream)["tag_name"])
PY
    )
fi

# RESOLVE_ONLY 只解析上游版本并退出，供 CI 判断是否值得跑完整构建。
resolved_patch_dir=$(printf '%s' "$OFFICIAL_PATCH_URL" | sed -n 's|.*/\(l[0-9]\{8\}_[^/]*\)/.*|\1|p')
if [ -n "${RESOLVE_ONLY:-}" ]; then
    # 客户端版本号只用于命名，取不到就留空。
    game_version=""
    if download_official "$OFFICIAL_SERVERINFO_URL" "$build_dir/serverinfos.json" \
            2>/dev/null; then
        game_version=$(
            "$PYTHON" - "$build_dir/serverinfos.json" <<'PY'
import json
from pathlib import Path
import sys

with Path(sys.argv[1]).open(encoding="utf-8-sig") as stream:
    entries = json.load(stream)

for entry in entries if isinstance(entries, list) else []:
    if entry.get("serverId") == "aos_product":
        versions = entry.get("versions") or []
        if versions:
            print(versions[0])
        break
PY
        )
    fi
    printf 'patch_dir=%s\n' "$resolved_patch_dir"
    printf 'localize_tag=%s\n' "$LOCALIZE_TAG"
    printf 'game_version=%s\n' "$game_version"
    exit 0
fi

printf '下载官方日文底包：%s\n' "$OFFICIAL_PATCH_URL/localize_jp.zip"
download_official "$OFFICIAL_PATCH_URL/localize_jp.zip" "$build_dir/base.zip"

# 底包无 .hash 可校验，改为在 Python 阶段逐个文件比对清单，见下。

printf '下载汉化文本：%s\n' "$LOCALIZE_REPO ($LOCALIZE_TAG)"
curl -fsSL --retry 3 --retry-delay 1 \
    -o "$build_dir/localize.zip" \
    "https://github.com/$LOCALIZE_REPO/releases/download/$LOCALIZE_TAG/LimbusLocalize_$LOCALIZE_TAG.zip"

printf '下载官方校验清单：%s\n' "$OFFICIAL_PATCH_URL/LocalizePatchInfo.json"
download_official "$OFFICIAL_PATCH_URL/LocalizePatchInfo.json" "$build_dir/manifest.json"

# 官方在同目录发布清单的 MD5，直接用它校验，无需手工固定哈希。
printf '校验官方清单：%s\n' "$OFFICIAL_PATCH_URL/LocalizePatchInfo.hash"
if download_official "$OFFICIAL_PATCH_URL/LocalizePatchInfo.hash" \
        "$build_dir/manifest.hash" 2>/dev/null; then
    expected_manifest_md5=$(tr -d ' \t\r\n' < "$build_dir/manifest.hash")
    actual_manifest_md5=$(md5_of "$build_dir/manifest.json")
    if [ "$expected_manifest_md5" != "$actual_manifest_md5" ]; then
        printf '官方清单 MD5 不匹配：期望 %s，实际 %s\n' \
            "$expected_manifest_md5" "$actual_manifest_md5" >&2
        exit 1
    fi
    printf '  MD5 一致：%s\n' "$actual_manifest_md5"
else
    printf '  警告：取不到 LocalizePatchInfo.hash，本次跳过清单校验\n' >&2
fi

mkdir -p "$build_dir/output"

"$PYTHON" - "$build_dir/base.zip" \
    "$build_dir/localize.zip" \
    "$build_dir/manifest.json" \
    "$GLYPH_MAP" \
    "$FONT_CHARSET" \
    "$build_dir/output/localize_jp.zip" \
    "$build_dir/output/manifest.json" <<'PY'
import hashlib
import json
from pathlib import Path
import re
import sys
import tempfile
import zipfile

base_zip = Path(sys.argv[1])
localize_zip = Path(sys.argv[2])
manifest = Path(sys.argv[3])
glyph_map_path = Path(sys.argv[4])
font_charset_path = Path(sys.argv[5])
output_zip = Path(sys.argv[6])
output_manifest = Path(sys.argv[7])

# 官方按内容更新拆出来的增量文件，条目之后会并进同名的累积文件。
PATCH_SUFFIX = re.compile(r"-a1c\d+p\d+(?=\.json$)")

# 汉化包自带的元数据，日文槽位里没有对应文件。
LOCALIZE_METADATA = {"version.json"}

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

reference_characters = set()
for line in font_charset_path.read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if line and not line.startswith("#"):
        reference_characters.update(line)
if not reference_characters:
    raise SystemExit("移动端字库清单为空")


def is_cjk(character):
    return (
        "㐀" <= character <= "鿿"
        or "豈" <= character <= "﫿"
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
    # 汉化包是平铺目录，去掉 JP_ 前缀后的文件名就是它与日文槽位的对应关系。
    destinations = {}
    for resource in resource_files:
        if resource.suffix.lower() == ".json":
            json.loads(resource.read_text(encoding="utf-8-sig"))
        if not resource.name.startswith("JP_"):
            raise SystemExit(f"参考包中存在没有 JP_ 前缀的资源：{resource.name}")
        slot = resource.name[len("JP_"):]
        if slot in destinations:
            raise SystemExit(f"参考包中存在重名的日文槽位：{slot}")
        destinations[slot] = resource

    # 底包没有单独的 .hash。真正要守的是「底包与清单是否同一版本」——
    # 清单列出而底包缺失的文件会让客户端每次启动都重下语言包。
    slot_keys = {
        key.split("/jp/", 1)[1]
        for key in manifest_files
        if "/jp/" in key
    }
    slot_files = {
        resource.relative_to(resource_root).as_posix() for resource in resource_files
    }
    only_manifest = sorted(slot_keys - slot_files)
    only_base = sorted(slot_files - slot_keys)
    if only_manifest or only_base:
        raise SystemExit(
            "官方日文底包与清单不是同一版本："
            "清单多出 {} 个（{}），底包多出 {} 个（{}）".format(
                len(only_manifest), "、".join(only_manifest[:3]) or "无",
                len(only_base), "、".join(only_base[:3]) or "无",
            )
        )

    # 官方偶尔会就地改动文件却不同步清单里的 Hash（Size 不变所以不易察觉）。
    # 成品的清单条目全部由我们重算，这类不一致无害，仅作提示。
    stale_entries = []
    for resource in resource_files:
        relative = resource.relative_to(resource_root).as_posix()
        entry = manifest_files["Assets/Resources_moved/Localize/jp/" + relative]
        raw = resource.read_bytes()
        if hashlib.md5(raw.replace(b"\r\n", b"\n")).hexdigest() != entry.get("Hash"):
            stale_entries.append(relative)
    print(f"底包校验：{len(slot_files)} 个日文槽位与清单一一对应")
    if stale_entries:
        print(
            "  官方自身 Hash 不同步：{} 个（成品已重算，无影响）".format(
                len(stale_entries)
            )
        )

    # 替换只做一遍，映射的目标字必须本身就能显示，否则会被当成缺字漏到成品里。
    unusable = sorted(
        {
            f"{source}->{target}"
            for source, target in glyph_map.items()
            if is_cjk(target) and target not in reference_characters
        }
    )
    if unusable:
        raise SystemExit(
            "字形映射的目标字不在字库清单中：" + "、".join(unusable)
        )

    with zipfile.ZipFile(localize_zip) as archive:
        bad_member = archive.testzip()
        if bad_member is not None:
            raise SystemExit(f"汉化 ZIP 校验失败：{bad_member}")
        localize_members = sorted(
            (member for member in archive.infolist() if not member.is_dir()),
            key=lambda member: member.filename,
        )
        if not localize_members:
            raise SystemExit("汉化 ZIP 中没有资源文件")

        expected_hashes = {}
        replaced_characters = 0
        patched_destinations = []
        skipped = []
        for member in localize_members:
            name = Path(member.filename).name
            if not name.lower().endswith(".json") or name in LOCALIZE_METADATA:
                skipped.append(member.filename)
                continue

            destination = destinations.get(name)
            if destination is None:
                skipped.append(member.filename)
                continue

            source_text = archive.read(member).decode("utf-8-sig")
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
                    f"{member.filename} 仍包含字库清单以外的汉字：{characters}"
                )

            transformed_bytes = transformed_text.encode("utf-8")
            destination.write_bytes(transformed_bytes)
            patched_destinations.append((member.filename, destination))
            replaced_characters += sum(
                source_text.count(character) for character in glyph_map
            )
            expected_hashes[
                destination.relative_to(stage).as_posix()
            ] = hashlib.sha256(transformed_bytes).digest()

    if not patched_destinations:
        raise SystemExit("汉化 ZIP 没有覆盖任何日文槽位")

    # 汉化包只发累积文件，官方仍在发的增量文件按条目 id 从累积文件回填。
    patched_slots = {path.name[len("JP_"):] for _, path in patched_destinations}
    backfilled_files = 0
    backfilled_rows = 0
    unfilled_rows = {}
    for slot, destination in sorted(destinations.items()):
        if slot in patched_slots or destination.suffix.lower() != ".json":
            continue

        stem = PATCH_SUFFIX.sub("", slot)
        merged = destinations.get(stem)
        if stem == slot or merged is None or stem not in patched_slots:
            continue

        with merged.open(encoding="utf-8-sig") as stream:
            merged_rows = json.load(stream).get("dataList")
        if not isinstance(merged_rows, list):
            continue
        translated = {
            row["id"]: row
            for row in merged_rows
            if isinstance(row, dict) and "id" in row
        }

        with destination.open(encoding="utf-8-sig") as stream:
            delta = json.load(stream)
        rows = delta.get("dataList")
        if not isinstance(rows, list):
            continue

        filled = 0
        missing = 0
        for index, row in enumerate(rows):
            if not isinstance(row, dict):
                continue
            source_row = translated.get(row.get("id"))
            # 字段对不上说明两边不是同一份数据，宁可保留日文原文。
            if source_row is None or set(source_row) != set(row):
                missing += 1
                continue
            rows[index] = source_row
            filled += 1

        if not filled:
            continue

        delta_bytes = (
            json.dumps(delta, ensure_ascii=False, indent=2) + "\n"
        ).encode("utf-8")
        destination.write_bytes(delta_bytes)
        expected_hashes[
            destination.relative_to(stage).as_posix()
        ] = hashlib.sha256(delta_bytes).digest()
        backfilled_files += 1
        backfilled_rows += filled
        if missing:
            unfilled_rows[slot] = missing

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
    unknown_models = {}

    def fill_story_speaker_fields(value, source_name):
        if isinstance(value, dict):
            model = value.get("model")
            if isinstance(model, str) and model and "content" in value:
                names = scenario_names.get(model)
                missing_fields = [
                    field for field in ("teller", "title") if field not in value
                ]
                # 联动章节和 //CG、//效果音 这类演出指示不在角色表里，
                # 留空交给客户端自己的回退逻辑，只统计后报告。
                if missing_fields and names is None:
                    unknown_models[model] = unknown_models.get(model, 0) + 1
                else:
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

    for source_name, destination in patched_destinations:
        relative = destination.relative_to(resource_root)
        if not relative.parts or relative.parts[0] != "StoryData":
            continue

        with destination.open(encoding="utf-8-sig") as stream:
            story_data = json.load(stream)
        fill_story_speaker_fields(story_data, source_name)
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
print(f"汉化覆盖：{len(patched_destinations)}")
print(f"增量文件回填：{backfilled_files} 个 / {backfilled_rows} 条")
print(f"兼容字形替换：{replaced_characters}")
print(f"剧情说话人补全：{speaker_fields_added['teller']}")
print(f"剧情职位补全：{speaker_fields_added['title']}")
print(f"清单更新：{len(resource_files)}")
if skipped:
    print(f"跳过（没有对应日文槽位）：{len(skipped)}")
    for name in skipped:
        print(f"  {name}")
if unfilled_rows:
    print(f"增量文件中没能回填的条目：{sum(unfilled_rows.values())}")
    for slot in sorted(unfilled_rows):
        print(f"  {slot} x{unfilled_rows[slot]}")
if unknown_models:
    entries = sum(unknown_models.values())
    print(f"角色表缺失，说话人留空：{len(unknown_models)} 个角色 / {entries} 条台词")
    for model in sorted(unknown_models):
        print(f"  {model} x{unknown_models[model]}")
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
