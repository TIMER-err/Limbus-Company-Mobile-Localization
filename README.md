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
| `OFFICIAL_PATCH_URL` | 空 | 指定官方资源目录，跳过解析 |
| `OFFICIAL_STATUS_URL` | [LCTA 状态 API](https://limbus.lcta.top/api/status) | 解析资源版本目录 |
| `OFFICIAL_XAPK_URL` | APKPure 最新 XAPK | 状态接口不可用时，从 XAPK 提取版本目录 |
| `OFFICIAL_CDN_IP` | 空 | 经本地代理访问官方 CDN 时的回源地址 |
| `OUTPUT_DIR` | `dist/` | 输出目录 |

将 `OFFICIAL_STATUS_URL` 或 `OFFICIAL_XAPK_URL` 置空可关闭对应解析步骤。无法解析资源版本目录时构建失败。

## GitHub Actions

[`.github/workflows/build.yml`](.github/workflows/build.yml) 于 UTC+8 08:00、12:00、20:00 检查上游。汉化标签、客户端版本或官方资源目录变化时构建，并发布 `v<客户端版本>-<汉化标签>`。

手动触发：

```sh
gh api repos/:owner/:repo/dispatches -f event_type=upstream_update
```

## Nginx

[`nginx/nginx.conf`](nginx/nginx.conf) 为 Android 本地 HTTPS 代理配置，监听 `127.0.0.1:443`，替换 `LocalizePatchInfo.json` 与 `localize_jp.zip`。证书置于 `/data/local/nginx/ssl/`，SAN 须包含 `downloadcommon.limbuscompanycdn.org`。证书不纳入本仓库。

## Credits

| 来源 | 用途 |
|---|---|
| [Project Moon](https://projectmoon.studio/) / Limbus Company | 游戏与官方日语资源 |
| [LocalizeLimbusCompany](https://github.com/LocalizeLimbusCompany/LocalizeLimbusCompany) | 简体中文译文 |
| [LCTA](https://github.com/HZBHZB1234/LCTA-Limbus-company-transfer-auto) | 官方资源版本目录 |
| [ghcruise/LimbusCompany-IOS-Localization](https://github.com/ghcruise/LimbusCompany-IOS-Localization) | 移动端字库覆盖范围 |
| [OpenCC](https://github.com/BYVoid/OpenCC) | 部分简繁字形对应 |

## 许可

本仓库源代码与字库数据依 [Apache License 2.0](LICENSE) 许可。第三方归属见 [NOTICE](NOTICE)。

构建产物含 Project Moon 官方资源及 LocalizeLimbusCompany 译文。前者版权归 Project Moon；后者依 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) 许可，使用、演绎与再分发须遵守署名、非商业与相同方式共享。本仓库不对上述材料主张权利。

Limbus Company 为 Project Moon 的商标。本项目与 Project Moon 无隶属或授权关系。

软件按现状提供，不附带任何明示或默示保证。作者不对使用本仓库或其产物所产生的任何损害承担责任。
