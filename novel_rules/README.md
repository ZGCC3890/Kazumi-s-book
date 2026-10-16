# Kazumi's book 小说规则

客户端首次搜索或阅读自动通过 `catalog.json` 获取默认规则；每个 JSON 仍可独立更新和删除。规则不是应用内置资源。默认索引位于本仓库 `feature/novel-reader` 分支，高级管理支持自定义索引 URL、单个规则 URL、文件和 JSON 粘贴导入。索引可选 `replaces` 列出允许自动替换的旧版规范化JSON的SHA256，只有原文匹配才升级；缺少此字段表示不自动覆盖已有规则。

## 已有规则及核验边界

| 规则 | 检索方式 | 内容 | 当前核验 |
| --- | --- | --- | --- |
| lightnovel | UTF-8 HTML 匿名搜索、显式公开详情链接 | JSON 两级分页卷章目录，正文 HTML 与原位插图 | 生产 Dio＋adapter 实取20结果/31章/4550文字块/20图，首图797846字节；受限313738返回locked=1，应用明确报权限错误，不取隐藏快照 |
| linovel | UTF-8 HTML 匿名搜索、显式公开详情链接 | 中文原创轻小说、分卷目录、正文和原位插图 | 生产 Dio＋adapter 实取15结果/486章/195文字块/1图23806字节；样本成功不代表全站永远没有访问限制 |
| wenku8 | GBK GET 搜索（本人首次登录）；显式公开书籍链接 | 分卷目录、段落和原位插图 | 应用UA+identity请求解决此前403；生产Dio会话与adapter实际取得23章/93文本块/13图及首图480755字节。真实账号登录待用户验收 |
| syosetu | 官方 UTF-8 JSON API | 日文 Web 版章节、正文、插图 | API 协议依据官方开发文档；HTML 规则参考维护者公开解析器；当前环境 API 和正文访问均记录过 403，待真实设备验证 |

规则不包含个人账号、密码、Cookie 或共享登录凭据。请求遭拒、正文缺失或章节定位不确定时，客户端显示实际错误或要求确认。

文库8规则依据用户指定站点的实际页面。`wenku8.cc` 在核验时进入 `wenku8.net`；规则使用实际页面地址。公开详情、目录、正文和插图已有生产Dio匿名实证，但搜索/书目列表确实要求登录。公开详情页的页眉也包含密码输入框，因此不能仅凭含密码框判定整页需要登录。`login` 显式声明HTTPS表单字段及受保护搜索页的验证选择器；会话按书源仅存本机，成功必须取得受保护搜索结果，不能单凭HTTP200或Set-Cookie判定。密码不保存，规则与WebDAV均不携带个人会话。

小説家になろう搜索 API：[官方文档](https://dev.syosetu.com/man/api/)。目录和正文选择器参考 [narou-mod 维护者的解析配置](https://github.com/iuill/narou-mod/blob/release/preset/parsers/ncode.syosetu.com.yaml) 中的当前页面结构；本规则仅使用显式指定的一套结构。

## Schema v1

- `type: novel-xpath`：版本化声明式规则类型；XPath 用于正文容器及字段提取，搜索和目录的节点选择模式可以显式声明 CSS。`searchFormat` 为 `html` 或 `json`（JSONPath）。不执行规则内脚本。
- `id` 是书源稳定标识；`revision` 用于维护说明。客户端以完整规则内容摘要区分目录和正文缓存，更新选择器后不会继续使用旧解析结果。
- `encoding` 必须声明 `utf-8` 或 `gbk`；GBK 同时用于搜索参数和响应解码。
- `search` 定义结果节点、书名、链接、作者和封面。HTML 必须声明 `itemsMode: css`，`items` 是选择整张结果卡片的 CSS 选择器；卡片内字段使用向下的相对 XPath，不在失败时切换解析模式。`titleAttribute` 可读取未截断的标题属性；`authorRegex` 非空时必须包含捕获组。JSON 的 `urlTemplate` 仅替换 `@value`，`linkTransform` 可指定 `lowercase`。
- HTML `singleDetect` 非空时可明确识别搜索重定向到单书详情的响应，并通过 `singleTitle` / `singleAuthor` / `singleAuthorRegex` / `singleCover` 提取唯一作品；作品地址取 HTTP 最终响应 URL。`loginRequiredUrlPattern` 匹配最终 URL 时明确报登录页错误；可选 `loginRequiredXPath` 只能用于真正唯一的登录页面结构，文库8该项为空，因为公开详情页眉也有登录表单。
- `directBookUrlPattern` 声明允许直接添加的书籍详情 URL；非空且匹配时，用户可明确选择“从公开书籍链接添加”，使用同一详情字段解析作品。空字符串表示该书源没有声明此能力。这是独立入口，不是搜索失败后的隐式备用路径。
- `catalog.detailToCatalog` 非空时先从书籍详情提取目录链接；目录显式使用 `mode: sequence-css`，`nodes` 是同时选择卷头和章节的 CSS 选择器，按文档顺序遍历。`volumeClass` 识别卷头，并将当前卷传递给后续章节和下一目录页；章内标题和链接仍使用简单 XPath。无需复杂 XPath 的嵌套谓词，不用数组下标当卷章身份。
- 目录/正文的 `next` 为空表示没有分页；有分页则必须显式指定“下一页”，不能使用“下一章”充当正文分页。循环和重复章节会报错。
- `content.root` 选择正文容器。DOM 按顺序提取文字、换行和 `img`，插图保留在原文位置；`remove` 只删除明确选择的节点。日文规则去除 `rt/rp` 注音节点，保留正文汉字。
- `requestEncoding: json` 为明确声明的 JSON POST，未声明的旧规则沿用表单协议。LightNovel 的 `catalog.mode: json-volumes` 先遍历卷分页，再逐卷遍历章节分页，通过 `hasNextPath` 控制，并核验每卷 `chapter_count`；不以网页只渲染的前8项冒充完整目录。
- `content.format: json-html` 明确指定公开正文 API、章节链接捕获组、POST模板、访问状态JSONPath和HTML字段。先核验 `locked=0` 再解析HTML，`locked=1` 明确报错。图像URL按站点实际响应使用，不自行生成权限参数。

更新规则后应运行解析样本测试，并分别验证搜索、卷章目录、正文、图片与分页。实际网站验证未通过时，更新本文件的核验状态。

执行器兼容性：当前 `xpath_selector` 并非完整浏览器 XPath。实验证明嵌套 `concat/normalize-space`、属性存在谓词、父轴 `parent::` 不可用，`..` 也未按父节点语义执行。规则使用已测试的向下 XPath 和显式 CSS 模式；不能仅在浏览器控制台验证选择器后就宣称应用解析通过。

2026-10-17 自动验证：`test/novel_rule_test.dart` 直接读取这两份生产 JSON，11项结构fixture通过，包括GBK搜索参数、单书重定向、公开URL添加、公开详情登录框与真正登录重定向的区分、空补齐目录单元格、图文顺序、JSON元数据行跳过、ruby去除及跨页卷继承。生产Dio链路实测及请求头单变量证据在仓库实施/审查记录中维护；实体设备UI与真实账号登录仍由用户验收。
