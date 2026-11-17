# 发送端服务

由 `install/typeless-bridge.sh install --sender …` 复制到
`~/Library/Application Support/TypelessRemoteBridge/service/`，入口为 `sender.py`。

| 文件 | 作用 |
|---|---|
| `sender.py` | 入口：单实例锁、启动 Guard 并维持心跳、按 `--destinations` 过滤目标、送达后通知 Guard 关弹窗 |
| `identities.py` | 启动时及每 30 分钟经 SSH 收集各目标 Mac 的电脑名、主机名、地址，写入 `identities.json`；Guard 和探针用窗口对应的机器名与之比对 |
| `watcher.py` | 只读轮询 `history_v2`、调用焦点探针、经 SSH 投递 |
| `completion_dispatch.py` | 每条记录只投递一次；投递前复核目标 |
| `completion_routing.py` | 纯函数：判断一条记录是否应投递、投到哪里 |

## 日志（`~/Library/Logs/TypelessRemoteBridge/sender.log`）

| 行 | 含义 |
|---|---|
| `PILOT_READY` | Guard 就绪，开始监听 |
| `TARGET <x>` | 一句完成时前台的目标：配置的目标名（如 `studio`）、`local`，或 `unknown:<原因>`（如 `unknown:name-not-recognized`） |
| `RESULT paste-sent-unconfirmed` | 已送到远端并发出粘贴 |
| `RESULT local` | 前台不是屏幕共享，交给 Typeless 自己粘贴 |
| `RESULT unknown` | 屏幕共享窗口连的不是本机配置的目标（或认不出来），交给 Typeless 自己粘贴 |
| `RESULT delivery-unconfirmed` 等 | 没送达；复制弹窗不会被关掉，用户可手动复制 |
| `POPUP_CLOSED` | 已自动关掉 Typeless 的"复制最后的转录"（Copy last transcript）弹窗 |
| `POPUP_LEFT <原因>` | 弹窗保留：`not-delivered` 这句没送达（20 秒内无送达确认）、`not-found` 没出现、`layout` 结构对不上、`target` 前台已不是配置的远程窗口、`press-failed` 按下失败 |
| `RESULT not-sent` | Guard 拦下了 Typeless 的粘贴，但 20 秒内没有任何投递结果（例如焦点探针没认出窗口）；弹窗保留 |
| `SKIP_AMBIGUOUS` | 同一时刻出现两条新听写记录，无法确定对应哪句而跳过；若当时 Guard 拦了粘贴，会随后出现 `RESULT not-sent` |
| `LATE_COMPLETION` | Typeless 先把这句标成出错，随后重试成功；照常送出 |
| `GAVE_UP <状态>` | 一句被标成出错/取消后 3 分钟内没有恢复，不再等待 |
| `SKIP_MODE <mode>` | Typeless 非听写功能产生的记录，不桥接（只记录模式名） |
| `IDENTITY_CACHED <mac>` / `IDENTITY_UNAVAILABLE <mac>` | 连不上该 Mac，沿用上次的身份 / 没有可用身份（这台暂时认不出） |
| `GUARD_NOT_READY` / `GUARD_EXITED` | Guard 未获授权或已退出；服务退出，launchd 30 秒后重启 |

日志里不会出现转写原文。修改后需重新运行安装脚本部署。
