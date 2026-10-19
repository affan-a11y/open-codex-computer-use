# Official Computer Use Bundles

这个目录记录从本地 bundled plugin cache 归档的官方 `computer-use` ZIP 包，用作逆向分析和版本对比输入。原始 ZIP 保存在独立的 [reference-bundles Release](https://github.com/iFurySt/open-computer-use/releases/tag/reference-bundles)，仓库只保留下载链接和 SHA-256 校验值。普通 clone 无需下载这些文件，也不需要为它们配置 Git LFS。

## 当前归档

| File | Size | SHA-256 |
| --- | ---: | --- |
| [1.0.750.zip](https://github.com/iFurySt/open-computer-use/releases/download/reference-bundles/1.0.750.zip) | 13 MB | `7afe231e98ddb3b95030c8c56bb178a0217e98fcbb08abf9e1b467fd7ead5b9d` |
| [1.0.755.zip](https://github.com/iFurySt/open-computer-use/releases/download/reference-bundles/1.0.755.zip) | 13 MB | `cfabe3f41bfec1ea1d5f99ca2f5424eac98487e9474a099394c372d5df7a6460` |

## 下载与校验

在仓库根目录执行：

```bash
cd docs/references/codex-computer-use-reverse-engineering/assets/official-bundles/computer-use
curl --fail --location --retry 3 --output 1.0.750.zip \
  https://github.com/iFurySt/open-computer-use/releases/download/reference-bundles/1.0.750.zip
curl --fail --location --retry 3 --output 1.0.755.zip \
  https://github.com/iFurySt/open-computer-use/releases/download/reference-bundles/1.0.755.zip
shasum -a 256 -c SHA256SUMS
```

本地下载的 ZIP 被 `.gitignore` 忽略。无需运行 `git lfs pull`；Windows 可用 `Get-FileHash -Algorithm SHA256` 与上表逐项比对。

固定下载地址使用 `releases/download/reference-bundles/<filename>`，不依赖会随正式发版变化的 `latest`，也不使用下载跳转中临时签名的 URL。保留该 tag、Release 与附件文件名即可维持这些入口；已归档版本不要覆盖，新增版本使用新的文件名。

## 维护约定

- 这些 ZIP 只作为原始官方制品归档，不直接参与构建。
- 新增 ZIP 时，将其作为附件上传到 `reference-bundles` Release，并同步更新 `SHA256SUMS` 和本文件；校验值也随 Release 提供。
- 不要把 ZIP 提交到 Git 或重新添加 LFS 追踪规则。
- `reference-bundles` 是独立的资料归档 Release，标记为 pre-release 且不设为 latest，不发布 npm 或应用版本。
- 本次迁移只移除当前分支的 LFS 引用，不重写旧提交。检出旧版本仍可能需要 Git LFS；已经消耗的本月流量不会因迁移返还，远端历史 LFS 对象也不会因此自动清除。
