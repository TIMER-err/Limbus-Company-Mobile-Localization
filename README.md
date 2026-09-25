# Limbus Company 移动端汉化资源打包

本仓库只保存可复现的打包脚本，不提交生成的 `localize_jp.zip` 和
`manifest.json`。生成的资源包供所有移动端 Limbus Company 客户端使用，通过替换
日语资源槽位加载中文文本。

## 上游

- [Limbus Company 官方 CDN](https://downloadcommon.limbuscompanycdn.org/)：提供原版日文底包 `localize_jp.zip` 和对应的校验清单 `LocalizePatchInfo.json`，清单用官方同目录发布的 `LocalizePatchInfo.hash` 校验。
- [LCTA 边狱文件状态 API](https://limbus.lcta.top/api/status)：提供官方 CDN 当前的资源版本目录，由 [LCTA](https://github.com/HZBHZB1234/LCTA-Limbus-company-transfer-auto) 从客户端资源中提取并发布。
- [LocalizeLimbusCompany](https://github.com/LocalizeLimbusCompany/LocalizeLimbusCompany)：提供全量汉化文本，取自 Release 附件 `LimbusLocalize_<tag>.zip`。默认使用 `2026092102`。

本仓库不保存任何译文，只保存两份纯数据表：[`data/mobile-glyph-map.json`](data/mobile-glyph-map.json)
是单字到单字的字形替换表，[`data/mobile-font-charset.txt`](data/mobile-font-charset.txt)
是移动端日文字库已确认可显示的汉字清单。二者都不含成句文本。字库清单的取值参考了
[ghcruise/LimbusCompany-IOS-Localization](https://github.com/ghcruise/LimbusCompany-IOS-Localization)
已发布包实际用到的字符范围，构建过程本身不再依赖该项目。

请遵守汉化上游的许可与非商业使用要求。本仓库不对上游文本主张额外权利。

## 打包方式

脚本会从官方 CDN 下载原版日文底包和校验清单（两者都按固定 SHA-256 校验），再把汉化 Release 里
`LimbusCompany_Data/Lang/LLC_zh-CN/` 下的文件映射到 `LocalizeTemp_jp/`。汉化包是平铺目录，
底包是分子目录加 `JP_` 前缀，两边按去掉前缀后的文件名一一对应。之后根据字形替换表把移动端
日文字库缺失的简体字换成可显示的繁体或日语字形，并对照字库清单检查结果。JSON
格式、覆盖后的文件内容及 ZIP 完整性也都会在构建时检查。脚本还会重算成品内全部日文槽位文件的
`Hash` 和 `Size`，避免客户端在每次启动时重复下载语言包。

官方会把内容更新拆成 `UserBanner-a1c8p1.json` 这样的增量文件，条目之后并进同名累积文件
（`UserBanner.json`）；汉化上游只发累积文件。脚本会按条目 `id` 从累积文件回填这些增量文件，
字段结构对不上时保留日文原文并在结束时报告。

对于剧情中只提供 `model` 而缺少 `teller` 或 `title` 的台词，脚本会从覆盖后的
`ScenarioModelCodes` 角色表（同样来自汉化上游）补全说话人和职位。上游已经显式填写的值会保留，以支持剧情中的特殊称呼。
联动章节的角色以及 `//CG`、`//효과음` 这类演出指示不在角色表里，说话人留空交给客户端自行回退，
构建结束时会列出这些 `model` 供核对。

这种方式保留官方底包的完整资源集合（2187 个文件），替换其中汉化包直接提供的 2177 个，
再回填剩下 10 个增量文件。如果新文本含有映射表和字库清单均未覆盖的汉字，构建会直接失败
并列出这些字符；映射表自身的目标字也必须在字库清单中，否则同样直接失败。

## 构建

需要 `curl` 和 Python 3：

```sh
./scripts/build.sh
```

产物生成在 `dist/`：

```text
dist/localize_jp.zip
dist/manifest.json
```

可以通过环境变量选择其他上游版本或输出目录：

```sh
LOCALIZE_TAG=2026092102 \
OFFICIAL_STATUS_URL=https://limbus.lcta.top/api/status \
OFFICIAL_PATCH_URL=https://example.invalid/Assets/LocalizePatch \
OFFICIAL_MAX_AGE_DAYS=7 \
OFFICIAL_CDN_IP=<optional-origin-ip> \
OUTPUT_DIR="$PWD/dist" \
./scripts/build.sh
```

`LOCALIZE_TAG=latest` 会使用汉化仓库的最新 Release。`OFFICIAL_PATCH_URL` 会跳过版本目录解析，
`OFFICIAL_STATUS_URL=` 置空则直接使用脚本内固定值。本机 hosts 已把官方域名指向代理时
（例如部署了下文的 Nginx），用 `OFFICIAL_CDN_IP` 指定回源地址绕开。
发布时仅需将 `dist/` 中的两个文件作为 Release 附件上传；它们不会进入 Git 历史。

### 资源版本目录

官方 CDN 的路径里带一段 `l<YYYYMMDD>_<token>`，随客户端版本变化，token 是随机的。它并非由 API 下发，
而是**烤在客户端的 Unity 资源里**（`resources.assets` / 安卓的 `split_UnityDataAssetPack.apk`），
正则 `downloadcommon\.limbuscompanycdn\.org/(l\d{8}_[A-Za-z0-9_-]+)` 即可提取。CDN 本身没有
免认证的固定入口，`serverinfos_*.json` 的 `cdnUrl` 为空。

构建机上没有游戏文件，所以脚本改从 `OFFICIAL_STATUS_URL`（默认 LCTA 的状态 API）取这个目录。优先级：

1. 显式设置了 `OFFICIAL_PATCH_URL` —— 直接用，不做解析
2. 状态 API 返回合法目录 —— 用它；与脚本内固定值不同时会提示更新固定值
3. 状态 API 不可用、返回异常、或被置空 —— 回退到脚本内固定值

取到的目录只接受 `l\d{8}_[A-Za-z0-9_-]+` 形式，异常响应不会被当成目录使用。
构建开始时会打印版本目录的日期和距今天数，超过 `OFFICIAL_MAX_AGE_DAYS`（默认 7）给出警告 ——
状态 API 正常时目录总是新的，这个警告实际只在回退到过期固定值时出现。

底包与清单的一致性由两道检查保证，都不需要手工固定哈希：

- 清单对照官方同目录的 `LocalizePatchInfo.hash`（即清单自身的 MD5）
- 底包的日文槽位集合必须与清单的 jp 条目**一一对应** —— 少一个都会让客户端每次启动重下语言包

官方偶尔会就地改动文件却不同步清单里的 `Hash`（`Size` 不变所以不易察觉），构建会报告这类不一致的数量；
由于成品的清单条目全部由我们重算，它们不影响结果。

## 在 GitHub Actions 中构建

[`.github/workflows/build.yml`](.github/workflows/build.yml) 负责自动构建与发布。构建脚本只依赖
`curl` 和 Python 3，不涉及本地代理或设备文件，可直接在 runner 上运行。

GitHub Actions 无法订阅其他仓库的 release 事件，所以只能轮询。为了让轮询足够便宜，工作流拆成两段：

- `check`：每 30 分钟跑一次，用 `RESOLVE_ONLY=1 ./scripts/build.sh` 解析上游版本（约 1 秒，只发几个
  HTTP 请求，不下载任何资源包），再判断是否需要构建。
- `build`：仅在 `check` 认为上游有更新时才运行，完成后发布 Release。

判断依据是 Release 自身，不需要额外的状态文件。Release 按仓库既有习惯命名为
`v<客户端版本>-<汉化 tag>`，正文里记录当次使用的资源版本目录。三种情况会触发构建：

1. 该 tag 还没有 Release —— 汉化上游发了新版本，或客户端版本变了
2. Release 正文记录的资源版本目录与当前不同 —— 客户端版本号没变但官方换了资源目录
3. 手动触发并勾选 `force`

也可以用 `repository_dispatch` 立即触发，跳过轮询等待：

```sh
gh api repos/:owner/:repo/dispatches -f event_type=upstream_update
```

官方 CDN 偶发 TLS 握手失败，而 `curl --retry` 不覆盖握手层错误，所以构建步骤整体重试三次。

## 本地 Nginx 配置

[`nginx/nginx.conf`](nginx/nginx.conf) 用于 Android 设备上的本地 HTTPS 代理，默认目录为
`/data/local/nginx`。它只监听 `127.0.0.1:443`，拦截 `LocalizePatchInfo.json` 和
`localize_jp.zip`，其他请求使用两个 Cloudflare 回源地址。如果官方 CDN 更换 IP，
需同步更新 `upstream limbus_cdn`。

仓库不包含 TLS 证书和私钥。部署前需在 `/data/local/nginx/ssl/` 准备已被设备信任、
且 SAN 覆盖 `downloadcommon.limbuscompanycdn.org` 的 `ca.crt` 和 `ca.key`。可在 root shell 中检查并加载配置：

```sh
cp nginx/nginx.conf /data/local/nginx/conf/nginx.conf
/data/local/nginx/nginx -t -p /data/local/nginx/ -c conf/nginx.conf
/data/local/nginx/nginx -s reload -p /data/local/nginx/ -c conf/nginx.conf
```

如果原配置监听所有网卡的 `443` 端口，改为回环地址时需完整重启 Nginx，
因为热重载期间旧监听套接字仍会占用端口。
