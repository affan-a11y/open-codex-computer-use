# 将官方参考包迁移到 GitHub Releases

## 目标

为两份官方 `computer-use` 参考 ZIP 提供固定 Release 下载链接，让当前主线的普通 clone 不再下载 LFS 参考包。

## 范围与约束

- 迁移 `1.0.750.zip`、`1.0.755.zip` 和校验清单到独立的 `reference-bundles` Release。
- 保留原文件哈希，在本地备份后移除 Git 跟踪；本地 ZIP 继续保留为忽略文件。
- 同步参考说明、原始制品提交约定与归档 Release 维护方式。
- 不重写历史、不修改付费预算、不发布新的 npm / App 版本。

## 风险与处理

- 资料丢失：先验证本地备份，上传后从公开固定入口重新下载校验，完成后再更新远端 main。
- 正式发布被误触发：使用不匹配软件 release tag glob 的 `reference-bundles`，归档设为 pre-release / 非 latest。
- 旧提交仍引用 LFS：保留边界说明，旧版本与其他仓库的 LFS 额度不因本次迁移自动恢复。

## 验证方式

- 迁移前后 SHA-256 一致，两个 ZIP 均通过 `unzip -tq`。
- 文档与 diff 检查；当前 Git tree 不再包含 ZIP / LFS 指针，下载后的本地 ZIP 被忽略。
- Release API 确认附件、pre-release 状态及正式 latest 未变。
- 从公开固定 URL 下载校验；对远端 main 执行启用 LFS 的全新 clone，确认正常检出且无需这些 ZIP。

## 进度记录

- [x] 核实干净 main 与远端一致；本地 ZIP 完整，备份哈希校验通过。
- [x] 确认 ZIP 只用于研究参考、不接入默认构建，制定固定 URL 与独立归档 tag。
- [x] 完成文档与 Git 跟踪迁移；文档骨架与 diff 检查通过，本地 ZIP 命中忽略规则。
- [ ] 发布并校验 Release 附件。
- [ ] 同步远端 main，验证干净克隆并记录 history。
