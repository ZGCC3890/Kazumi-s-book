# 上游与第三方声明

## 项目来源

Kazumi's book 基于 [Predidit/Kazumi](https://github.com/Predidit/Kazumi) 开发，继续使用 [GNU GPL 第 3 版](LICENSE)。上游作者与贡献者的署名、源文件内版权声明及已有许可证均保留。小说模块和本分支集成变更见 [版本说明](CHANGELOG.md)；对应版本源码由本仓库同名标签提供。

本文件说明来源和已有许可文件的位置，不替代任何第三方许可证，也不将所有第三方素材统一改为 GPL。

## 组件许可

| 组件或资源 | 许可与来源 |
| --- | --- |
| ech_http 及所含原生依赖 | [组件许可证](licenses/ech_http/LICENSE)、[第三方清单](licenses/ech_http/THIRD_PARTY_NOTICES.md)；同目录保留 BoringSSL、curl、CA bundle 和 libc++ 的声明。 |
| m3e_core | [许可证](licenses/m3e_core.txt)。 |
| Anime4K 着色器 | [资源许可证](assets/shaders/LICENSE)，来源 [bloc97/Anime4K](https://github.com/bloc97/Anime4K)。 |
| Flutter / Dart 包及其他原生依赖 | 依赖及锁定版本见 [pubspec.yaml](pubspec.yaml)、[pubspec.lock](pubspec.lock)；各包按其附带许可证使用。 |

## 图标与字体

应用图标来自 [Yuquanaaa](https://www.pixiv.net/users/66219277) 的[原作品](https://www.pixiv.net/artworks/116666979)。上游 README 声明已取得在 Kazumi 中使用的授权，并明确图标不属于可自由使用的素材。本分支保留该说明；仓库中未附原作者对本分支的独立授权文件，不据此主张可以任意复制、修改或再分发图标。相关使用应核对原作者许可范围。

内嵌 MiSans 字体由 Xiaomi 提供，来源及使用条款见 [MiSans 官网](https://hyperos.mi.com/font/zh/details/sc/)。字体权利由其权利人保留，代码许可证不替代字体许可。

## 内容与服务

番剧、小说、封面及插图来自第三方内容来源，权利属于相应权利人；书源规则只描述访问与解析方式。Bangumi、弹弹play、trace.moe、SyncPlay 和用户配置的 AI 服务均由各自运营方提供，本项目不代表这些服务。

上游的签名服务、赞助及推荐徽章属于上游项目，本分支不声称继承这些关系。感谢上游和各依赖项目的贡献者。
