# 资料加载、搜索与阅读缓存优化

2026-09-17。基线为提交 `93eee4c`。本轮保留原来的共享 WebView、资料索引、异步附件读取与阅读状态写入节流，优化正文生命周期和异步请求。

## 已实现

- 启动只在后台读取资料清单、整理记录和阅读状态。多个窗口共用一次初始加载，加载完成前不会用空状态覆盖已保存记录。
- 正文独立按需读取，最近打开的文章采用 LRU 缓存，最多 8 篇、估算容量 8 MiB。超限单篇读取后直接使用，不留在缓存里。
- 全文搜索移出 MainActor，输入防抖 200 ms，逐篇检查取消状态，缓存最近 8 个查询结果。每个窗口用请求标识隔离旧结果与旧错误。匹配规则仍为 `localizedStandardContains`。
- 新导入直接追加返回的元数据并一次性更新索引；完全重复的导入不更新书架、不读取已有正文。新资料仍按自然文件名顺序加入。整理记录写入失败时保留资料包、暂停后续写入，重启时重新读取，避免重复导入。
- JavaScript 排版缓存同时估算原文、HTML、目录及资源地址的文本容量，最多 12 篇、8 MiB；单篇超限时绕过缓存，保留已有的小文章。
- 切换文章会使旧渲染和旧偏好恢复任务失效。调整偏好时若仍在首次排版，由当前渲染负责恢复位置。

正文缓存的 8 MiB 和排版缓存的 8 MiB 是各自的文本载荷预算，按 UTF-16 估算，不是整个 App 的内存上限。当前正在展示的文章、DOM、对象开销、图片及 WebKit 进程另占内存。

## 复测结果

在本机 arm64 Mac、Xcode 27.0 下用 `swiftc -O` 运行相同测量脚本，分别编译基线与修改后的资料库代码。使用临时合成资料，每篇重复 300 段中英概率论文本，1000 篇约 47.1 MB；文件刚生成，文件系统缓存已热。下表是同一轮单次测量，非真实 App 冷启动或统计分位数。

| 项目 | 优化前 | 优化后 |
| --- | ---: | ---: |
| 100 篇资料库加载完成 | 21.5 ms | 11.6 ms |
| 1000 篇资料库加载完成 | 107.7 ms | 38.6 ms |
| 1000 篇启动期间，MainActor 探测最大间隔 | 107.8 ms | 6.5 ms |
| 1000 篇中文未命中查询，总耗时 | 850.4 ms | 1068.0 ms |
| 同一中文查询期间，MainActor 探测最大间隔 | 850.4 ms | 6.4 ms |
| 1000 篇英文未命中查询，总耗时 | 399.9 ms | 584.7 ms |
| 同一英文查询期间，MainActor 探测最大间隔 | 399.9 ms | 6.4 ms |

优化后的第一次正文读取约 0.21 ms，读完一篇后正文缓存估算占用 59,422 字节；启动不再常驻全部正文。旧实现已在启动时读取正文，因此不把这个按需读取耗时与旧实现的“0 ms”作速度对比。

搜索总耗时增加，因为现在需要逐篇读取正文；收益是主线程持续可调度，且不必为搜索常驻全部正文。探测器每 5 ms 尝试在 MainActor 运行一次，中文查询期间优化后实际运行了 172 次，优化前为 0 次。该指标不等于屏幕帧率，也没有计算界面的 200 ms 输入防抖。重复查询可复用结果，收藏、阅读记录与资料夹移动不会导致整库重查。

JavaScript 使用相同公式样例生成 HTML：2500 组公式的原文为 336,403 字节，HTML 为 16,499,128 字节，缓存文本估算 33,771,802 字节。新缓存拒绝保留该条目，并保持之前小文章的缓存占用为 8,099,262 字节，小于 8,388,608 字节预算。旧实现允许最后一篇大文章突破上限。本次 Node.js HTML 生成约 443 ms，不包含 WebKit DOM 布局、字体加载或首屏显示。

## 验证范围

- 12 项 JavaScript 测试通过，含切文与偏好更新交错、过期渲染、容量限制和原有公式解析回归。
- 同套 25 项 XCTest 在正常签名的 Mac 与 iPhone 18 Pro 模拟器上分别通过，包含真实 WKWebView 本地公式、字体和图片加载。
- 新增 Swift 回归覆盖按需读取与路径检查、并发启动、启动前状态保护、LRU 淘汰、增量导入、文件自然排序、写入失败恢复、搜索本地化匹配、缓存失效、过期查询和防抖取消。
- 未测量真实 iPhone 冷启动、长文章滚动帧率及整个进程的内存峰值。超大公式文章仍需要完整解析和 DOM 布局，缓存上限不能消除这部分开销。

## 重复测量

在项目根目录运行；脚本在系统临时目录生成与清理资料，不访问真实资料库。

```sh
mkdir -p .build/performance-review
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O -parse-as-library -swift-version 5 \
  StudyReader/Library/LibraryDisk.swift StudyReader/Library/LibraryOrganization.swift \
  StudyReader/Library/LibraryContent.swift StudyReader/Library/LibraryStore.swift \
  scripts/benchmark-library.swift -o .build/performance-review/optimized-bench
.build/performance-review/optimized-bench
node scripts/benchmark-reader.mjs
```

`benchmark-library.swift` 的 `BASELINE` 编译分支适配提交 `93eee4c` 的接口，可使用该提交的 `LibraryDisk.swift`、`LibraryOrganization.swift`、`LibraryStore.swift` 加 `-D BASELINE` 编译，获得同一脚本下的对照数据。JS 与双端测试命令见 README。
