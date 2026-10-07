# 1. PairFlow MVP 实施计划

**目标：** 在已批准范围内完成可安装的 Lightroom Classic JPEG→RAW 选片标记同步插件。

**架构：** 匹配算法与 Lightroom SDK 适配分离，入口仅组织界面和执行流程；结果由统一报告模块呈现。

**技术栈：** Lua 5.1、Lightroom Classic SDK、无运行时外部依赖。

**设计：** `docs/superpowers/specs/2026-10-07-pairflow-mvp-design.md`。

## 1.1. 全局约束

- 同目录配对、当前选中 JPEG、原片限定、歧义跳过。
- 只同步星级、颜色标签、Pick/Reject；预览默认开启。
- 保留 GPL-3.0 许可证，独立实现；参考项目的功能和 SDK 用法，不复制其源码。
- 不新增单元测试，不提交 Git，不推送远程。

## 1.2. 匹配和目录适配

- [x] 实现 `Pairing.build(sources, candidatesByFolder)`，返回配对、跳过项及原因。
- [x] 实现 `CatalogAdapter.collect(catalog, selected, progress)`，读取原片信息并缓存同目录候选。
- [x] 实现 `CatalogAdapter.apply(catalog, pair, fields)`，检查字段值并在错误时尝试恢复目标字段。
- [x] 用临时模拟数据验证单候选、多候选时间消歧、重复来源、虚拟副本和跨目录隔离。

## 1.3. 插件入口和界面

- [x] 注册 `PairFlow.lrplugin/Info.lua` 菜单，声明 SDK 兼容信息。
- [x] 实现 `Sync.lua`：拒绝空选择、字段选项、仅预览、明确写入确认、取消和进度。
- [x] 实现 `Report.lua`：显示并允许复制每一项来源、目标、跳过原因及写入结果。
- [x] 模拟 SDK 执行预览、应用、失败恢复和取消流程，确保未勾选字段与 Develop 参数不受影响。

## 1.4. 交付验证

- [x] 编写数字标题 README，说明安装路径、JPEG 过滤、预览、正式同步以及旧状态覆盖。
- [x] 检查所有 Lua 文件的 5.1 语法和插件加载入口。
- [x] 执行 `git diff --check` 和新文件空白检查；既有许可证未修改，忽略规则仅追加本地 `work/`。
- [x] 汇报静态/模拟证据及 Lightroom 实机验证限制。

## 1.5. 验证结果

- 五个插件文件均通过 Lua 5.1 语法解析。
- 临时 Fengari 执行验证通过：配对、精确时间消歧、同名来源冲突、跨目录隔离、目标虚拟副本排除和未匹配。
- 模拟 SDK 流程通过：空选择拒绝、SDK `JPG` 格式识别、仅预览零写入、三个字段写入、只勾选星级、清空状态、失败恢复、确认取消、执行中取消、来源虚拟副本排除和已一致零写入。
- `git diff --check` 与所有新文件的空白检查通过；没有提交或推送。
- 临时验证工具及脚本均在已忽略的 `work/` 下，不是插件运行依赖，没有加入单元测试套件。
- 尚未在 Lightroom Classic 中实机加载、执行或验证 Windows/macOS 的界面显示。
