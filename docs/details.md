# How it works · 工作原理

## Overview · 概览

```
Mac you talk to (sender)                                  Mac being controlled (receiver)
Typeless finishes a dictation
  → the sender reads Typeless' local history (read-only)
  → the probe tells which Mac the front Screen Sharing window shows
  → the guard drops Typeless' own ⌘V (no stray "V")
  → the text goes over SSH  ────────────────────────────→  the receiver pastes it at the cursor,
  → after delivery, the guard closes the copy popup         then restores the clipboard (1.5 s)
```

| Part · 组件 | Where · 位置 | Does · 作用 |
|---|---|---|
| sender | `service/` (LaunchAgent `org.local.typelessbridge.sender`) | watches history, decides the target, delivers once · 监视历史、判断目标、只投递一次 |
| TypelessBridgeGuard | `apps/guard.swift` | stops Typeless' paste into a target window; closes the popup only after delivery · 拦截 Typeless 的粘贴；送达后才关弹窗 |
| TypelessBridgeProbe | `apps/probe.swift` | names the Mac shown in the front Screen Sharing window · 识别前台屏幕共享窗口对应的 Mac |
| TypelessBridgeReceiver | `apps/receiver.swift` (LaunchAgent `org.local.typelessbridge.receiver`) | pastes received text at the cursor · 把收到的文字粘贴到光标处 |

- A Mac is recognised by the name in its Screen Sharing connection (`Studio (alice).vncloc` →
  `studio`), matched against the names each receiver reports about itself over SSH. The login
  user name does not matter. · 按屏幕共享连接里的机器名识别，与登录用户名无关。
- Each sentence is sent at most once and never retried. · 每句最多发送一次，从不重发。
- Transcripts are never written to logs or command arguments. · 转写原文不进日志、不进命令参数。

## Logs · 日志

`~/Library/Logs/TypelessRemoteBridge/sender.log`, one block per sentence · 每句一组：

| Line · 日志 | Meaning · 含义 |
|---|---|
| `TARGET studio` → `RESULT paste-sent-unconfirmed` → `POPUP_CLOSED` | delivered · 已送达 |
| `RESULT local` | Screen Sharing not in front · 前台不是屏幕共享 |
| `TARGET unknown:name-not-recognized` | window of a Mac that is not paired · 未配对的 Mac 的窗口 |
| `POPUP_LEFT not-delivered`, `RESULT not-sent`, other `RESULT …` | not delivered, popup left open · 没送达，弹窗保留 |
| `LATE_COMPLETION` / `GAVE_UP` | Typeless finished after a retry / never finished · Typeless 重试后完成 / 一直没完成 |
| `GUARD_NOT_READY` | the guard is not allowed in Device Control yet · Guard 还没授权 |

All lines: [service/README.md](../service/README.md).

## Known limitations · 已知限制

- Only Apple's Screen Sharing. · 只支持 Apple 自带的屏幕共享。
- A saved connection renamed to something other than the Mac's name is not recognised. · 保存的连接若改成了非机器名，将认不出来。
- Only plain dictation, not Typeless' other modes. · 只处理普通听写。
- Depends on Typeless' history format and popup layout; anything unrecognised is left alone. · 依赖 Typeless 的历史格式和弹窗结构；认不出时一律不动作。
- The popup shows briefly before it is closed. · 弹窗会短暂出现后才被关掉。
- After an upgrade, changed apps must be removed from Device Control with "−" and added again (they
  are built and signed on your Mac). · 升级后，有变化的 App 需在设备控制里先删再加。
