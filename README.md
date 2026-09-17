# 学习书架

Mac / iPhone 原生 Markdown 学习阅读器。本地阅读原型，支持 iOS 17+ 与 macOS 14+。

## 运行

1. 首次打开完整 Xcode，完成许可确认和组件安装。
2. 打开 `StudyReader.xcodeproj`，选择 `StudyReader` scheme。
3. 目标选择 `My Mac` 或可用的 iPhone 模拟器，点击 Run。
4. 真机运行时，在 Signing & Capabilities 里选择自己的 Team，并设置唯一 Bundle Identifier。

Mac 和 iPhone 模拟器的 Debug 配置使用本地签名，无需选择开发团队。iPhone 真机与 Release 配置使用自动签名，需要配置 Team。如果 Xcode 仍显示旧的团队报错，关闭并重新打开工程，确认运行目标是 `My Mac` 或具体模拟器，再按 ⌘R。

已经打包本地 Markdown、公式库、样式和字体，打开工程不需要 npm 或 XcodeGen。首次运行自带概率论样例。

## 当前能力

- 原生双端导航、目录与资料列表。
- Markdown、表格、图片、美元/括号分隔符公式。
- 本地文件与文件夹导入，附件相对路径保留；完全重复导入会跳过。
- 新建空资料夹、文章拖动排序、拖到左侧资料夹移动；归属和顺序自动保存。
- 标题/正文搜索、收藏、最近阅读、文章目录、页内查找。
- 字号和外观、答案折叠、文本选择、点击公式复制 LaTeX。
- 阅读位置持久保存；导出当前文章 MD 原文。

本阶段资料与阅读状态只保存在本机，没有开通 iCloud 同步。重新导入修改过的资料会保留成独立副本，不覆盖旧资料。当前导出是单篇 MD，不包含附件；完整资料包导出在后续阶段实现。

单篇 MD 限制 5 MB、单张图片 25 MB、每批导入 200 MB。远程图片不会自动下载；请导入本地附件。HTML 原文与脚本不执行。

## 整理资料（Mac）

1. 点击工具栏的“新建资料夹”，或按 ⇧⌘N，输入名称后创建。空资料夹在重启后仍然保留。
2. 在文章列表里上下拖动，在插入位置松开即可排序；也可以右键文章，选择“上移”或“下移”。
3. 把文章拖到左侧目标资料夹，资料夹高亮后松开即可移动；右键“移到资料夹”也可完成相同操作。
4. 选中资料夹后，用“＋ → 导入 Markdown 到当前资料夹”直接添加文章。“导入资料文件夹”仍创建独立资料夹。

“全部资料”和各资料夹分别保存手动顺序；收藏沿用“全部资料”的顺序。搜索结果中的排序只调整可见文章，隐藏文章保留原位置。“最近阅读”始终按阅读时间排列，可以从中拖出文章移动到资料夹。

资料夹是书架内的整理分组。移动只更新文章归属，MD 与附件继续保留在原始导入包中，避免相对图片路径和同名附件冲突；文档 ID、收藏、阅读进度保持不变。旧资料首次打开时自动生成整理记录，不需要重新导入。整理记录保存在 App 的 `library-organization.json` 中，写入成功后才更新界面。

## 修改渲染组件

```sh
npm ci --ignore-scripts
npm run build
npm test
```

编辑 `WebReader/` 后运行构建。生成的离线资源保存在 `StudyReader/Resources/Reader/`，包含第三方许可。

工程描述在 `project.yml`。添加/移除 Swift 文件后可以用 XcodeGen 2.46.0 重新生成工程：

```sh
xcodegen generate
```

本次开发用的 XcodeGen 位于忽略提交的 `.tools/xcodegen/bin/xcodegen`；也可以在 Xcode 中直接添加文件。

## 验证

2026-09-17 已通过：Mac 和 iOS 模拟器构建；7 项 JavaScript 测试；同套 15 项 XCTest 分别在 Mac 与 iPhone 18 Pro 模拟器通过。新加的 9 项测试覆盖旧资料迁移、空资料夹保存、上下排序、筛选后排序、跨资料夹移动与阅读记录保留、导入到指定资料夹、无效操作、写入失败和拖动数据传递。WebView 集成测试实际加载了本地公式、字体和图片，并检查样例没有页面横向溢出。

签名配置修正后，双端 XCTest 已在开启签名的正常 Debug 构建中重新通过。Mac 保持 App Sandbox；网络客户端权限用于 WebKit 正常启动，用户选择文件的读写权限用于导入和导出。阅读内容仍通过本地资源处理器加载。

完整界面交互、真机阅读、VoiceOver 和长文性能尚未验收。本次原生界面自动检查遇到 ScreenCaptureKit 屏幕捕获失败（-3811），所以鼠标拖放手势尚未完成端到端实测；拖放数据与实际持久化逻辑已通过上述双端测试。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project StudyReader.xcodeproj -scheme StudyReader -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/Mac test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project StudyReader.xcodeproj -scheme StudyReader -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iOS build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project StudyReader.xcodeproj -scheme StudyReader -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath .build/iOS test
```

模拟器名称应替换为本机已安装设备；也可在 Xcode 里选择设备后用 Product → Test。`DEVELOPER_DIR` 只对当前命令选择完整 Xcode，无需修改全局 Command Line Tools 设置。

JavaScript 测试验证数学分隔符、转义、答案折叠、错误公式和不可信内容处理；Swift 测试验证导入完整性、去重、失败回滚、文件访问边界和实际 WebView 渲染。

后续路径见 `PLAN.md`。渲染和同步的未完成验收项继续在该文档跟踪。
