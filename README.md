# ScreenScribe · 屏注

用于讲课、演示和屏幕分享的原生 macOS 批注工具。冻结当前画面后，可以直接书写、框选和编辑文字；退出批注即可回到原来的应用。

使用 Swift、AppKit、SwiftUI 和 ScreenCaptureKit 构建，无第三方运行依赖。界面采用半透明悬浮工具条；macOS 26 使用系统 Liquid Glass，macOS 15 使用原生磨砂材质。

## 使用

应用运行需要 macOS 15 或更新版本；源码构建需要 Xcode 26 或更新版本（macOS 26 SDK、Swift 6）。

```bash
git clone https://github.com/Yurken/ScreenScribe.git
cd ScreenScribe
scripts/build.sh
open dist/ScreenScribe.app
```

启动后从菜单栏打开控制面板。首次使用冻结画面、截图、放大镜或录屏时，在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」允许屏注访问；系统要求时重新打开应用。只有选中录制麦克风时才请求麦克风权限。

默认构建使用本机临时签名，未使用 Apple Developer ID 签名，也未经过 Apple 公证。可直接使用源码构建，或在确认来源后按系统提示允许首次打开。

## 功能

| 功能 | 操作 |
| --- | --- |
| 冻结批注 | 固定当前显示器画面，避免网页滚动或动画影响讲解 |
| 实时批注 | 透明画布覆盖当前应用 |
| 画笔与形状 | 自由笔、荧光笔、直线、箭头、矩形、椭圆；颜色、粗细、填充可调 |
| 文字 | 原位输入与再次编辑；字体、字号、粗体、斜体、下划线和背景色 |
| 选择与整理 | 移动、调整大小、复制、删除；撤销、重做与清空 |
| 擦除与遮挡 | 橡皮擦、像素化区域 |
| 白板 / 黑板 | 无干扰的全屏空白画布 |
| 演示辅助 | 指针高亮、聚光灯、跟随放大镜、休息计时 |
| 桌面整理 | 使用壁纸覆盖层遮住桌面图标，退出后恢复 |
| 截图 | 完整画布或选区，导出 PNG / 复制到剪贴板 |
| 录屏 | MP4，最高 4K / 30 fps，系统声音与麦克风可选；包含屏幕批注 |

当前覆盖 macOS 桌面的主要演示流程。iPhone 遥控、远程画板、背景音乐和 PIN 锁定尚未实现。参考产品的功能对应与验证边界见 [功能对照](docs/ScreenMark-comparison.md)。

首版已通过 Debug / Release 构建、11 项测试和解压后的本机代码签名检查。安装包为 Apple Silicon 版本。当前自动化环境无法注册原生图形应用，屏幕权限、输入法候选框、多显示器、真实录屏及声音仍待真机验证。

## 快捷键

全局快捷键与工具快捷键以应用面板实际显示为准。默认全局入口：

| 快捷键 | 功能 |
| --- | --- |
| `⌃⌥1` | 实时批注 |
| `⌃⌥2` | 冻结并批注 |
| `⌃⌥0` | 显示 / 隐藏批注 |
| `⌃⌥3` | 区域截图 |
| `⌃⌥4` | 聚光灯 |
| `⌃⌥5` | 放大镜 |
| `⌃⌥6` | 白板 |
| `Esc` | 完成当前编辑 / 退出当前批注模式 |
| `⌘Z` / `⌘⇧Z` | 撤销 / 重做 |

`⌃` 表示 Control，`⌥` 表示 Option。全局快捷键可在设置中重新录入；如被其他应用占用，请按面板提示更换组合。工具条中的单字母提示仅在批注画布获得焦点时生效；编辑文字期间保留正常文字输入。

## 开发与打包

```bash
swift test
scripts/build.sh debug
scripts/package.sh          # ZIP
scripts/package.sh --dmg    # ZIP + DMG
```

输出位于 `dist/`。可设置 `SCREENSCRIBE_VERSION`、`SCREENSCRIBE_BUILD_NUMBER` 和 `SCREENSCRIBE_SIGNING_IDENTITY`。不设置签名身份时使用 ad-hoc 签名；设置 Developer ID 身份后启用 hardened runtime，公证仍需单独配置。

`Sources/ScreenScribeCore` 保存批注模型、历史记录、几何运算和画布；`Sources/ScreenScribe` 保存窗口、控制面板、系统快捷键、屏幕捕获及录制。GitHub Actions 在推送和 PR 时构建、测试并保存 ZIP；推送 `v*` 标签会生成 GitHub Release。

## 仓库与发布

源码托管于 [Yurken/ScreenScribe](https://github.com/Yurken/ScreenScribe)。安装包可在 [Releases](https://github.com/Yurken/ScreenScribe/releases) 下载，构建与测试状态见 [GitHub Actions](https://github.com/Yurken/ScreenScribe/actions)。

推送 `v*` 版本标签后，GitHub Actions 会自动测试、打包并发布对应版本。

## 数据与许可

批注、截图和录音在本机处理；应用不包含上传服务、账户或统计 SDK。冻结画面是显示器快照，不会暂停底层应用进程。

本项目独立实现，功能设计参考 [ScreenMark](https://ceritmustafa.github.io/screenmark-public/)，不使用其源码、图标或品牌素材，与原产品无隶属关系。代码采用 [MIT 许可证](LICENSE)。
