# 资料加载、搜索与阅读缓存优化

## 2026-09-18 补充：按变化异步保存阅读状态

后续保存实现已替换下面历史记录中的同步 `saveQueue.sync`：`LibraryStore` 只在收藏、阅读位置、最近阅读或同步合并实际改变状态时推进保存版本，`ReadingStateWriter` 在独立 actor 上编码并原子写入。`flush()` 现在是异步操作；并发调用复用同一版本的写入，保存期间的新状态按顺序落盘，保存失败不清除待保存标记。切文前等待保存时，等待前后的选择请求都要匹配，防止旧点击覆盖后续选择。

新增测试验证无变化的多次 flush 和干净重启不改变文件 inode、慢写入期间 MainActor 仍能处理下一次收藏和阅读操作、最终文件保留最新状态，以及写入失败后的重试。已收敛的双端空闲同步不重写本机阅读状态或收藏快照。没有为本轮给出真机耗时或帧率结论。

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
  StudyReader/Library/*.swift StudyReader/Sync/*.swift \
  scripts/benchmark-library.swift -o .build/performance-review/optimized-bench
.build/performance-review/optimized-bench
node scripts/benchmark-reader.mjs
```

`benchmark-library.swift` 的 `BASELINE` 编译分支适配提交 `93eee4c` 的接口，可使用该提交的 `LibraryDisk.swift`、`LibraryOrganization.swift`、`LibraryStore.swift` 加 `-D BASELINE` 编译，获得同一脚本下的对照数据。JS 与双端测试命令见 README。

---

# 阅读滚动与屏幕底部

2026-09-17 第二轮。基线为提交 `dbc4d01`。针对两个实际现象：iPhone 上长文滚动卡顿，以及正文下方留出一条用不到的空白。

## 已实现

- 记录阅读位置改为从上一次的结果向两侧走。原来每次都从文章开头逐块调用 `getBoundingClientRect()`，读得越靠后扫描的块越多；滚动时每 200 ms 记录一次，这段测量正好落在 WebKit 即将绘制的那一帧里。现在按文档顺序走到阅读线两侧的相邻块为止，折叠起来没有盒子的解答照旧跳过，取值与整篇扫描逐位相同，包括正好落在两块中间时仍取靠前的一块。
- 每个块的前 100 字摘要按元素缓存，图片缺失替换、切换文章和排版失败时与块列表一起失效。原来每次记录和每次恢复位置都要重新遍历文本节点。
- 位置和上一次发给 App 的完全一样时不再发送消息，停下不动时的定时记录不再跨进程往返。
- iPhone 的 WebView 不再透明。`isOpaque = false` 让 WebKit 绘制每块贴图时都要做混合；现在 WebView 和它的滚动视图使用与 `--paper` 相同的颜色，跟随「自动 / 浅色 / 深色」，越界回弹区域也是纸色，不会闪白。
- 书架进度条的刷新通知限速到每 0.5 秒一次，并保证最后一次送达。每次滚动记录原来都会让整个书架、包括阅读页自己的工具栏重新求值，而书架上画的只是一条细线。
- 正文填满屏幕底部：`ReaderWebView` 不再被底部安全区挡住，CSS 的下边距加上 `env(safe-area-inset-bottom)`，最后几行仍然避开主屏幕指示条。书架底部出现导入或提示条时，正文重新让出这段位置，不会被盖住。
- 宽表格、代码块和宽公式的横向滚动加上 `overscroll-behavior-x: contain`，滑到尽头不再带动整页或触发返回手势。

## 复测结果

同一篇合成文章：320 节，每节含一个块级公式、两条行内公式和一个折叠解答，共 1921 个阅读块。分别在 iPhone 18 Pro 模拟器的 Safari（真正的 WebKit）和 Mac 上的 Chromium 里，加载同一份打包好的 `reader.js`，从 15% 读到 97%、每次前进 1200 px，重复 10 轮。表中是每次记录位置自身的耗时，已减去同一轮只滚动不记录的耗时。

| 引擎 | 页高 | 优化前（最小 / 中位） | 优化后（最小 / 中位） |
| --- | ---: | ---: | ---: |
| WebKit，iPhone 18 Pro 模拟器 | 217,097 px | 0.372 / 0.311 ms | 0.007 / 0.061 ms |
| Chromium，Mac | 195,819 px | 0.664 / 0.600 ms | 0.029 / 0.000 ms |

模拟器用的是 Mac 的处理器，真机上两个数字都会更大，差距也更大。361 个阅读块的短文里，Chromium 上是 0.085 ms → 0.013 ms；块越多差距越大，因为原来的耗时随视口以上的块数增长，现在只和两次记录之间跨过的块数有关。

底部空白在 iPhone 18 Pro 模拟器上实测为 102 个设备像素，即 34 pt，正是主屏幕指示条的安全区。修改后正文纸色一直铺到屏幕最后一行，浅色为 `#FCFBF7`、深色为 `#1D2423`，与 CSS 的 `--paper` 一致。

WebView 透明度、书架刷新限速和消息去重没有单独测量，它们减少的是每帧混合、SwiftUI 重新求值和跨进程往返的次数，不是这张表里的 JavaScript 耗时。

## 验证范围

- 20 项 JavaScript 测试通过，其中新增一项：沿着文章上下滚动、跳转目录、以及位置正好落在两块中间时，新的走法与整篇扫描结果一致，并跳过折叠起来的解答。突变测试确认该用例能发现漏掉折叠块和改变并列取舍这两种写法。
- iPhone 18 Pro 模拟器 78 项 XCTest 通过，包含实际运行 WebView 的阅读进度恢复与持久化。
- Mac 的 XCTest 当时没有跑起来，原因是工程签名配置的问题，与本轮改动无关；已在下一节修好并补跑，90 项通过。
- iPhone 18 Pro 模拟器截图确认底部空白消失，浅色与深色下纸色都铺到屏幕底端。
- 未在真机上测量滚动帧率。模拟器不代表 iPhone 的 GPU 和内存带宽，超长公式文章的 DOM 布局与绘制开销也不在本轮改动范围内。

## 重复测量

在项目根目录运行 `python3 -m http.server 8000`，然后：

```sh
open http://127.0.0.1:8000/scripts/benchmark-scroll.html?n=320
xcrun simctl openurl booted "http://127.0.0.1:8000/scripts/benchmark-scroll.html?n=320"
```

对照旧版本时，把该提交的 `StudyReader/Resources/Reader/reader.js` 取到能被服务到的位置，再加 `&src=` 指向它。

---

# 搜索、附件尺寸、状态写入与公式 DOM

2026-09-18。基线为上一节结束时的工作副本。四项改动分别针对：搜索每次重读整库、图片加载时版面跳动、阅读状态在主线程编码、超长公式文章的首次布局。

## 1. 全文搜索：并行扫描，不做前缀收窄

原计划是「新查询以旧查询的结果为范围」，实测不成立，已放弃。`localizedStandardContains` 按整个字符匹配，一份含连字 `ﬁ` 的正文回答 `confi` 却不回答 `conf`：

```
"conf"  -> false
"confi" -> true
```

从 LaTeX 生成的 PDF 里粘贴来的资料普遍带 `ﬁ` `ﬂ` 连字，德语 `ß` 与 `ss` 同理。以旧结果收窄会让这类文章在继续输入后永久消失，属于静默丢结果，比慢更糟。

改为把扫描分给多个核：每个工作单元取第 n、2n… 篇，相邻文件大小相近所以分配均匀，同一时刻每个工作单元只驻留一篇正文。匹配规则、缓存和取消行为都没有变。

`scripts/benchmark-library.swift`，同一台 arm64 Mac，1000 篇合成资料共 47.1 MB：

| 查询 | 优化前 | 优化后 |
| --- | ---: | ---: |
| 贝（全部命中） | 183.0 ms | 41.5 ms |
| 贝叶斯公式（全部命中） | 182.4 ms | 41.0 ms |
| 不存在的知识点（未命中） | 1064.3 ms | 188.8 ms |
| qzxmissingterm（未命中） | 591.8 ms | 108.8 ms |

100 篇时中文未命中查询为 106.1 ms → 20.2 ms。查询期间 MainActor 探测的最大间隔仍是 6.3 ms 左右，没有变差。这台 Mac 的核数多于 iPhone，真机上的倍数会小一些。

## 2. 附件尺寸：先占好位置

导入的图片按文件头读出像素尺寸（`CGImageSourceCopyPropertiesAtIndex`，不解码整张图），按资料包缓存、随 `contentRevision` 失效，和正文一起在后台取出，随排版数据交给页面。渲染时写入 `width` / `height`，浏览器据此先占好方框。

- 正文不再随图片解码上下跳动。
- 已知尺寸的文章恢复阅读位置时不再等图片：原来最多等 1500 ms。JavaScript 回归实测未知尺寸时 300 ms 仍未完成，已知尺寸时 400 ms 内完成。
- 尺寸表按资料包内的相对路径为键，两端都用 NFC 比较，中文文件名不会因为文件系统返回分解形式而错过。
- 文件缺失时表里没有它，于是既不写尺寸也照旧等待——缺图提示的高度和图片不同，这条路径必须保留原行为。
- 排版缓存的键加入尺寸表签名，换了图片不会命中旧 HTML。

## 3. 阅读状态编码移出主线程

`writeState` 原来在 MainActor 上 `JSONEncoder().encode(state)`，再把写盘交给串行队列。现在快照按值交给同一个队列，编码和写盘都在队列上完成，顺序不变，`flush` 仍然等到字节送出。

同一台 Mac 上编码这份状态的耗时：200 篇 2.4 ms、1000 篇 8.8 ms、3000 篇 25.9 ms（各 12 次取中位）。滚动停下 0.7 秒后触发的那次保存原来就落在主线程上，真机更慢。

## 4. 公式的 MathML 副本：只在读屏时渲染

原计划是给正文块加 `content-visibility: auto`，跳过屏幕外的布局与绘制。实测四种写法（iPhone 18 Pro 模拟器 Safari，320 节 / 1921 个阅读块 / 64,321 个元素 / 页高 185,132 px，帧间隔取每帧 45 px 的 200 帧程序滚动）：

| 写法 | 首次完整布局 | 页面总高 | 帧间隔均值 / p95 | 超过 20 ms 的帧 |
| --- | ---: | ---: | ---: | ---: |
| 不加 | 305 ms | 185,132 | 16.8 / 17.0 ms | 2 |
| `.reading-block { content-visibility: auto }` | — | **+8.2%** | 17.8 / 29.0 ms | 53 |
| `.katex-display { content-visibility: auto }` | — | +2.9% | 16.8 / 23.0 ms | 15 |
| `.katex-mathml { content-visibility: auto }` | 216 ms | 185,132 | 18.2 / 28.0 ms | 73 |
| `.katex-mathml { contain: strict }` | 307 ms | 185,132 | 16.7 / 17.0 ms | 0 |
| **`.katex-mathml { content-visibility: hidden }`** | **204 ms** | **185,132** | **16.7 / 17.0 ms** | **0** |

`content-visibility: auto` 每一帧都要重新判断哪些内容相关，并为刚进入视口的公式重做布局，结果是滚动更差而不是更好；加在正文块上还会因为 `contain: layout` 改变外边距合并，让页面凭空长高 8%，进而使阅读进度百分比失真。这两种都没有采用。

实际采用的是最后一行：KaTeX 为每个公式额外输出一份 1px、被裁剪的 MathML 副本，只有读屏软件会用到它。它占了全部元素的 30%，却不影响任何几何。跳过它之后页面总高逐像素相同，滚动帧间隔不变，首次布局少三分之一。

为了不牺牲无障碍，App 检测 VoiceOver（iOS 还包括「切换控制」）是否开启，开启时给页面加上 `data-assistive`，MathML 恢复渲染；iOS 监听状态变化通知即时生效，macOS 在打开文章和回到前台时重新读取。公式原文始终留在 DOM 里，点击公式复制 LaTeX 和阅读位置的段落摘要都不受影响。

端到端用打包好的 `reader.js`，同一篇 320 节文章：首次打开 678 ms → 481 ms，命中排版缓存的再次打开 471 ms → 377 ms。

顺带测到的一件事：这篇文章里 markdown-it 加 KaTeX 的排版只占约 10–23 ms，`innerHTML` 解析约 32 ms，其余 300 ms 以上都是首次布局。排版缓存省下的是那几十毫秒，不是打开一篇长文的主要成本。

## 验证范围

- 25 项 JavaScript 测试通过，新增：已知尺寸的附件写入 `width`/`height` 且未知的不写、附件路径经过百分号编码与分解形式后仍能对上、尺寸表变化不会命中排版缓存、已测量的附件不再等待解码、`data-assistive` 的开关不需要重新渲染文章。
- iPhone 18 Pro 模拟器 81 项 XCTest 通过（原 78 项）。新增三项：附件尺寸来自文件头并随 `contentRevision` 失效、尺寸表的键与阅读器解析出的地址一致、真实 WKWebView 下跳过 MathML 副本后页面总高逐像素相同、公式原文仍在 DOM 中、页内查找仍能命中正文。
- 模拟器实机操作确认：公式正常显示，点击公式仍弹出「公式原文」并显示正确的 LaTeX。
- Mac 90 项 XCTest 通过（原 87 项，加上本轮新增的 3 项）。

## 附带修好的：Mac 的 XCTest 起不来

`xcodebuild -destination 'platform=macOS' test` 一直失败。先看到的是 `The test runner hung before establishing connection.`，退出正在运行的同 Bundle ID 的 App 之后，真正的原因才露出来：

```
code signature ... not valid for use in process:
mapping process and mapped file (non-platform) have different Team IDs
```

`StudyReader.app` 被 `Apple Development` 证书签名并开启了 Hardened Runtime，`StudyReaderTests.xctest` 却是 ad-hoc 签名，dyld 因此拒绝把测试包加载进宿主进程。

`project.yml` 里两个 target 都引用 `localDebugSigning`，在 macOS 与模拟器的 Debug 下使用本地签名；但生成的 `project.pbxproj` 只有测试 target 保留了这组设置，App target 的 Debug 被换成了 `CODE_SIGN_STYLE = Automatic` 加 `DEVELOPMENT_TEAM`，两边于是对不上。把那四行按 `project.yml` 的原意补回 App target 的 Debug 配置：

```
"CODE_SIGN_IDENTITY[sdk=iphonesimulator*]" = "-";
"CODE_SIGN_IDENTITY[sdk=macosx*]" = "-";
"CODE_SIGN_STYLE[sdk=iphonesimulator*]" = Manual;
"CODE_SIGN_STYLE[sdk=macosx*]" = Manual;
```

这四行只覆盖 macOS 和模拟器，`DEVELOPMENT_TEAM` 原样保留给 iPhone 真机与 Release。清掉 `.build/Mac` 重新构建后，App 与测试包都是 ad-hoc、Team 一致，Mac 90 项、模拟器 81 项 XCTest 全部通过。如果以后在 Xcode 里改过签名又出现同样的报错，先比较这两个产物的 `codesign -dvvv` 输出。
- 未在真机上测量。模拟器使用 Mac 的处理器，上面所有毫秒数在 iPhone 上都会更大。

## 搜索容错、片段与正文定位

2026-09-18。搜索返回每篇的短片段、UTF-16 高亮范围及正文行位置；读取错误按文件收集，取消任务仍立即退出。保留六个扫描 worker 和最近八个完整查询缓存，不缓存失败批次，也不保留整篇正文。普通 LF 文本跳过 BOM、YAML 和 CRLF 的替换处理，计算位置只计数换行字节。

用上面的 `benchmark-library.swift` 重新编译 `-O` 测量，1000 篇合成资料共 47.1 MB，文件系统缓存已热，单次测量，不含 200 ms 输入防抖：

| 查询 | 结果 | 耗时 |
|---|---:|---:|
| 贝叶斯公式 | 1000 篇，含片段及位置 | 59.4 ms |
| 不存在的知识点 | 0 篇 | 203.9 ms |
| qzxmissingterm | 0 篇 | 124.8 ms |

这些查询期间，5 ms 主线程探针的最大间隔为 6.4 ms 以内；资料库加载为 45.6 ms。数值不是实际设备的界面响应分位数。正文高亮仅处理命中的内容块，清理高亮时也只合并改动过的文本节点，不遍历整篇公式 DOM 做文本整理。

真实 WKWebView 测试覆盖排版前排队的搜索跳转、折叠答案自动展开、已选中文章再次定位、清空待执行查询、跳转后的阅读记录及进程恢复不重放旧搜索；JavaScript 测试额外覆盖重复段落、Unicode、跨行内元素高亮、表格、代码、LaTeX 和 HTML 转义。Mac 与 iPhone 模拟器均通过相关回归。
