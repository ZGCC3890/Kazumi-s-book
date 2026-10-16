# Kazumi's book 小说规则

客户端通过 `catalog.json` 获取规则列表；每个 JSON 可以独立导入和更新。规则不是应用内置资源。默认索引位于本仓库 `feature/novel-reader` 分支，应用支持自定义索引 URL、单个规则 URL、文件和 JSON 粘贴导入。

## 已有规则及核验边界

| 规则 | 检索方式 | 内容 | 当前核验 |
| --- | --- | --- | --- |
| wenku8 | 公开站点 GBK GET 搜索 | 分卷目录、段落和原位插图 | 2026-10-17 浏览器核对搜索、详情、目录和正文 DOM；匿名客户端请求遇 Cloudflare 403，不能认定所有网络免登录可用 |
| syosetu | 官方 UTF-8 JSON API | 日文 Web 版章节、正文、插图 | API 协议依据官方开发文档；HTML 规则参考维护者公开解析器；当前环境正文站点返回 403，待真实设备验证 |

规则不包含个人账号、密码、Cookie 或共享登录凭据。请求遭拒、正文缺失或章节定位不确定时，客户端显示实际错误或要求确认。

文库8规则依据用户指定站点的实际页面。`wenku8.cc` 在核验时进入 `wenku8.net`；规则使用实际页面地址，避免给普通阅读请求增加无关跳转。首页旧公告描述免注册阅读，当前匿名网络可用性仍须实测，公告不能代替实测结果。

小説家になろう搜索 API：[官方文档](https://dev.syosetu.com/man/api/)。目录和正文选择器参考 [narou-mod 维护者的解析配置](https://github.com/iuill/narou-mod/blob/release/preset/parsers/ncode.syosetu.com.yaml) 中的当前页面结构；本规则仅使用显式指定的一套结构。

## Schema v1

- `type: novel-xpath`：版本化声明式规则类型；XPath 用于正文容器及字段提取，搜索和目录的节点选择模式可以显式声明 CSS。`searchFormat` 为 `html` 或 `json`（JSONPath）。不执行规则内脚本。
- `id` 是书源稳定标识；`revision` 用于维护说明。客户端以完整规则内容摘要区分目录和正文缓存，更新选择器后不会继续使用旧解析结果。
- `encoding` 必须声明 `utf-8` 或 `gbk`；GBK 同时用于搜索参数和响应解码。
- `search` 定义结果节点、书名、链接、作者和封面。HTML 的 `itemsMode: css` 表示 `items` 是 CSS 选择器，选中整张结果卡片；卡片内字段使用向下的相对 XPath。`itemsMode: xpath` 则直接使用 XPath 选择结果节点；模式来自规则声明，不在失败时切换。`titleAttribute` 可读取未截断的标题属性；`authorRegex` 非空时必须包含捕获组。JSON 的 `urlTemplate` 仅替换 `@value`，`linkTransform` 可指定 `lowercase`。
- HTML `singleDetect` 非空时可明确识别搜索重定向到单书详情的响应，并通过 `singleTitle` / `singleAuthor` / `singleAuthorRegex` / `singleCover` 提取唯一作品；作品地址取 HTTP 最终响应 URL。`loginRequiredXPath` 匹配时明确报登录页错误，不作为零搜索结果。
- `catalog.detailToCatalog` 非空时先从书籍详情提取目录链接；目录显式使用 `mode: sequence-css`，`nodes` 是同时选择卷头和章节的 CSS 选择器，按文档顺序遍历。`volumeClass` 识别卷头，并将当前卷传递给后续章节和下一目录页；章内标题和链接仍使用简单 XPath。无需复杂 XPath 的嵌套谓词，不用数组下标当卷章身份。
- 目录/正文的 `next` 为空表示没有分页；有分页则必须显式指定“下一页”，不能使用“下一章”充当正文分页。循环和重复章节会报错。
- `content.root` 选择正文容器。DOM 按顺序提取文字、换行和 `img`，插图保留在原文位置；`remove` 只删除明确选择的节点。日文规则去除 `rt/rp` 注音节点，保留正文汉字。

更新规则后应运行解析样本测试，并分别验证搜索、卷章目录、正文、图片与分页。实际网站验证未通过时，更新本文件的核验状态。

执行器兼容性：当前 `xpath_selector` 并非完整浏览器 XPath。实验证明嵌套 `concat/normalize-space`、属性存在谓词、父轴 `parent::` 不可用，`..` 也未按父节点语义执行。规则使用已测试的向下 XPath 和显式 CSS 模式；不能仅在浏览器控制台验证选择器后就宣称应用解析通过。

2026-10-17 自动验证：`test/novel_rule_test.dart` 直接读取这两份生产 JSON，8 项结构 fixture 全部通过，包括 GBK 搜索参数、单书重定向、卷目录、最终 URL 相对解析、图文顺序、登录错误、JSON 元数据行跳过、ruby 去除及跨页卷继承。此结果不表示匿名在线访问或站点未来结构已获保证。
