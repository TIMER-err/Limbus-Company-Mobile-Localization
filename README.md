# Limbus Company 移动端汉化资源打包

将 [LocalizeLimbusCompany](https://github.com/LocalizeLimbusCompany/LocalizeLimbusCompany) 译文写入官方日语资源槽，生成 `localize_jp.zip`。仓库仅包含构建脚本与字库数据（[`data/mobile-glyph-map.json`](data/mobile-glyph-map.json)、[`data/mobile-font-charset.txt`](data/mobile-font-charset.txt)），不收录译文或构建产物。

## 构建

依赖：`curl`、Python 3。

```sh
./scripts/build.sh
```

输出：`dist/localize_jp.zip`、`dist/manifest.json`。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `LOCALIZE_TAG` | `latest` | 汉化 Release 标签 |
| `GH_TOKEN` | 空 | 查询汉化 Release API 时使用的 GitHub 令牌；Actions 自动提供 |
| `OFFICIAL_PATCH_URL` | 空 | 指定官方清单目录（`…/Assets/LocalizePatch`），跳过目录解析 |
| `OFFICIAL_XAPK_URL` | APKPure `.net` 最新 XAPK | 从 XAPK 提取资源目录与客户端版本 |
| `OFFICIAL_CDN_IP` | 空 | 经本地代理访问官方 CDN 时的回源地址 |
| `OUTPUT_DIR` | `dist/` | 输出目录 |

将 `OFFICIAL_XAPK_URL` 置空可关闭自动解析；此时须通过 `OFFICIAL_PATCH_URL` 指定资源目录。无法解析资源版本目录时构建失败。

官方日文底包位于同一资源版本根目录下的 `Assets/Resources_moved/Localize/localize_jp.zip`，校验清单位于 `Assets/LocalizePatch/LocalizePatchInfo.json`。构建分别使用这两个路径，并核对底包文件与当前清单完全对应；不会改用旧版本底包。

默认使用 [APKPure `.net` 下载页](https://apkpure.net/limbus-company/com.ProjectMoon.LimbusCompany/download) 提供的公开下载入口。`.com` 入口可能对云服务器返回 Cloudflare 验证页（HTTP 403）；这不是 GitHub 令牌权限问题。解析器会报告被拒绝的下载地址及验证页类型，并隐藏地址中的签名查询参数。

## GitHub Actions

[`.github/workflows/build.yml`](.github/workflows/build.yml) 于 UTC+8 08:00、12:00、20:00 检查上游。客户端版本或汉化 Release 变化时构建，并发布 `v<客户端版本>-<汉化标签>`；相同组合已存在时跳过。

检查任务用 HTTP Range 读取 XAPK 的 ZIP 索引和 `manifest.json`，以包内 `version_name` 为客户端版本，不依赖镜像响应头或文件名。只有需要构建时才扫描 Unity 资源目录，不下载整个 XAPK。网络或清单解析失败时保留错误并终止检查，不使用旧版本兜底。

### 缺字审核

需要构建时，工作流先扫描整包译文。发现新缺字后，自动创建审核 PR，包含映射提案及 `data/mobile-glyph-review.md`：列出全部缺字、来源文件、上下文和候选字形。本次发布暂停，不使用未经审核的映射。

候选按 Noto Sans CJK 的字形相似度排序，目标只能来自已确认的移动端字库清单。这不是语义等价转换；候选可能改变人名或术语，必须人工逐项确认，必要时修改后再合并。无法用候选字体渲染的字会明确报告，不填入占位映射。

同一上游版本已有审核 PR 时，工作流只链接该 PR，不覆盖人工修改。映射合并到 `main` 后自动重新检查；全部缺字解决后重新构建并发布，即使该版本已有 Release，也会更新附件。不会自动批准或合并 PR。仓库需允许 Actions 创建 PR。

仅扫描时只需 Python 3：

```sh
python3 scripts/check-glyphs.py LimbusLocalize_TAG.zip --report glyph-review.md
```

生成可视候选另需 Pillow、fontTools 和 CJK 字体；Actions 会自动安装。使用 `--font 字体路径 --proposal proposed-map.json` 可在本地生成完整映射提案，扫描发现缺字时退出码仍为 `2`。输入错误退出码为 `1`，无缺字为 `0`。

人工修改 [`data/mobile-glyph-map.json`](data/mobile-glyph-map.json) 时，目标字必须在 [`data/mobile-font-charset.txt`](data/mobile-font-charset.txt) 中已确认可显示；不要仅为通过校验就将未确认的字符加入字库清单。

映射包含字库受限时的近形替代，例如 `苯 → 笨`，不只是简繁转换。近形替代不表示原译文有误。

扫描器覆盖整包 JSON（包括转义的 Unicode 字符），不在第一个缺字处提前退出。正式打包仍保留独立的缺字校验。

手动触发：

```sh
gh api repos/:owner/:repo/dispatches -f event_type=upstream_update
```

强制构建但不创建或更新 Release（产物仍上传到本次 Actions 运行）：

```sh
gh workflow run build.yml --ref main -f force=true -f publish_release=false
```

`publish_release` 默认开启，不改变定时任务和上游通知的发布行为。

## Credits

| 来源 | 用途 |
|---|---|
| [Project Moon](https://projectmoon.studio/) / Limbus Company | 游戏与官方日语资源 |
| [LocalizeLimbusCompany](https://github.com/LocalizeLimbusCompany/LocalizeLimbusCompany) | 简体中文译文 |
| [ghcruise/LimbusCompany-IOS-Localization](https://github.com/ghcruise/LimbusCompany-IOS-Localization) | 移动端字库覆盖范围 |
| [OpenCC](https://github.com/BYVoid/OpenCC) | 部分简繁字形对应 |

## 许可

本仓库源代码与字库数据依 [Apache License 2.0](LICENSE) 许可。第三方归属见 [NOTICE](NOTICE)。

构建产物含 Project Moon 官方资源及 LocalizeLimbusCompany 译文。前者版权归 Project Moon；后者依 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) 许可，使用、演绎与再分发须遵守署名、非商业与相同方式共享。本仓库不对上述材料主张权利。

Limbus Company 为 Project Moon 的商标。本项目与 Project Moon 无隶属或授权关系。

软件按现状提供，不附带任何明示或默示保证。作者不对使用本仓库或其产物所产生的任何损害承担责任。
