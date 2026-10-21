# 贡献指引

欢迎为 Kazumi's book 提交问题、规则、文档和代码。请向本仓库的 `feature/novel-reader` 分支提出 Pull Request；上游 Kazumi 与本项目分别维护，新增小说功能的问题请在本仓库报告。

在开始之前, 请先阅读这份指引, 以保障审阅者和您之间的协作效率。

## 开发环境设置

### 前置需求

- [Flutter SDK](https://flutter.dev/) - 版本以 `pubspec.yaml` 的 `environment.flutter` 为准，与 CI 保持一致。
- 良好的网络环境
    - 建议至少保证 Google, Github, SourceForge, MavenCentral, pub.dev 的可访问性。
    - 某些资源访问质量不佳时, 可能需要通过设置镜像地址或其他方式解决。
- 开发侧所需的 SDK, 如 [Android SDK](https://developer.android.com/) 等。在配置 Flutter 时, 也会要求下载安装开发侧 SDK.
- Windows 需要 Visual Studio 的 C++ 桌面开发工具、Windows SDK 和对应工具集的 ATL 组件。Android 需要 JDK 17 和 Android SDK；版本及原生测试配置见 [book-ci.yml](.github/workflows/book-ci.yml)。

### 基本配置

```bash
# 克隆仓库
git clone --branch feature/novel-reader https://github.com/ZGCC3890/Kazumi-s-book.git
cd Kazumi-s-book

# 检查 Flutter SDK 状态并下载相关包
flutter doctor -v
flutter pub get

# 进行检查
flutter test
flutter analyze --no-fatal-infos --fatal-warnings

# 进行调试
flutter run
# flutter run --profile
# flutter run --release

# 为生产环境编译
flutter build apk --release --target-platform android-arm64
flutter build windows --release
```

## 代码质量

您的更改应该通过检查和验证。

```bash
flutter test
flutter analyze --no-fatal-infos --fatal-warnings
```

## 编写规范

项目大多数功能都遵循 `抽象 -> 调用` 的实现。不同组件按职责分类存放, UI 组件、功能、页面、服务分属不同目录, 互不混写。

有关模块职责和扩展边界，参考 [项目结构](static/doc/STRUCTURE.md)。小说业务位于 `lib/novel/`，规则位于 `novel_rules/`；平台更新位于 `lib/services/update/`。避免让原有番剧功能依赖小说业务状态。

开发过程中, 您应该**慎重考虑**新增外部库、会导致包体积大量膨胀的实现和其它不安全的行为。

- 如果要引入新的外部库 - 考虑一下是否有更轻便的实现方法？
- 如果功能会导致包体积巨增 - 也许这个功能目前不应该实现？
- 如果需要使用 `Print()` 等输出 - 使用 `KazumiLogger` 或其它代替？
- 如果性能表现大打折扣 - 当前功能的思路是不是需要重新考虑？

行为变化应提供覆盖成功、失败、取消及相关异步时序的回归测试；先通过本地可执行的检查，再推送 CI。新增或修改代码以至少 90% 的分支覆盖为目标，并说明未覆盖范围。Windows 更新器测试在 Windows 上执行，Android 原生验收在手机和平板模拟器中执行；编译成功不等于交互验收通过。

```bash
flutter test --coverage --branch-coverage
flutter test test/windows_portable_update_test.dart
```

平台特定测试在相应平台运行。原生流程、测试服务与 CI 命令分别位于 `integration_test/`、`tool/` 和 `.github/workflows/book-ci.yml`。报告应说明环境、实际执行的命令和结果，不把不可运行的检查标为通过。

Android 正式签名和弹弹play接口凭据由发行环境提供，不随源码分发。个人构建不能覆盖安装不同签名的正式 APK；缺少弹弹play凭据时不能验证在线弹幕。不要提交账号、密钥、个人阅读数据或本机工具路径。

## 更改与 Commits

建议使用 [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(theme): 增加新的主题设计
fix(external_player): 修复外部播放器启动失败的问题
refactor: re-design parser implements
chore: replace print() with KazumiLogger
docs: 更新文档 Q&A 
```

**不建议您使用模糊不清的 commits**, 反之, 上述建议能够使 commits 准确简洁地说明您做出的工作, 为审查提供便利。

## 推送与 Pull Requests

### 限制

您的 PR 至少应该符合以下基本要求: 
- **一个 PR 只解决一件事情**。比起把多个功能、调整和修复都堆在一个 PR 中, 把它们拆开并分别创建 PR, 分别提交是正确的选择。
- **一个 PR 更改的代码量不应太多**。1000 行甚至更多的更改是不建议的, 可以分成几个 PR 分别提交, 利于审查和修改。
- **提交者对完整改动负责**。描述具体问题、修改后行为及验证结果；使用辅助工具不替代对代码和测试的审阅。

### 类型

在推送 PR 时, 根据类型不同可以分为: 
- Bug 修复 - 您应当打开 Issue 并确认所描述的 Bug 已修复, 然后在 PR 中引用该 Issue。
- 新功能 - 编写代码和推送前, 请确认这个新功能已经被维护者批准, 以防您的贡献因为不在计划中而拒绝合并。
- 功能重构 - 重构和新功能应当清楚分开。在重构功能时, 不要加入新功能。

### PR 标题

您的 PR 标题应该遵循 [Conventional Commits](https://www.conventionalcommits.org/) 的格式:

```
refactor: 重构 WebDAV 同步功能
feat(danmaku): 为弹幕添加了新的屏蔽方法
fix(network): fix proxy issues
```

同样, 遵循该规范能够使标题准确、简洁地说明您做出的工作。

### 推送 PR 之后

GitHub Actions 会执行仓库配置的检查；失败时先阅读相关日志并定位原因，再提交修复。检查通过后由维护者审阅，是否合并取决于正确性、范围和维护成本。

如果最终 PR 未被接受合并, 通常可能是因为该实现有以下问题之一: 
- 这个实现的性能开销无法接受。
- 这个实现会导致安全或隐私问题。
- 这个实现过于臃肿, 可能有更好的方法。
- 这个实现只有部分设计比较好, 其它的部分有更好的方法。
- 这个实现不在计划中。
- 其它...

一般情况下都会解释为什么您的 PR 没有被接受。**这并非对您工作的否定, 只是因为您的贡献可能并不适合项目当前的情况。我们感谢您所做的付出！**

### 文档与资源

README 介绍项目、安装、功能和上游关系；CHANGELOG 记录正式版本的用户可见变化；协议和模块说明就近维护。更新文档时检查相对链接，避免重复维护同一规则。公开文档不包含本地交接记录、临时测试流水或个人开发环境约束。

截图应来自实际运行的应用，标明平台，避免出现个人账号、密钥或私有服务器地址。第三方代码和素材保留其版权与许可证，新增依赖同时更新相应声明。


## 许可证

本项目基于 [GNU 通用公共许可证第 3 版（GPL-3.0）](LICENSE)授权。请仅贡献您有权按项目许可证提交的内容；引入第三方代码或素材时说明来源及其适用许可，参见 [第三方声明](THIRD_PARTY_NOTICES.md)。
