# Limbus Company 移动端汉化资源打包

本仓库只保存可复现的打包脚本，不提交生成的 `localize_jp.zip` 和
`manifest.json`。生成的资源包供所有移动端 Limbus Company 客户端使用，通过替换
日语资源槽位加载中文文本。

## 上游

- [ghcruise/LimbusCompany-IOS-Localization](https://github.com/ghcruise/LimbusCompany-IOS-Localization)：提供移动端日语资源槽位的完整参考底包与 `manifest.json`。默认使用 Release `v1.114.0-alpha`。
- [haool871/Limbus-Company-Chapter-10-Week-1-Chinese-Localization-Share](https://github.com/haool871/Limbus-Company-Chapter-10-Week-1-Chinese-Localization-Share)：提供第十章第一周增量汉化。默认使用提交 `a05c0b00c74c3b4c9c39a7e501d0012bbea317d7`。

请遵守两个上游各自的许可与非商业使用要求。本仓库不对上游文本主张额外权利。

## 打包方式

脚本会下载参考 Release 中的完整 `localize_jp.zip` 和 `manifest.json`，再将增量仓库
`patch/` 下的文件映射到 `LocalizeTemp_jp/`：保留原有子目录，并给每个文件名添加
`JP_` 前缀。映射存在性、JSON 格式、覆盖后的文件内容及 ZIP 完整性都会在构建时检查。

这种方式保留参考包的完整资源集合，同时只替换增量仓库提供的 129 个资源文件。

## 构建

需要 `git`、`curl` 和 Python 3：

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
REFERENCE_TAG=v1.114.0-alpha \
SOURCE_REF=main \
OUTPUT_DIR="$PWD/dist" \
./scripts/build.sh
```

`REFERENCE_TAG=latest` 会使用参考仓库的最新 Release。发布时仅需将 `dist/` 中的两个
文件作为 Release 附件上传；它们不会进入 Git 历史。
