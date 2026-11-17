# 辅助 App 构建说明

`install/build_apps.sh` 把 `apps/` 下的 Swift 源文件构建为 ad-hoc 签名、`LSUIElement=true` 的 `.app` 包。安装脚本会自动调用它。

## 用法

```bash
install/build_apps.sh <输出目录>
```

- 必须传入输出目录，缺少参数会直接退出。
- 产物只写入输出目录（另有一个 `mktemp -d` 临时目录，退出时自动删除）。
- 会构建 3 个 App，并逐个执行 `--self-test` 自检，任一自检非 0 退出即失败。
- 脚本仅需 macOS 自带的 `swiftc`、`codesign`、`plutil`。

## 构建的 App

| App | 可执行文件 | Bundle ID | 源文件 |
|---|---|---|---|
| TypelessBridgeReceiver.app | TypelessBridgeReceiver | org.local.typelessbridge.receiver | receiver.swift |
| TypelessBridgeGuard.app | TypelessBridgeGuard | org.local.typelessbridge.guard | guard.swift |
| TypelessBridgeProbe.app | TypelessBridgeProbe | org.local.typelessbridge.probe | probe.swift |


## 签名与授权

- ad-hoc 签名（`codesign --sign -`）。构建是可复现的：同一份源码、同一编译器，在任何目录、任何一台 Mac 上都得到相同的 CDHash，"隐私与安全性 → 设备控制"里的授权在重装后可以沿用。
- 为此脚本在 `apps/` 目录内用相对文件名编译：`swiftc` 会把命令行给出的源文件路径写进二进制（`fatalError`、顶层未捕获的 `try` 等都会带上路径）。
- 源码一改，CDHash 就变，需要先在设备控制里用 "−" 删掉旧条目、再添加新 App（条目按 Bundle ID 记录，但保留旧签名）。
- 脚本从不安装、不启动 App，也不写入 `~/Library` 或 `~/Applications`。
