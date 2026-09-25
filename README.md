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
