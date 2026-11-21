<p align="center">
  <img src="assets/icon/icon-graphite.png" width="128" alt="picoTranslator 图标">
</p>

<h1 align="center">picoTranslator</h1>

<p align="center">一款小巧、简洁的 macOS 翻译工具。</p>

<p align="center"><a href="README.md">English</a> · 简体中文</p>

<p align="center">
  <img src="assets/screenshots/demo-zh.gif" width="560" alt="框选便签上的一行中文，picoTranslator 在便签正下方显示英文译文">
</p>

## picoTranslator 真的非常轻

- 应用本身比它的图标还小！
- 空闲时内存占用约 50MB，代码约 1500 行 Swift，没有任何依赖。
- 完全基于 Apple 的原生框架。它就是一个纯粹的翻译工具，完全免费。

## 功能

- 框选屏幕上任意位置的文字，即使是图片里的文字，或不允许拷贝的应用中的文字，译文都会显示在这段文字旁边。
- 打开翻译器，自己输入或粘贴文字。
- 自动识别语言，包括中文、日文或韩文与英文混合的文字。
- 可以朗读原文或译文，也能一键拷贝。

<p align="center">
  <img src="assets/screenshots/settings-zh.png" width="420" alt="picoTranslator 设置：屏幕录制权限、翻译语言、快捷键和登录时启动">
</p>

## 安装

Homebrew、App Store 和 GitHub Releases 即将推出。在此之前，请从源代码构建。

需要 macOS 26 或更高版本。

## 开始使用

picoTranslator 位于菜单栏。第一次打开时，它会引导你完成以下设置：

1. **屏幕录制：**读取你框选区域中的文字需要这项权限。允许后，macOS 会提示你退出并重新打开应用。
2. **翻译语言：**翻译使用 Apple 的模型在你的 Mac 上完成，请在“系统设置 › 通用 › 语言与地区 › 翻译语言…”中下载你要用的语言。
3. **快捷键：**按 ⌃⌥S 框选屏幕上的区域并翻译，按 ⌃⌥T 打开翻译器输入文字。两者都可以在设置中更改。按 Esc 关闭翻译器。

安装后（或 macOS 更新后）的第一次截图可能需要最多一分钟，因为 macOS 要先准备文字识别模型。之后只需片刻。如果你的 Mac 储存空间快满了，macOS 无法保留这个模型，每次截图都要重新准备；出现这种情况时，picoTranslator 会提示你。

## 局限与替代方案

这个项目的大部分代码由 AI 编写，我做它是为了自己使用。如果你遇到问题，请[提交 issue](https://github.com/encodeous/picoTranslator/issues)。

picoTranslator 有意保持小巧。如果你需要更多功能，比如词典查询、多种翻译服务、AI 模型或插件，可以试试这些很棒的应用：

- [Easydict](https://github.com/tisfeng/Easydict)：免费、开源的 macOS 翻译和词典应用，可以对比包括 AI 在内的多种服务的结果。
- [Pot](https://github.com/pot-app/pot-desktop)：免费、开源的翻译应用，支持 macOS、Windows 和 Linux，提供翻译、文字识别和语音朗读插件。

## 构建

需要 Xcode 命令行工具。

```bash
./build.sh
open build/picoTranslator.app
```

这会在 `build/picoTranslator.app` 生成一个针对体积优化的发布版本。如果你有 Developer ID 或 Apple Development 证书，会用它签名，否则使用临时签名。要指定签名身份：

```bash
SIGN_ID="<identity>" ./build.sh
```

运行测试：

```bash
swift test
```

## 许可证

[GNU Affero 通用公共许可证 v3.0](LICENSE)
