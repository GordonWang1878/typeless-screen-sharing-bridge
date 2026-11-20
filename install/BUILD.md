# 辅助 App 构建说明

`install/build_apps.sh` 把 `apps/` 下的 Swift 源文件构建为 ad-hoc 签名、`LSUIElement=true` 的 `.app` 包。安装脚本会自动调用它。

## 用法

```bash
install/build_apps.sh <输出目录>
```

- 必须传入输出目录，缺少参数会直接退出。
- 产物只写入输出目录（另有一个 `mktemp -d` 临时目录，退出时自动删除）。
- 会构建 3 个 App，并逐个执行 `--self-test` 自检，任一自检非 0 退出即失败。
- 每个 App 都是通用二进制（Apple 芯片 + Intel）：接收端在这台 Mac 上构建，再复制到被控的 Mac，那台可能是另一种芯片。
- 设置环境变量 `TB_MODULE_CACHE=<目录>` 可在多次构建之间保留 Swift 的模块缓存（每次省约 25 秒），产物与 CDHash 不变。安装向导会自动使用 `~/.local/share/typeless-remote-bridge-build/modcache`。
- 脚本仅需 macOS 自带的 `swiftc`、`codesign`、`plutil`。

## 构建的 App

| App | 可执行文件 | Bundle ID | 源文件 |
|---|---|---|---|
| TypelessBridgeReceiver.app | TypelessBridgeReceiver | org.local.typelessbridge.receiver | receiver.swift |
| TypelessBridgeGuard.app | TypelessBridgeGuard | org.local.typelessbridge.guard | guard.swift |
| TypelessBridgeProbe.app | TypelessBridgeProbe | org.local.typelessbridge.probe | probe.swift |


## 安装窗口

`install/build_setup_app.sh <输出目录>` 把 `apps/setup-window.swift` 构建为 `Screen Sharing Bridge Setup.app`：只编译本机芯片、ad-hoc 签名，只在你说话的那台 Mac 上需要，不会被安装到任何地方。`setup --window` 会在源码、芯片或编译器变化时才重新构建，构建期间终端显示进度。

开发用的检查方式（不会启动安装流程）：

- `…/SetupWindow --snapshot <目录>`：把每一页离屏渲染成 PNG（`TB_LANG=zh|en` 选择语言），用于设计评审。
- `TB_WINDOW_CHECK=<png> …/SetupWindow <仓库>`：以完全透明的方式打开真实窗口、渲染成图片并打印尺寸后退出。
- `…/SetupWindow --write-ding <wav>`：写出完成时的提示音。

## README 配图

`tools/readme-art.sh`（仅开发仓库）用安装窗口自己的 SwiftUI 代码加 `tools/readme-art.swift`（以 `-D README_ART` 编译，不进入 App）重新生成 `docs/images` 里的图片：中英文、浅色和深色，保存为 WebP。`docs/images` 在 `.gitattributes` 里标记为 `export-ignore`，一行安装命令下载的压缩包里不包含它。

## 签名与授权

- ad-hoc 签名（`codesign --sign -`）。构建是可复现的：同一份源码、同一编译器，在任何目录、任何一台 Mac 上都得到相同的 CDHash，"隐私与安全性 → 设备控制"里的授权在重装后可以沿用。
- 为此脚本在 `apps/` 目录内用相对文件名编译：`swiftc` 会把命令行给出的源文件路径写进二进制（`fatalError`、顶层未捕获的 `try` 等都会带上路径）。
- 源码一改，CDHash 就变，需要先在设备控制里用 "−" 删掉旧条目、再添加新 App（条目按 Bundle ID 记录，但保留旧签名）。
- 脚本从不安装、不启动 App，也不写入 `~/Library` 或 `~/Applications`。
