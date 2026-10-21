# Kazumi's book 项目结构

小说业务集中在 `lib/novel/`，通过搜索、追番、设置及生命周期入口接入应用。番剧模型、播放器和上游规则保持原有职责；Windows 更新器独立位于 `lib/services/update/`。

```
Kazumi-s-book/
├── lib/                        # Dart 代码
├── test/                       # 测试
├── integration_test/           # 原生应用流程验收
├── tool/                       # 自动化验证与构建工具
├── novel_rules/                # 小说规则与公开协议说明
├── assets/                     # 资源
├── static/                     # 文档与静态素材
├── android/  ios/  linux/  macos/  windows/  web/   # Flutter 平台框架
├── fastlane/                   # 打包脚本
├── .github/                    # CI workflow + 模板
├── pubspec.yaml                # 依赖与版本
├── analysis_options.yaml       # lint 配置
├── LICENSE
├── CONTRIBUTING.md             # 开发、测试与贡献说明
├── PRIVACY.md                  # 本机及外部服务的数据范围
├── THIRD_PARTY_NOTICES.md       # 上游与第三方许可入口
├── CHANGELOG.md                # 发行版本变化
└── README.md
```

## lib/

```
lib/
├── main.dart                   # 入口
├── app_module.dart             # 根模块
├── core_module.dart            # App 单例注册
├── app_widget.dart             # 应用外壳
├── navigation.dart             # 全局 navigatorKey / routeObserver
├── hive_registrar.g.dart       # Hive adapter 注册表
│
├── bbcode/                     # BBCode 解析器
│   ├── bbcode_base_listener.dart
│   ├── bbcode_elements.dart
│   ├── bbcode_widget.dart
│   ├── README.md
│   └── generated/
│
├── bean/                       # UI 组件
│   ├── appbar/
│   ├── card/
│   ├── dialog/
│   ├── settings/
│   └── widget/
│
├── modules/                    # 数据模型
│   ├── bangumi/
│   ├── character/  characters/
│   ├── collect/                # 收藏
│   ├── comments/  staff/       # 评论、staff 响应
│   ├── danmaku/                # 弹幕
│   ├── download/               # Download
│   ├── history/                # 历史记录
│   ├── my/                     # 我的
│   ├── plugin/                 # 规则商店
│   ├── roads/                  # 线路+剧集
│   └── search/                 # 搜索
│
├── pages/                      # 页面
│   ├── index_module.dart / index_page.dart / init_page.dart
│   ├── router.dart             # 底部 Tab 路由表
│   ├── route_error_page.dart
│   ├── about/  bangumi/  collect/  download/  error/  history/
│   ├── info/                   # 番剧详情
│   ├── logs/  menu/  my/
│   ├── onboarding/             # 首次引导
│   ├── player/                 # 播放器主体 + controller/ 子目录（弹幕/进度/调试等）
│   ├── plugin_editor/          # 规则编辑/商店/测试
│   ├── popular/  search/  timeline/  video/  webdav_editor/
│   └── settings/               # 各设置页 + danmaku/ + proxy/
│
├── plugins/                    # 规则 schema 与规则管理
├── novel/                      # 小说模型、规则、搜索、书架、阅读、AI 关联与 WebDAV
│
├── repositories/               # 仓储接口 Hive
│
├── request/                    # 网络
│   ├── apis/
│   ├── clients/
│   ├── config/
│   └── core/
│
├── services/                   # 服务
│   ├── download/
│   ├── logging/
│   ├── network/
│   ├── platform/
│   ├── player/
│   ├── plugin/
│   ├── shaders/
│   ├── storage/
│   ├── sync/
│   ├── update/
│   └── video_source/
│
├── utils/                      # 无状态工具
│
└── webview/                    # WebView
    ├── captcha/
    └── video/
```
