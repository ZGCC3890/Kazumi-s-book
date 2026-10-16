# Kazumi's book 架构审查记录

实施基线：上游 `025dcb5`，版本 2.3.9。审查依据为同目录《Kazumi-轻小说实施方案.md》。本记录只记录实际审查证据，不能替代设备测试。

维护位置：两份文档现已移至用户 fork 的 `docs/novel/`，作为唯一 canonical 文档。用户最新明确范围：wenku8.cc、syosetu.com，Android/Windows 与官方共存，插图原位置显示并可放大，卡片播放每次打开选源。产品为独立软件 Kazumi's book（仓库 Kazumi-s-book），main 跟踪 upstream/main，产品开发在 feature/novel-reader。

规则维护决策：同一 fork 根目录 `novel_rules/` + `catalog.json`，默认读取 feature/novel-reader 的 raw GitHub 索引，可自定义索引；客户端导入/更新/删除独立于视频规则；禁止 assets 再维护规则副本。

## A01：WebDAV 现有发布助手不能直接作为小说的原子替换

- 状态：方案已处理，待小说实现及故障注入验证。
- 证据：`lib/services/sync/webdav_remote_file_commit.dart:31` 开始上传到临时路径，随后 `_removeIfExists(destinationPath)`，最后 `rename(temporaryPath, destinationPath)`。
- 判断：目标删除和 MOVE 之间存在空窗；源码顺序已核实，尚未在真实服务端重现。不能宣称当前方法原子替换。
- 小说方案：独立不可变设备快照，最终路径此前不存在，旧快照保留；复用连接与全局队列。
- 验收：PUT 失败、MOVE 失败、目录读取与发布交错时，最后有效状态仍能读取；不修改现有视频/弹幕发布行为。

## A02：弹幕屏蔽的 LWW 不能用于阅读位置

- 状态：设计约束已下发，待 M1 审查。
- 证据：`lib/modules/danmaku/danmaku_shield_sync.dart:19` 的 `_compareTo` 先比较 updatedAt，再比较 deviceId 和 deleted。
- 判断：该比较无法证明两台离线设备上哪个阅读位置在因果上更新，也无法保留主动回退和并发阅读意图。
- 小说方案：逐实体修订向量；并发候选保留；显式选择后产生包含双方因果的新修订。
- 验收：设备时钟偏移、向前重读、删除与修改并发不会静默丢弃候选。

## A03：追番卡片按钮必须纳入布局计算

- 状态：已下发，待 UI 实现。
- 证据：`lib/pages/collect/collect_library_card.dart` 的 `_CollectPosterCard.extent`、`_detailsHeight`、`_isStacked` 根据状态、评分和文本缩放计算卡片高度。
- 判断：仅在 Widget 增加按钮会与固定高度冲突，尤其是小屏和放大字体。
- 验收：卡片与列表两种布局、状态可见/隐藏、字体缩放、两个按钮事件互不干扰；图标有语义标签与合适点击区域。

## M1 审查清单

2026-10-17 首轮源码审查已向实施者发送以下待验证问题：

- `NovelSyncState.edit` 合并所有并发修订后直接覆盖；若被自动保存调用，会未经用户选择消除冲突。要求普通编辑与显式 resolve 分开，并用“并发后自动保存”实验验证。
- 同一 clock 的 payload 比较直接使用 `jsonEncode`，对象键顺序变化会被误报为内容不同；要求结构等价用例 `{a:1,b:2}` 与 `{b:2,a:1}`。
- `NovelLocator.locate` 对章节末尾 quote 为空、prefix 非空的保存位置返回 null；要求章节末尾恢复用例。
- 当前 `NovelPosition` 仅有文本锚点；连续插图、纯插图章节无法区分位置。用户新增插图要求应在模型阶段完成图像/内容块定位设计。
- capture 参数是规范化文本偏移，UI 必须提供原文到规范化文本的偏移映射；不能传原文字符数或滚动比例。
- Unicode 属性正则是否支持必须以实际 Dart VM 运行结果确认，不能用别种语言的正则引擎代替。

上述问题是代码审查结论及对应实验要求，尚未标记为自动验证通过。

第二轮源码核对：普通 edit 已拒绝并发，新增 resolve；payload 比较已递归排序对象键；Position 已增加 chapterDigest/imageHash，章节文本不变时可恢复末尾。以上仅确认修正代码存在，等待对应测试结果。imageHash 的实际内容下载、哈希核验和图像块恢复仍需阅读器集成证明。

第二轮新增待处理项：

- `NovelService.bind` 在新建 edition 时总创建新 work，尚无法表示“同一 work 下的中文文库版与日文 Web 版”。需要显式 existingWorkId 或等价业务流程，不能通过同标题自动猜测。
- 正文/目录缓存 key 当前只有 sourceId 与 URL；规则更新后默认仍读取旧解析结果。需要规则版本/解析版本参与缓存身份，并在阅读 UI 提供明确缓存状态与刷新动作。
- 阅读器尚未接入；必须用原文到规范化文本的映射定位，imageHash 字段本身不能证明插图恢复功能已实现。

## A04：不可变快照需要增量下载

- 状态：源码修正已核对，待传输协议测试。
- 证据：新增 `WebDav.syncNovels` 遍历全部最终 JSON 文件并逐个 `read2File`，NovelService 每 30 秒触发轮询。
- 判断：即使无更新，每轮也重复下载全部历史快照，传输量随使用时长增长；只用内容 hash 避免重复上传不能解决重复下载。
- 方案：按连接域保存已校验且成功合并的文件名，只下载未见文件；先持久化合并结果，再确认已读标记。
- 验收：第一次 N 次 GET，第二次 0 次 GET，新快照 1 次 GET；失败不可标成功；切换服务器/用户重新建立对应域。
- 复核：已增加 knownSnapshots、server/user/path 作用域和 `_seen`；本地 state 与 seen 在单 JSON 记录中一并提交，merge 成功后确认已读，publish 成功后确认自身快照。建议提取注入 list/read/write/move 的纯 Dart 传输协调器，以独立 harness 测真实生产代码，不复制协议算法作为测试替身。

## M1 状态表

| 检查项 | 状态 | 证据 |
| --- | --- | --- |
| 小说 canonicalWorkId 独立于动画 ID，版本独立 | 已实现待验证 | NovelWork / NovelEdition |
| 同一本作品多季绑定、不同译本位置隔离 | 已实现待验证 | existingEditionId / existingWorkId 已提供；真实绑定交互待集成 |
| 位置使用卷章/文本语义，支持主动倒退 | 纯算法自动验证通过 | NovelPosition / NovelLocator；图像恢复待集成 |
| 手动书签独立实体且有删除墓碑 | 已实现待验证 | bookmark 独立 key，null tombstone |
| 本地写入串行，修订与数据一同持久化 | 已实现待验证 | NovelService._commit 的单 state 记录及 flush |
| 逐实体因果合并，并发候选可显式解决 | 纯算法自动验证通过 | NovelSyncState.edit / merge / resolve；含并发删除与回读 |
| 未知 schema 明确拒绝写入，旧数据明确迁移 | 纯算法自动验证通过 | version 2 拒绝用例通过；尚无旧小说版本，视频兼容待集成 |
| 设备标识/计数不会从远端覆盖 | 已实现待验证 | deviceId 本地独立 key；实体修订与 payload 一并保存 |
| 单元测试与持久化重启验证 | 纯算法通过，应用验证受环境阻塞 | 23 项纯 Dart 测试通过；Flutter native-assets 构建在 MSVC 发现阶段失败；持久化重启尚未测 |

### 独立 M1 自动验证记录

- 测试文件：`test/novel_domain_test.dart`，23 项测试；合并交换律覆盖 16 个输入组合，结合律覆盖 64 个组合；另含并发删除/解决、主动回读、schema、卷隔离、章号及文本锚点。
- 实际命令：工作区 Flutter 3.47.7 执行 `flutter test test/novel_domain_test.dart`。
- 结果：exit 1，未进入测试断言。`ech_http 0.2.1` native-assets hook 报 `Bad state: Install Visual Studio C++ build tools`。
- 根因证据：hook `_toolchain` 用 `C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe` 查找 VC.Tools.x86.x64；该文件在当前环境不存在。CMake 在 PATH 中，cl.exe 不在 PATH 中。
- 日志：工作区 `work/novel-domain-tests.log`。未通过删除依赖、屏蔽 hook 或降级工具链伪造完整验证成功；等待工具链就绪后重跑。
- 独立算法验证：按主实施者授权，在 `work/novel_domain_harness` 建立仅依赖 test + crypto 的 Dart 包。复制相同 23 项测试，仅将测试框架 import 改为 package:test 并以 relative import 直接引用应用的模型、合并及定位源码；业务源码与 app 依赖没有改动。
- 实际运行 `dart test test/novel_domain_test.dart`，exit 0，结果 `+23: All tests passed!`。日志为工作区 `work/novel-domain-harness-tests.log`。已证实当前 Dart VM 的 Unicode 属性规范化、合并代数性质、冲突/墓碑/回读及文本定位；该结果不代表 app 原生构建、UI、Hive 持久化、图像锚点或 WebDAV 实机验证通过。

## A05：共存安装需要配套更新源

- 状态：已下发，待打包阶段验证。
- 证据：`lib/request/config/api_endpoints.dart:29` 的 latest release 地址为官方仓库；`init_page.dart` 与 onboarding 会自动检查更新。
- 方案：应用发布更新源改为用户 fork；没有发布版本时显示真实状态，不取官方包代替。保留官方署名、许可证和视频规则来源。
- 验收：应用检查更新不会指向 Predidit/Kazumi 安装包；独立包标识、Windows 程序名及本地数据目录同时验证。

## A06：阅读器定位与排版的独立实验

- 状态：3 项缺陷已复现，已交实施者修复；不是环境失败。
- 实验环境：`work/novel_layout_harness` 仅 Flutter、crypto 与 flutter_test，直接 relative import 应用真实 NovelLayout；未更改 app 依赖。运行 `flutter test test/reader_layout_review_test.dart`，exit 1，三个正确行为断言均失败。日志 `work/novel-layout-review-tests.log`。
- 前置插图：内容块为“图片、文字”，首次打开按当前 reader 传 textOffset=0/imageBlock=null，`fragmentAt(0)` 实际返回 1，而章节起点应为 0。根因是文字偏移 0 无法表示位于首段文字之前的插图起点。
- 重排漂移：按当前 reader 的 `fragmentAt → postFrame _moved → capture` 路径模拟，初始锚点 53，宽度依次 240/150/220/180/240，保存位置变为 48/42/33/27/24。用户没有阅读操作却回退 29 字符。根因是把新排版的行首当作新的阅读意图保存；重排应保留语义锚点，只有实际阅读动作更新位置。
- 系统字号：布局宽 240，TextPainter 以 scale 1 测量；Text 按系统 scale 2 渲染时该行实际宽 480。根因是测量与渲染 textScaler 不一致，maxLines=1 会裁切正文；应使用同一缩放参数。

### 阅读器其他待集成验证项

- 滚动模式 PageDown：当前 offset=0、viewport=500、maxScrollExtent=100 时，`next=450` 直接切下一章，跳过本章最后 100px。要求先滚到当前边界，已经在边界时再跨章；反向同理。
- 本地保存失败：`_save` catch 后正常返回，退出/切章仍继续，切章还会清除错误。用 savePosition 抛写入异常的服务替身验证停留原页并保留错误；不得把尚未落盘的位置显示为已保存。
- 方向恢复：设置使用 setPreferredOrientations，当前 dispose 仅恢复 SystemUI。Android 锁横屏后退出阅读页，验证其他页面恢复进入前方向策略。
- 反向跨章：当前 `_load(index)` 总从章首开始；从本章开头向前翻页应进入上一章末尾，目录主动选章仍从章首，二者应明确区分。

### A06 修复后的生产阅读页回归

`test/novel_reader_test.dart` 通过独立最小 Flutter 包直接 import 生产 `NovelReaderPage`，以 `NovelReaderStore` 测试替身控制内容和写入失败，没有复制阅读器实现。首轮 6 项全部通过：首图可见且按图片字节保存哈希；窗口/字号重排保持 offset 53；系统字号 2 倍不裁切；保存失败阻止退出且重试可离开；PageDown 先到本章末尾；PageUp 跨章落在上一章末尾。日志为 `work/novel-reader-widget-tests.log`。

新增第 7 项发现剩余根因：失配恢复弹窗选择“从本章开始”时，`restore` 仍非 null，未进入首图 imageBlock/imageHash 初始化，实际滚动位置 17.44 而不是 0。要求把用户确认重开与首次阅读统一为章首定位。该回归已落在同一测试文件，待实施者修正重跑。方向恢复代码已加入，但实际 Android 方向策略仍待设备验证。

复测：实施者以统一 fresh 分支处理首次阅读和显式重开，7 项生产阅读页用例全部通过。原 3 项布局诊断也已更新为当前调用契约并通过，综合日志 `work/novel-all-reader-tests.log` 记录 `+10: All tests passed!`。其中 3 项布局测试与 7 项页面测试的覆盖范围不同，不重复计为新的端到端验收。

### A07 生产 WebDAV 交换自动验证

`test/novel_webdav_exchange_test.dart` 的 9 项直接执行 `NovelWebDavExchange`，纯 Dart harness 结果全部通过，日志 `work/novel-webdav-exchange-tests.log`。覆盖 N→0→1 增量 GET、读取失败不推进 seen、文件哈希损坏拒绝、本地提交失败不发布、PUT/MOVE 失败保留旧快照与新本地位置并可重试、双设备同列表交错发布与显式冲突收敛、关闭前及 PUT 后关闭不发布。

测试替身可观测 read/write/move 并注入异常，证明实际交换算法的顺序与状态约束；不能证明真实 WebDAV 服务器 MOVE 或 Hive 落盘原子性。设备内持久化、真实凭证/目录、远端权限与服务端协议仍待集成。

### A08 实际规则 JSON 的 fixture 验证发现解析阻断

`test/novel_rule_test.dart` 从仓库 `novel_rules/wenku8.json` 与 `syosetu.json` 读取生产规则。8 项中首轮 3 项通过（图文原顺序、登录页报错、JSON allcount 跳过），5 项失败，日志 `work/novel-rule-tests.log`。这些是合成结构样本，不标记为匿名在线通过。

- `_text/_link` 参数为 dynamic，对 DOM Element 动态调用 `queryXPath`。Dart extension 不参与动态方法派发，单结果详情及目录调用实际抛 NoSuchMethodError；应改为正确静态类型/统一节点访问。
- 现用 XPath 库对 `concat(' ',normalize-space(@class),' ')` 抛 Unsupported function，阻断 syosetu 正文和目录；规则必须使用该实际执行器支持的表达式。
- 文库8搜索 items 的包含路径、and 及嵌套谓词表达式被执行器报 ParserException。需要验证兼容表达式仍准确选中结果卡片，不能空结果后静默换解析路线。

第二轮：统一 XPathNode 静态访问、简化 XPath，并为目录显式声明 sequence-css 顺序遍历模式后，8 项中 6 项通过。剩余文库8搜索用例确认该库还不支持 `[@tiptitle]` / `[@vspace]` 属性存在谓词；正在修正并复测。CSS 模式是 schema 显式选择，不能作为 XPath 失败后的隐式备用路径。

第三轮：文库8单书封面按实读 DOM 的 `vspace=0` 更新 fixture 后通过。多结果卡片仍失败；独立 probe 证实此执行器的 `..` 返回当前节点，`../../p[1]` 为空，`parent::b/parent::div/p[1]` 直接报无效 XPath。日志 `work/novel-xpath-probe.log`。这是执行器能力与规则设计不匹配，不能按浏览器 XPath 支持范围推断该库支持；要求显式选择有可验证父子关系的规则模式。

最终复测：HTML 搜索以规则声明的 `itemsMode: css` 选择完整卡片，内部字段只用已验证的向下 XPath；fixture 保留实读卡片 `width:373px` 结构。8 项规则用例全部通过，与 23 项领域测试及 9 项 WebDAV 测试合跑 `+40: All tests passed!`，日志 `work/novel-all-domain-tests.log`。规则协议及执行器限制已补入 `novel_rules/README.md`。

### A09 移动插图的错误准确恢复

第 8 项生产阅读页测试把同一 PNG 从文本段前移到段后，保持正文和图片字节完全一致。旧恢复逻辑只验证全章文本锚点与唯一图片哈希，没有验证图片所在 block 的邻接文本位置，实际未显示确认弹窗。证据为 `test/novel_reader_test.dart` 及 `work/novel-reader-widget-tests.log`。修正要求把图片前规范化文本偏移与已定位的文本锚点比较；不一致时保留旧位置并让用户确认。该问题独立于 A06 的首次首图恢复。

修正复测通过：图片恢复现在同时核验唯一哈希与图片前规范化文本长度。移动图片会先要求确认，且确认前不保存错误位置。另将窗口/字号重排测试覆盖滚动、分页两模式，均保持原锚点 53。生产阅读页共 9 项全部通过，结合 3 项布局契约测试为 `+12: All tests passed!`，日志 `work/novel-all-reader-tests.log`。

### A10 章节映射及进度拖动回归

生产 `NovelReaderStore` 增加 `mappedChapter` / `confirmChapterMapping`，阅读位置与书签共用 `_restoreChapter`。新增 4 项生产阅读页测试全部通过：人工选章后回到原源位置再次打开无需重新选章；旧源书签复用同一映射；已映射目标从目录移除时明确重新询问并保留旧进度；实际拖动本章进度 Slider 后保存新的可见文本锚点。

测试替身返回反序列化的新 Chapter 对象，确保 Reader 以 URL 在当前目录定位，而非依赖对象引用。该替身只模拟映射存储，不能替代 Service 的 Hive 重启、双向映射因果实体或真实 WebDAV 验证。当前生产阅读页共 13 项通过，日志 `work/novel-reader-mapping-tests.log`。仓库测试总数为 53（23 领域 + 9 交换 + 8 规则 + 13 阅读页），另有 3 项工作区布局契约实验。

后续新增拆章候选纠正用例：旧映射指向第一章但锚点在第二章，Reader 明确显示定位不匹配；用户点“重新选择章节”并选第二章后，准确恢复 offset 7，确认前没有写入错误位置。第 14 项通过，同日志记录 `+14: All tests passed!`。当前映射仍以章节为粒度；一对多拆章可能需要再次确认，后续若升级为位置相关映射须另行设计，不能把当前行为宣传成拆合章全自动精准恢复。

### A11 真实 Service / Hive / HTTP WebDAV 集成测试

新增 `test/novel_service_integration_test.dart`，4 项测试使用生产 `NovelService`、真实 Hive 文件关闭重开、两个独立设备目录以及 loopback HTTP 服务；生产 `webdav_client` 实际执行 OPTIONS/MKCOL/PROPFIND/GET/PUT/MOVE，不替换 client/transport。覆盖本地位置/书签/删除墓碑/外观/双向映射重启，已见快照重启后的增量 GET，两个离线设备冲突与显式回读选择，以及 PUT/MOVE 失败后旧远端快照与本地位置保留。旧视频快照 sentinel 必须从未被读写。

当前静态检查 `dart analyze test/novel_service_integration_test.dart` 为 No issues found，日志 `work/novel-service-integration-analyze.log`；尚未运行，待第二轮 CI。测试服务的 collection self 响应、临时文件和失败状态均可观测；它不代表所有商业 WebDAV 服务的实现兼容性。

同一磁盘重启场景增加自定义规则索引 URL 的保存/重开断言，不增加测试项数；规则页使用成功加载时的索引 URL 解析相对下载地址，并检查索引 ID 与下载规则 ID 一致。新断言的运行结果随第二轮 CI 记录。

### CI 和范围复核

首轮提交 `143256f` 已经完整 CI 验证：[run 38945602888](https://github.com/ZGCC3890/Kazumi-s-book/actions/runs/38945602888) / checks job `117123810541`，262 项 Flutter 测试全部通过，分析通过。Windows/Android 原生包构建当时仍运行；后续映射及 A11 测试不在该首轮结论内。本地 MSVC 缺失仍如前记录，但不能据此说完整应用测试始终未运行。

范围复核：外观设置按设备本地保存，云端同步只覆盖作品关联、位置、书签及恢复映射；交互式规则测试工作台为可选维护增强。自动同步以已有轮询和前台恢复满足基础触发要求，不把新增网络状态监听库当作独立硬要求。上游维护使用 `dev/sync-upstream.ps1` 直接合入产品分支，main 保持官方镜像；不要求新增仓库、账号系统或评论功能。

首轮 CI 最终状态：`143256f` 的 checks、Windows、Android 三个 job 均 success。Windows release ZIP artifact `12066986462` 约 43 MB，Android debug arm64 APK artifact `12066307689` 约 89.6 MB。原生构建已经通过；桌面/手机安装共存、真实源匿名访问和真实跨设备服务仍未验收。第二提交新增业务与测试须重新等待对应 CI，不能复用首轮结果。

### A03 追番卡片实际布局回归

实施者新增 `test/book_collect_actions_test.dart`，直接渲染生产 `CollectLibraryView` 的 4 种情况：360px 海报卡、360px 海报卡配 2 倍文字、360px 列表配 2 倍文字、1440px 列表。首轮实际发现新按钮导致底部溢出 44/76px，根因是竖屏固定 3 列而忽略卡片最小宽度。按最小宽度和文字缩放计算列数、竖屏最多 3 列/横屏最多 6 列后，4 项全部通过；play/read 按钮分别触发各自回调且不误触卡片详情。日志 `work/collect-widget-tests.log`。这验证卡片渲染和事件隔离，视频选源及播放仍需完整应用路径验证。

第二批累计新增 13 项仓库测试：Reader 映射/进度/重新选章 5 项、真实 Service/Hive/HTTP 4 项、追番卡片 4 项。前者与卡片已在独立 harness 跑过，真实 Service 集成仅静态分析通过，均等待第二提交的完整 CI 结果。书架“添加小说”入口已加入，支持独立搜索且无需关联动画，真实绑定路径待集成。

### A12 匿名公开详情被登录框检测误判

最新匿名请求日志 `work/public-source-probe.log` 表明：文库8 `/book/4343.htm`、`/novel/4/4343/index.htm`、`/novel/4/4343/177990.htm` 均 HTTP 200；搜索虽最终状态 200，实际最终地址为 `login.php`。公开详情页页眉也有 password 字段，导致原 `loginRequiredXPath=//input[@type='password']` 把公开内容判为登录页。

第 9 项规则 fixture 在公开详情中保留页眉登录表单，真实执行 catalog 时复现 `书源返回登录页` 错误，未继续请求目录，日志 `work/novel-public-detail-test.log`。要求依据明确的最终响应 URL 登录路径识别，而非页面任何密码框；真实登录重定向仍须报错。此轮 HTTP 证据不等于生产 adapter、图片或目标设备阅读全部通过；syosetu API 本机仍为 Apache 403。

修正复测通过：`_root(NovelResponse)` 按规则的 `loginRequiredUrlPattern` 核对最终 URL；新增显式 `bookFromUrl` 和能力 URL 模式。公开详情页眉登录框、直接 URL 详情及真正 login.php 重定向都由新增回归覆盖，规则测试总数 11，全部通过，日志 `work/novel-rule-tests.log`。

### A13 真实目录补齐单元格及图文样本验证

匿名捕获的文库8目录有 24 个 `td.ccss`，其中 1 个仅含 `&nbsp;`。生产 adapter 把所有单元格都当章节，实际抛缺少链接异常，证据 `work/novel-captured-parse.log`（首轮）及 `work/novel-public-catalog-structure.log`。在既有目录 fixture 加入该空单元格复现后，规则改成只选 `td.vcss, td.ccss a`，字段以 `.` 读取章节链接；不吞掉解析异常、不把空节点伪造章节。11 项规则全测再次通过。

真实解析结果：无 Cookie Python 捕获公开详情、目录、正文、插图章，再交给生产 `XPathNovelAdapter`，得到书名/作者、23 章、93 文本块、13 插图块；图片顺序与原 DOM `#content img` 顺序一致。日志 `work/novel-captured-parse.log` 明确 `productionTransportProven:false`。首图由匿名 Python 请求取得 HTTP 200、`image/jpeg`、480755 字节，文件头为 JPEG，SHA256 `1f865d0e0170b658c57192ce5f982ebd12dba19b6d7711f892c084e935ee7c4c`，日志 `work/novel-public-image-capture.log`。

Dart HttpClient 在直连及观测到的系统代理路径均返回 Cloudflare 403，采用生产浏览器 UA/语言仍如此；根因未确认，不改传输或引入访问检查备用路线。上述样本/图片成功只证明公开资源和解析逻辑，不宣称应用已能联网读该站。第二批规则新增 3 项，加上 A14 回归后第二提交新增测试共 17 项，完整 CI 结果另记。

第二轮 CI 增加待验证的原生检查：Windows 构建后读取 EXE ProductName/CompanyName，启动 15 秒检查进程存活及 `APPDATA/ZGCC3890/Kazumi's book/hive/setting.hive` 创建，再结束该测试进程；Android 用 aapt 核验 APK applicationId `com.zgcc.kazumisbook`。这些检查尚未执行成功；即使通过，也只证明标识、启动和独立目录，不替代真实 UI、阅读或双版本并行使用验收。

### A14 未移动退出覆盖已同步进度

真实 ReaderPage 回归先保存本地 offset 53，再通过 fake store 从该因果状态写入远端 offset 9 并通知；修订仍为唯一值，读者未滚动直接返回。修复前保存调用从 1 次增长到 2 次，旧 53 覆盖新 9，日志 `work/novel-reader-remote-overwrite-red.log`。根因是 Reader 退出总提交 `_location`，而 Service 的当前值已经被远端改变，不能代替会话内“此位置是否已保存”的判断。

修复在冲突/恢复检查之后，按不可变位置对象记录本 Reader 已成功提交的快照；相同对象不重复写入，实际移动产生新对象仍保存，失败不标记成功，异步完成记录捕获的快照而非可能已改变的当前值。未取最大进度。原磁盘失败测试改为先实际滚动制造未保存位置，再验证失败阻止退出。完整 Reader 15 项通过，日志 `work/novel-reader-remote-overwrite-green.log`；新增用例明确远端回读 9 保留，待第二轮完整 CI。

### A15 连载目录与正文显式刷新

Service 已有强制刷新参数，但 Reader 原未暴露操作，缓存目录无法主动取得连载新增章。新增“刷新目录与正文”，先保存再将 refresh=true 传至目录、当前正文及恢复过程中手动重新选择的章节；错误页重试同样强制刷新。已保存不可变位置的去重位于冲突检查之后、恢复中检查之前，刷新失败可退出而不重复写旧位置。

新增实际 ReaderPage 用例：刷新 fake 返回第二章和前插正文，验证两个调用都收到 refresh=true，目录显示第二章，原 quote 保持、offset 按插入文本的标准化长度平移、正文 digest 更新。另一用例让正文刷新抛网络错误，验证页面显示具体错误、返回成功且保存调用数不增长。完整 Reader 17 项通过，日志 `work/novel-reader-refresh-tests.log`。第二提交新增测试总数随这两项增至 19，完整应用测试结果仍等第二轮 CI。

### A16 第二轮完整 CI 与维护脚本验证

提交 `f1a33b8` 的 [run 38950139335](https://github.com/ZGCC3890/Kazumi-s-book/actions/runs/38950139335) / checks job `117139163024` 成功，日志明确 `281 tests passed`；分析通过，输出 28 个 info。此前待运行的 4 项真实 Service/Hive/loopback HTTP 集成逐项通过：重启恢复位置/书签/本地设置/双向映射；两个独立数据目录经生产 WebDAV 客户端增量读取并解决离线冲突；PUT 失败保留；MOVE 失败保留。旧视频 sentinel 在这些场景中不被读取/修改，证据摘录 `work/ci2-checks-evidence.log`。这关闭自动集成待验项，不等于所有商业 WebDAV 或两台真实设备已验证。

实施者在 Windows PowerShell 5.1 实际运行 `dev/sync-upstream.ps1 -CheckOnly`，退出 0，`work/upstream-check.log` 为“上游待合并提交：0”。脚本 UTF-8 BOM 保证 5.1 中文兼容；这次没有需要合并的上游提交，因此只证明检查路径，不宣称冲突合并路径已经演练。

第二轮原生步骤验证成功：Windows job `117140046552` 的 release 编译、产品标识与原生启动、上传产物均通过；启动步骤先检查 ProductName=`Kazumi's book` / CompanyName=`ZGCC3890`，运行 15 秒后确认进程仍存活、独立目录 `APPDATA/ZGCC3890/Kazumi's book/hive/setting.hive` 已建立。Android job `117140046441` 成功，编译 APK 后 aapt 日志明确验证 `com.zgcc.kazumisbook`。原生证据摘录 `work/ci2-native-evidence.log`；Windows artifact `12068182527` 为 43017667 字节，Android artifact `12068976800` 为 89612752 字节。产物绑定 `f1a33b8`，后续仅文档提交不代表重新构建。

最终 Public REST 核对：该 run 的 checks、Windows、Android 三个 job 均 completed/success。这些结果证明 CI 环境中的真实原生启动、独立存储和编译产物身份，不证明用户手机/桌面的双版本共存、完整阅读 UI、图片缩放、Dart 访问文库8或真实跨设备云服务已通过。Dart 书源 403 与真机阅读边界仍如 A13，不因 CI 通过而消除。

### A17 首次使用、真实书源与个人 Nextcloud

按用户最新要求，默认规则在首次搜索或直接阅读时统一获取，成功落盘才记完成；失败可见并可重试，用户删除后不重复强装。默认规则与应用仍分别维护在本仓库 `novel_rules/`。索引可选 `replaces` 只允许用旧原文摘要识别升级，不覆盖自定义规则；旧版v1索引无该字段仍可用。搜索记忆选择的书源，首次遇到登录要求时打开本人账号登录框，CookieJar按书源在本机持久保存，密码只在表单内存使用。

Astra 单变量复核推翻了“Dart客户端本身无法访问”的早期判断：Chrome UA或默认gzip各自触发403；使用应用UA与显式identity时请求成功。没有更换网络栈、代理或DNS，也没有登录兜底。随后生产 `NovelHttpSession + Dio + XPathNovelAdapter` 匿名实测23章、首章93块、插图章13图、首图480755字节，搜索明确报告需要登录，证据 `work/live-book-session.log`。快速重复探针曾收到429，放慢实验频率后完成；应用仍显示站点真实错误。真实本人账号登录及实体设备交互由用户安装验收，小説家403尚未关闭。

真实 Nextcloud32 上使用生产 `webdav_client + NovelWebDavExchange` 跑通OPTIONS/PROPFIND/MKCOL/PUT/MOVE/GET与快照校验读回；临时应用密码已撤销，测试目录已清理。原始中文WebDAV基址成功；预编码中文基址的MOVE被依赖再次编码导致409，因此配置文档要求原样中文路径。无需修改云盘服务器、反向代理或开放额外端口。

用户强调官方兼容后，Astra 核对上游025dcb5/官方2.3.9：观看/收藏数据模型、init、同步和清理代码与上游逐字一致，小说仅新增兄弟目录；官方只处理已知文件，不会遍历删除小说。新增真实HTTP逆向集成运行同一客户端两轮观看/收藏上传与下载恢复，并核验小说快照、未完成cache文件集合与字节不变、无请求触及小说路径。夹具仅初始化 GStorage 一次，每轮上传经过真实历史 checkpoint、确认本地日志消失，再清空本地业务集合并断言实际 GET 恢复。它不代表两套独立官方设备或官方安装包 UI 验收，也不扩展成所有历史/未来官方版本的无限兼容承诺。

该夹具前两次 CI 失败均为测试初始化错误：首次重置 Hive 适配器清除了内置 DateTime；恢复适配器后，又触发 GStorage._setting 的 late-final 禁止二次初始化。现已删除整条同 isolate 重复初始化/重置路径，沿用官方测试一次初始化方式；生产 GStorage、WebDAV 和历史协调单例均未改。修订测试静态分析通过，完整 HTTP 运行结果等待下一轮 CI。

### A18 固定签名与发布

用户已配置仓库Secret `BOOK_ANDROID_SIGNING`。Android release使用独立长期PKCS12签名，CI同时校验应用ID及预定证书摘要；私钥在仓库外。`book-release.yml`只发布与版本标签完全相同提交、已经成功完成完整检查和原生构建的产物，不重复打包。上游release工作流首两个依赖job仅允许上游仓库执行，防止fork触发官方打包流程。本轮完整测试、原生包和发布结果待执行后记录。

### A19 发布候选完整检查

提交 `32c607ed7e6f51018454ce6c21456781a3d5a5a0` 的 [run 38955947909](https://github.com/ZGCC3890/Kazumi-s-book/actions/runs/38955947909) / checks `117158994829` 成功，日志明确 `286 tests passed`；分析32个info，无error/warning。新增会话测试证明一次登录后重建会话仍可访问、退出后明确需要登录，持久文件不包含密码；默认规则初始化、失败重试、已知旧版升级及旧v1索引保留自定义规则通过。官方协议测试以单次生产存储初始化执行两轮上传、清空本地业务集合、真实远程GET恢复；小说快照和cache文件集合及字节全不变，没有请求触及小说路径。这是同协议读写与隔离验证，不冒充两份官方安装程序的UI测试。

Hive按key排序的实验导致首选书源不稳定，现把catalog首条明确写入首选设置并在测试断言；不依赖注册表枚举顺序。另一回归是新会话曾持有DioFactory旧客户端，而ProxyManager更改网络配置会关闭它；已改为每次取得当前客户端。真实HTTP纯Dart红绿实验精确复现旧闭连接错误并验证新provider读取成功，CI同时验证客户端替换后本地会话继续可用。构建和发布结果在完成后另记。

### A20 0.1.0 发布及下载核验

同一run `38955947909` 的Windows `117159829042` 与Android `117159828952` 均success，整个run completed/success。Windows日志确认release产物构建、原生进程运行及独立settings目录创建，artifact `12070733561`。Android release APK约33.9MB，日志明确验证包名 `com.zgcc.kazumisbook` 及固定证书SHA256 `85fa5bfda7fd385f44cabf8da36970bcde6c049e297f4dc67ca3e24252e4ee41`，artifact `12071061710`。此前281项的debug包不作为此次发布产物。

标签 `0.1.0` 指向该成功构建提交 `32c607e`。[发布run 38957633003](https://github.com/ZGCC3890/Kazumi-s-book/actions/runs/38957633003) success，复用同提交已成功构建的两个artifact，发布[0.1.0 Release](https://github.com/ZGCC3890/Kazumi-s-book/releases/tag/0.1.0)。公开REST确认非草稿、三项asset齐全；应用使用的 `/releases/latest` 返回0.1.0。

实际从公开Release下载三文件并与GitHub摘要逐一核验：APK33908677字节，SHA256 `1194994bfd9711b06f69e0546a006b6524da01c9c7dd0dc22450856111f00e2f`；WindowsZIP43144191字节，SHA256 `fe9e7e86d03f7651fd3a8e6163053f30852c31b8e6deb5bd592b4fc1d9d919a4`；SHA256SUMS194字节，摘要 `13c709555072d037d1515761a3ee5ff6047dc1863b161fdb1c33e2c3df1499be`。两归档CRC及所需原生文件核验通过。下载验证件在工作区 `outputs/releases/`，公开仓库不包含私钥或账号密码。

Astra最终只读复核未发现偏离用户目标或新的代码发布阻断。仍需用户安装后验收真实账号会话、手机/桌面阅读交互、两款已安装应用共存及实体设备跨源续读；Syosetu访问限制保留在发布说明。后续仅文档进度提交不改变0.1.0二进制绑定提交。

## 0.1.1 回归与交互修正（进行中）

用户最新要求覆盖原方案中的版本确认流程：选书即读，同卷同章号可跨译名匹配；段落或插图位置不确定时直接从对应章节开头继续，仅章节不唯一时选章。爱心仍为原导航入口，页内“追番／书架”并列，封面来自当前书源。

CI `38967246915`（`b0a9613`）为 301 项通过、10 项失败、1 项默认跳过；未发布安装包。新增退出动画回归实际复现小说 URL 弹窗关闭后父页面已销毁仍 setState。书签输入弹窗另在本机复现 TextEditingController 早于退出动画销毁，修正为等待 DialogRoute.completed 后释放；相同生命周期问题同步修正小说规则粘贴入口。

进度控件的语义断言经 Astra 最小实验定位：Focus 下的双层亮度 Stack 在遮蔽期间滚动后出现未构建 IndexedSemantics 节点。移除 SelectionArea 或挪 Focus 均不足以解决。纯视觉亮度改为正文前景 DecoratedBox，保留键盘 Focus 与全部语义；未修改 SDK、未关闭断言或无障碍。实际生产 Reader 的 20 项原测试及新增书签回归在独立依赖 harness 全部通过（`work/reader011-green.log`）；该结果只覆盖 Reader，完整应用 CI 仍待重跑。

`7191f86` 的完整 CI 日志确认 Reader 20 项、导航两种尺寸、封面解码失败展示、选源 5 项均通过；入架同时写入官方“在看”的正常流程也通过。失败重试用例在 10 分钟后超时，因此该轮取消，未发布。增加 CI 步骤 5 分钟上限以便卡住时能收尾并取得日志，不跳过失败。

Astra 用真实 Hive CE 跨两个 Widget 测试复现：首项写入/flush 成功，第二项 setUp 的 clear 超时。Hive 保留的完成 Future 属于首项已结束的 FakeAsync zone；Dart 已完成 Future 的后续监听仍由原 zone 调度。对照将写入链、确认弹窗 Future 及终态 Completer 放在 tester.runAsync 的真实 zone，连续两项通过。修复仅改测试夹具的异步边界，不重建 GStorage、不修改应用存储队列；生产集成重跑待 CI。

`4e64c32` 的 CI `38970244139` checks `117206917569` 完整结果为 312 项通过、1 项默认跳过；单独启用 live 测试通过，真实搜索“无职转生”9 条、“葬送的芙莉莲”5 条，番剧评论20条（总4622）、分集256446评论201条。三项原入架正常／失败重试集成全部通过，确认真实异步 zone 修复有效。

用户随后调整要求：加入书架不得修改番剧追番状态，改为书架与小说搜索结果中的番剧详情跳转键。已移除上架链中的 Bangumi 请求和 CollectController 写入；新增关联查询与共享按钮，多季选择、完整标题／别名匹配、分页、请求合并，并保持 `/info/` 完整 BangumiItem 参数。Astra 查出的两个状态问题（换书时残留旧 Future 数据、同步关联后按钮不刷新）均补局部修复及 Widget 回归。新需求完整 CI 尚待执行，不能沿用上一提交绿灯。

发布边界已按最新指令更新：当前只实现、验证、提交，不打标签、不发布；等待用户要求清理测试文件并表示本轮无后续指令后再发布。

新需求提交 `ac77a2443be748c8d1e39a075d74444848266c06` 的 [CI 38971601750](https://github.com/ZGCC3890/Kazumi-s-book/actions/runs/38971601750) checks `117211220624` 成功：325 项通过、1 项默认跳过。13 项新增关联解析／按钮交互及生命周期回归全部通过；三项入架测试确认不新增番剧收藏、已有“想看”及同步日志不变、书架写失败可重试。单独启用 live 测试成功：真实搜索9／5条，小说“葬送的芙莉莲”解析出番剧400602、515759，番剧评论20条（总4622）和分集256446评论201条。

Astra 最终复核未发现新确定阻断；当前状态为自动验证通过、待设备体验验收。该 CI 最终 completed/success：Windows job `117212095443` 完成 release 编译、原生启动和独立设置目录检查，artifact `12076989006`；Android job `117212095509` 完成 release 编译，包名与固定签名校验均通过，artifact `12077099366`。公开 Releases 仍只有 `0.1.0`；继续等待后续指令和清理测试文件通知。

失败邮件核查：仓库 Actions 最近失败记录均来自本项目 `book-ci.yml` 的开发回归测试（包括已修复的弹窗生命周期、阅读器语义断言和测试异步 zone 问题）；连续推送另产生了旧任务 cancelled 记录。继承的 `release.yaml` 在 Fork 中按仓库条件跳过，`pr.yaml` 只响应 PR／手动触发，没有对应失败记录。当前完整 CI 全绿，自动校验继续执行；未用关闭工作流或通知掩盖失败。

### 阅读器跟随应用明暗（本轮）

原阅读器依据独立 theme 偏好选择固定色盘，并自行生成 ColorScheme，未读取应用有效 brightness。新滚动／翻页／系统主题测试在原代码均复现背景不随应用变色；局部修复后，正文采用应用深色 surface／onSurface，亮色保留日间纸色，控件沿用完整应用 ThemeData。旧夜间值明确兼容为纸白日间偏好，设置去掉重复夜间开关。颜色不影响排版测量，主题变化不清布局缓存；字体、行距、边距、字体族或阅读方式变化才重排。

生产 Reader 独立依赖 harness 的 23 项测试通过（`work/reader-theme-green.log`），包括中段滚动／翻页切明暗后保留控制器、视口和保存锚点，打开设置时切明暗，跟随系统及旧偏好。定向 Dart 分析无 error／warning，保留 3 项既有 info；完整应用 CI 与本轮原生构建待执行。仍不创建标签或 Release。

Astra 只读复核未发现确定阻断；确认正文重新取当前 style，片段缓存只有几何数据，切换主题无需重排。AppBar 与正文采用同一阅读纸色，底栏及弹窗继承应用完整主题。设备体验仍待用户确认。

## 验证状态说明

“源码审查通过”只说明所检查代码满足架构约束；“自动验证通过”必须列出执行命令/结果；“待设备测试”不能改写成“完成”。真实书源、真实跨设备同步和阅读器排版恢复需分别记录实际运行证据。
