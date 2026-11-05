---
description: Luau 调用预算、进程超时与 I/O 边界
condition:
  - "\\bwhile\\s+true\\s+do\\b"
  - "\\brepeat\\b[\\s\\S]*\\buntil\\s+false\\b"
  - "tern\\.process\\.run\\s*\\("
  - "tern\\.fs\\.read\\s*\\("
scope: "tool:edit(*.luau), tool:write(*.luau)"
interruptMode: never
---
核对刚写的 Luau 代码:
- **调用预算**:每次 host 调用最多 2 s Lua 时间,window 50 ms,chrome 格式化 4 ms;超时的 hook 会被暂停,暂停时间从 5 s 开始逐次加倍。不要写无界循环,大任务用 `tern.timer(ms, fn)` 分片执行,每片处理固定数量的条目。
- **进程**:`tern.process.run` 默认**没有超时**,必须传 `timeout_ms`;回调里要处理 `timed_out`、`status ~= 0`(`-1` 表示被杀),以及 `stderr`。
- **文件读取**:`tern.fs.read` 读取量没有上限,读到 FIFO 还会卡死线程。先确认目标是普通文件;外部文件用 `pcall` 包裹;大文件改由外部进程处理后只回传摘要。
- **内存**:每个 VM 上限 256 MiB。缓存、日志、历史这类表必须有条目上限或 LRU 淘汰;不要把整份输出(最多 16 MiB)长期挂在 state 上。
- 过期的异步回调要用 `state.gen` 计数器丢弃;pane 已关闭时取消 timer。
