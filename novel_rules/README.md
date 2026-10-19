# Kazumi's book 小说规则

客户端首次搜索或阅读自动通过 `catalog.json` 获取默认规则；每个 JSON 仍可独立更新和删除。规则不是应用内置资源。默认索引位于本仓库 `feature/novel-reader` 分支，高级管理支持自定义索引 URL、单个规则 URL、文件和 JSON 粘贴导入。索引可选 `replaces` 列出允许自动替换的旧版规范化JSON的SHA256，只有原文匹配才升级；缺少此字段表示不自动覆盖已有规则。

## 书源与使用

| 规则 | 检索方式 | 内容 | 登录与访问要求 |
| --- | --- | --- | --- |
| lightnovel | UTF-8 HTML 搜索、公开详情链接 | JSON 分页卷章目录，正文 HTML 与原位插图 | 支持匿名访问公开内容；受限章节显示权限错误 |
| linovel | UTF-8 HTML 搜索、公开详情链接 | 中文原创轻小说、分卷目录、正文和原位插图 | 支持匿名访问公开内容 |
| wenku8 | GBK GET 搜索、公开书籍链接 | 分卷目录、段落和原位插图 | 搜索需要在每台设备登录本人账号 |

规则不包含个人账号、密码、Cookie 或共享登录凭据。请求遭拒、正文缺失或章节定位不确定时，客户端显示实际错误或要求确认。

在小说搜索或书架打开“小说规则”，使用“添加规则”从仓库、剪贴板或文件导入；支持规则 URL、单个 JSON 和 JSON 数组。已安装规则可重新获取或删除，仓库地址可在规则管理设置中修改。

点击已安装规则，或从菜单打开“书源账号与网站”，可以访问书源网站注册。声明 `login` 协议的规则提供用户名、密码、登录验证、当前会话验证及清除登录。首次登录成功后，账号密码通过系统安全存储加密保存在本机；会话过期时使用保存的账号自动登录，并继续原请求。清除登录会删除保存的账号密码和 Cookie。没有登录协议的规则明确显示匿名访问状态，不将浏览器登录视为客户端已登录。

轻小说文库使用 `https://www.wenku8.net/`。在搜索的“书源状态”中打开“书源账号”登录；客户端通过首页退出链接确认会话有效。搜索间隔须遵守站点要求，间隔不足 5 秒时会显示站点提示，等待后可重试。账号密码和会话按书源保存在本机，规则与 WebDAV 均不携带个人登录信息。密码失效或站点要求额外验证时会显示实际错误，需要重新打开书源账号处理。

## Schema v1

- `type: novel-xpath`：版本化声明式规则类型；XPath 用于正文容器及字段提取，搜索和目录的节点选择模式可以显式声明 CSS。`searchFormat` 为 `html` 或 `json`（JSONPath）。不执行规则内脚本。
- `id` 是书源稳定标识；`revision` 用于维护说明。客户端以完整规则内容摘要区分目录和正文缓存，更新选择器后不会继续使用旧解析结果。
- `encoding` 必须声明 `utf-8` 或 `gbk`；GBK 同时用于搜索参数和响应解码。
- 可选 `websiteUrl` 指定 HTTP(S) 网站或注册页面。未声明时，网站入口使用 `headers.Referer` 的站点根地址；未设置 Referer 时使用搜索地址的站点根地址。
- 可选 `imageHeaders` 只覆盖封面与正文插图的请求头，搜索、目录和正文仍使用 `headers`。未声明时沿用 `headers`。LightNovel 的图片请求使用空 `Referer`，以兼容正文中的外部图床；自行导入的规则须显式声明所需覆盖。
- 可选 `login` 定义表单登录的 `url`、`usernameField`、`passwordField`、固定表单 `fields`，以及登录后的 `verifyUrl` 和 `verifySelector`。客户端以验证页面中的指定 CSS 节点确认会话；验证成功后保存本机账号密码，失败会显示实际错误。已保存的凭据绑定登录和验证地址，规则更改这些地址后需要用户重新登录确认。
- `search` 定义结果节点、书名、链接、作者和封面。HTML 必须声明 `itemsMode: css`，`items` 是选择整张结果卡片的 CSS 选择器；卡片内字段使用向下的相对 XPath，不在失败时切换解析模式。`titleAttribute` 可读取未截断的标题属性；`authorRegex` 非空时必须包含捕获组。JSON 的 `urlTemplate` 仅替换 `@value`，`linkTransform` 可指定 `lowercase`。
- HTML `singleDetect` 非空时可识别搜索重定向到单书详情的响应，并通过 `singleTitle` / `singleAuthor` / `singleAuthorRegex` / `singleCover` 提取唯一作品；作品地址取 HTTP 最终响应 URL。`loginRequiredUrlPattern` 匹配最终 URL 时报告登录页错误；`loginRequiredXPath` 用于唯一的登录页面结构。`errorXPath` 指定站点错误提示节点，匹配到非空文本时以该提示报告失败，不将错误页解析为空结果。
- `directBookUrlPattern` 声明允许直接添加的书籍详情 URL；非空且匹配时，用户可明确选择“从公开书籍链接添加”，使用同一详情字段解析作品。空字符串表示该书源没有声明此能力。这是独立入口，不是搜索失败后的隐式备用路径。
- `catalog.detailToCatalog` 非空时先从书籍详情提取目录链接；目录显式使用 `mode: sequence-css`，`nodes` 是同时选择卷头和章节的 CSS 选择器，按文档顺序遍历。`volumeClass` 识别卷头，并将当前卷传递给后续章节和下一目录页；章内标题和链接仍使用简单 XPath。无需复杂 XPath 的嵌套谓词，不用数组下标当卷章身份。
- 目录/正文的 `next` 为空表示没有分页；有分页则必须显式指定“下一页”，不能使用“下一章”充当正文分页。循环和重复章节会报错。
- `content.root` 选择正文容器。DOM 按顺序提取文字、换行和 `img`，插图保留在原文位置；`remove` 只删除明确选择的节点。日文规则去除 `rt/rp` 注音节点，保留正文汉字。
- 阅读器可将当前连续分卷内标题为“插图”“插画”“彩页”（含繁体）、“イラスト”或“挿絵”的独立章节显示为插图栏，标题可带数字序号。图片按目录及正文 DOM 顺序排列，不对封面、彩页和尾页重新排序，不将正文编号替换为图片。没有独立插图章时不显示入口；自定义规则沿用同一明确标题识别，不启用网站专属回填逻辑。
- `requestEncoding: json` 表示 JSON POST，未声明时使用表单协议。`catalog.mode: json-volumes` 先遍历卷分页，再逐卷遍历章节分页，通过 `hasNextPath` 控制，并核验每卷 `chapter_count`。
- `content.format: json-html` 明确指定公开正文 API、章节链接捕获组、POST模板、访问状态JSONPath和HTML字段。先核验 `locked=0` 再解析HTML，`locked=1` 明确报错。图像URL按站点实际响应使用，不自行生成权限参数。

## 规则维护

规则更新需要检查搜索、卷章目录、正文、图片和分页。可在仓库根目录运行 `flutter test test/novel_rule_test.dart` 检查解析样本；网站登录与访问限制需使用本人账号按站点规则验证。

执行器使用 `xpath_selector`，不具备完整的浏览器 XPath 支持。节点选择应使用规则声明的 CSS 模式，字段提取使用向下的相对 XPath；避免嵌套 `concat/normalize-space`、属性存在谓词、`parent::` 和 `..`。选择器必须与客户端使用的执行器兼容。
